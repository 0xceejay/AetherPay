# Security

The module creates database and signature secret containers, a customer-managed
KMS key, two private rotation functions, and their IAM and resource policies.
Terraform manages metadata and ARNs only. Secret values never enter its inputs,
outputs, task environment, or state.

Build the Lambda package from the repository root before planning or validating:

```sh
python3 terraform/modules/security/rotation/build_package.py
```

The ignored `.build/rotation.zip` contains the handler, boto3, pg8000, and all
their runtime dependencies. `rotation/requirements.txt` pins every version and
the SHA-256 of its universal PyPI wheel; the builder enforces `--require-hashes`
and rejects source distributions. It extracts wheel contents directly, excluding
unused command-line scripts, instead of generating installer-specific files.
Sorted ZIP entries use fixed timestamps, permissions, and no compression, so
temporary paths, Python bytecode, and host zlib versions cannot change its hash.
The build fails if the ZIP exceeds Lambda's 50 MiB direct-upload limit.

The default CA is the committed `rotation/us-east-1-rds-ca.pem`, downloaded from
the [AWS regional trust store](https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem)
on 2026-11-11. Its reviewed SHA-256 is
`b1711d12bae51838581281e23b6cb97b1074016873b4dafc80ed14002462dd77`;
the builder verifies it without fetching a replacement. Review CA refreshes as
source changes and update that digest in `build_package.py` with the PEM. AWS
documents the regional bundles in its [RDS TLS guide](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html).
For a PostgreSQL server with a different CA, pass `--ca-bundle /path/to/ca.pem`.
That file's bytes become part of the package and must stay fixed between plans;
CI uses the committed default. TLS and hostname verification stay enabled.

CI builds with Python 3.13.9 and pip 24.3.1, signs the ZIP's digest with
the plan manifest, and restores that exact ZIP for apply. Drift checks rebuild
from the same dependency lock and CA bytes. Builds download the hash-locked wheels from PyPI but make no
AWS API calls. See [pip hash checking](https://pip.pypa.io/en/stable/topics/secure-installs/).

Inputs connect three private application subnets, the application security group,
Secrets Manager endpoint, task role, PostgreSQL host/port/database name, and
rotation intervals. `enable_rotation` defaults to true; use false only while
initializing empty secrets. Staging supplies the endpoint policy that admits the
task role and each rotation role. Secret reads require that endpoint and the
appropriate workload role. KMS use requires the exact secret encryption context
and the Secrets Manager service.

PostgreSQL rotation changes the existing application's own password, tests a new
TLS connection, then promotes `AWSPENDING` to `AWSCURRENT`. It never provisions a
database or user. Single-user rotation requires clients to refresh credentials
and retry new connections during the password change.

The signature secret contains `algorithm`, `key_id`, and a base64-encoded 256-bit
HMAC key. AetherPay's signer reads `AWSCURRENT`. The verifier must refresh its cache
and accept `AWSPREVIOUS` for the agreed overlap window, using `key_id` to select
the version. Rotation intervals must exceed that window and message lifetime.
Those application behaviors still need implementation; creating the Lambda alone
does not coordinate deployed signers and verifiers.

Each function has its own role and exact secret/key grants. Lambda's required
EC2 interface permissions use wildcard resources, with an explicit deny when
called by function code. In a KMS key policy, `Resource = "*"` denotes only the
attached key; identity policies use the exact key ARN. No wildcard actions are used.
During initial creation, key validation is limited to Secrets Manager's
`RequestToValidateKeyAccess` context. The final key policy replaces that temporary
grant with the two exact secret ARNs once they exist.

See [staging setup](../../environments/staging/README.md) for initial seeding and
enabling rotation. Validation does not prove live database or signer rotation.

References: [rotation steps](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotate-secrets_lambda-functions.html),
[rotation permissions](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets-required-permissions-function.html),
[Lambda VPC permissions](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html),
and [KMS key policy scope](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-overview.html).
See also [Secrets Manager key validation](https://docs.aws.amazon.com/secretsmanager/latest/userguide/security-encryption.html).
