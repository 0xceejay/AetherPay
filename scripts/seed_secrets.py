"""Initialize empty AetherPay secrets interactively, without Terraform or plaintext files."""

import argparse
import base64
import getpass
import json
import secrets
import sys
import uuid
import warnings

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError


def needs_initial_value(client, arn):
    metadata = client.describe_secret(SecretId=arn)
    stages = metadata.get("VersionIdsToStages", {})
    if any("AWSCURRENT" in labels for labels in stages.values()):
        return False
    if metadata.get("RotationEnabled") or stages:
        raise ValueError("Disable rotation and resolve existing version stages before initializing a secret")
    if metadata.get("KmsKeyId") is None:
        raise ValueError("Secret must use the security module's customer-managed key")
    return True


def put_initial_value(client, arn, value):
    # Racing initializers use the same token; a retry cannot replace another value.
    token = str(uuid.uuid5(uuid.NAMESPACE_URL, arn + "/initial"))
    client.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        VersionStages=["AWSCURRENT"],
        SecretString=json.dumps(value),
    )


def initialize(client, database_arn, signature_arn):
    for arn in (database_arn, signature_arn):
        if not arn.startswith("arn:aws:secretsmanager:us-east-1:") or ":secret:" not in arn:
            raise ValueError("Supply Secrets Manager ARNs in the selected Region, us-east-1")
    database_empty = needs_initial_value(client, database_arn)
    signature_empty = needs_initial_value(client, signature_arn)

    if database_empty:
        host = input("PostgreSQL host (same as Terraform database.host): ").strip()
        port = int(input("PostgreSQL port [5432]: ").strip() or "5432")
        name = input("Database name: ").strip()
        username = input("Existing application database user: ").strip()
        password = getpass.getpass("Current password for that user: ")
        confirm = getpass.getpass("Confirm password: ")
        if not all((host, name, username, password)) or password != confirm or not 1 <= port <= 65535:
            raise ValueError("Database details are incomplete or passwords do not match")
        put_initial_value(client, database_arn, {
            "engine": "postgres", "host": host, "port": port, "dbname": name,
            "username": username, "password": password,
        })
        print("Database secret initialized.")
    else:
        print("Database secret already initialized; unchanged.")

    if signature_empty:
        key_id = str(uuid.uuid5(uuid.NAMESPACE_URL, signature_arn + "/initial"))
        put_initial_value(client, signature_arn, {
            "algorithm": "HMAC-SHA256", "key_id": key_id,
            "key": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
        })
        print("Signature secret initialized.")
    else:
        print("Signature secret already initialized; unchanged.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database-secret-arn", required=True)
    parser.add_argument("--signature-secret-arn", required=True)
    parser.add_argument("--profile", default="ubuntu")
    args = parser.parse_args()
    if not sys.stdin.isatty():
        parser.error("Run from an interactive terminal; passwords are read with echo disabled")
    try:
        warnings.simplefilter("error", getpass.GetPassWarning)
        session = boto3.Session(profile_name=args.profile, region_name="us-east-1")
        client = session.client("secretsmanager", config=Config(
            connect_timeout=5, read_timeout=10,
            retries={"total_max_attempts": 3, "mode": "standard"},
        ))
        initialize(client, args.database_secret_arn, args.signature_secret_arn)
    except (BotoCoreError, ClientError, ValueError, EOFError, KeyboardInterrupt, getpass.GetPassWarning) as error:
        # AWS error codes help diagnose permissions without printing request payloads.
        code = error.response["Error"]["Code"] if isinstance(error, ClientError) else type(error).__name__
        print(f"Secret initialization stopped ({code}); no secret values were printed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
