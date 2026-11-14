"""Secrets Manager rotation for PostgreSQL and AetherPay HMAC signing keys."""

import base64
import binascii
from contextlib import closing
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import ssl

import boto3
from botocore.config import Config
import pg8000.native


_client = None


def secret_client():
    global _client
    if _client is None:
        _client = boto3.client(
            "secretsmanager",
            config=Config(
                connect_timeout=5,
                read_timeout=10,
                retries={"total_max_attempts": 3, "mode": "standard"},
            ),
        )
    return _client


def read_secret(client, arn, stage, token=None):
    request = {"SecretId": arn, "VersionStage": stage}
    if token is not None:
        request["VersionId"] = token
    response = client.get_secret_value(**request)
    value = json.loads(response["SecretString"])
    if not isinstance(value, dict):
        raise ValueError("Secret must contain a JSON object")
    return value


def validate_database(value):
    expected = {
        "engine": "postgres",
        "host": os.environ["DB_HOST"],
        "port": int(os.environ["DB_PORT"]),
        "dbname": os.environ["DB_NAME"],
    }
    if any(value.get(key) != item for key, item in expected.items()):
        raise ValueError("Secret does not match the configured PostgreSQL target")
    if not all(isinstance(value.get(key), str) and value[key] for key in ("username", "password")):
        raise ValueError("PostgreSQL credentials are incomplete")


def signature_key(value):
    if value.get("algorithm") != "HMAC-SHA256" or not isinstance(value.get("key_id"), str) or not value["key_id"]:
        raise ValueError("Signature secret metadata is invalid")
    try:
        key = base64.b64decode(value["key"], validate=True)
    except (KeyError, TypeError, ValueError, binascii.Error):
        raise ValueError("Signature key encoding is invalid") from None
    if len(key) != 32:
        raise ValueError("Signature key must contain 256 bits")
    return key


def validate_value(kind, value):
    if kind == "database":
        validate_database(value)
    else:
        signature_key(value)


def connect_database(value):
    # TLS and hostname verification stay enabled for every connection.
    context = ssl.create_default_context()
    context.load_verify_locations(cafile=str(Path(__file__).with_name("postgres-ca.pem")))
    return pg8000.native.Connection(
        user=value["username"],
        password=value["password"],
        host=value["host"],
        port=value["port"],
        database=value["dbname"],
        ssl_context=context,
        timeout=5,
    )


def try_database_credentials(value):
    try:
        return connect_database(value)
    except pg8000.native.DatabaseError as error:
        details = error.args[0] if error.args else None
        if isinstance(details, dict) and details.get("C") in {"28P01", "28000"}:
            return None
        raise


def create_secret(client, arn, token, kind, rotation_token=None):
    current = read_secret(client, arn, "AWSCURRENT")
    validate_value(kind, current)
    try:
        pending = read_secret(client, arn, "AWSPENDING", token)
    except client.exceptions.ResourceNotFoundException:
        if kind == "database":
            pending = {**current, "password": secrets.token_urlsafe(32)}
        else:
            pending = {
                "algorithm": "HMAC-SHA256",
                "key_id": token,
                "key": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
            }
        request = {
            "SecretId": arn,
            "ClientRequestToken": token,
            "VersionStages": ["AWSPENDING"],
            "SecretString": json.dumps(pending),
        }
        if rotation_token is not None:
            request["RotationToken"] = rotation_token
        client.put_secret_value(**request)
    else:
        validate_value(kind, pending)


def set_secret(client, arn, token, kind):
    current = read_secret(client, arn, "AWSCURRENT")
    pending = read_secret(client, arn, "AWSPENDING", token)
    validate_value(kind, current)
    validate_value(kind, pending)
    if kind == "signature":
        # AetherPay's signer and verifier use this secret as their key source.
        # Promotion in finishSecret changes the active key for both consumers.
        return

    if pending["username"] != current["username"]:
        raise ValueError("Rotation cannot change the PostgreSQL user")
    connection = try_database_credentials(pending)
    if connection is not None:
        connection.close()
        return

    connection = try_database_credentials(current)
    if connection is None:
        try:
            previous = read_secret(client, arn, "AWSPREVIOUS")
        except client.exceptions.ResourceNotFoundException:
            raise ValueError("No working PostgreSQL credential version") from None
        validate_database(previous)
        if previous["username"] != current["username"]:
            raise ValueError("Previous credentials refer to another PostgreSQL user")
        connection = try_database_credentials(previous)
    if connection is None:
        raise ValueError("No working PostgreSQL credential version")

    # PostgreSQL role identifiers and utility-statement literals need SQL quoting.
    with closing(connection):
        connection.run(
            f"ALTER ROLE {pg8000.native.identifier(pending['username'])} "
            f"WITH PASSWORD {pg8000.native.literal(pending['password'])}"
        )


def test_secret(client, arn, token, kind):
    pending = read_secret(client, arn, "AWSPENDING", token)
    validate_value(kind, pending)
    if kind == "database":
        with closing(connect_database(pending)) as connection:
            if connection.run("SELECT 1") != [[1]]:
                raise ValueError("PostgreSQL credential test failed")
    else:
        key = signature_key(pending)
        digest = hmac.digest(key, b"aetherpay-rotation-check", hashlib.sha256)
        if len(digest) != hashlib.sha256().digest_size:
            raise ValueError("Signature key test failed")


def finish_secret(client, arn, token, metadata):
    current = next(
        (version for version, stages in metadata["VersionIdsToStages"].items() if "AWSCURRENT" in stages),
        None,
    )
    if current is None:
        raise ValueError("Secret must be initialized before rotation")
    client.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current,
    )


def lambda_handler(event, context):
    kind = os.environ["SECRET_KIND"]
    arn = os.environ["SECRET_ARN"]
    step = event.get("Step")
    if kind not in {"database", "signature"} or event.get("SecretId") != arn:
        raise ValueError("Rotation request does not match this function's secret")
    if step not in {"createSecret", "setSecret", "testSecret", "finishSecret"}:
        raise ValueError("Unknown rotation step")
    token = event.get("ClientRequestToken")
    if not isinstance(token, str) or not 32 <= len(token) <= 64:
        raise ValueError("Invalid rotation request token")

    try:
        client = secret_client()
        metadata = client.describe_secret(SecretId=arn)
        if not metadata.get("RotationEnabled"):
            raise ValueError("Secret rotation is disabled")
        stages = metadata.get("VersionIdsToStages", {}).get(token, [])
        if "AWSCURRENT" in stages:
            return
        if "AWSPENDING" not in stages:
            raise ValueError("Request token is not staged for this rotation")

        if step == "createSecret":
            create_secret(client, arn, token, kind, event.get("RotationToken"))
        elif step == "setSecret":
            set_secret(client, arn, token, kind)
        elif step == "testSecret":
            test_secret(client, arn, token, kind)
        else:
            finish_secret(client, arn, token, metadata)
    except Exception:
        # Driver and SDK exceptions can include request details; no values leave here.
        raise RuntimeError(f"{kind} secret rotation failed during {step}") from None
