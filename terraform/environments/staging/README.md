# Staging

This root connects networking, ingress, compute, cache, messaging, and security in
`us-east-1`. It creates the ALB/WAF, Redis cache, and ingestion queue and passes
their real outputs to ECS. PostgreSQL metadata, an issued ACM certificate, a private
ECR repository, and its published image remain supplied inputs.

Copy `staging.tfvars.example` to a file outside the repository. Replace the sample
identifiers with resources in this project and Region. The certificate must cover
your ingestion hostname; arrange its DNS alias to the ALB separately. The image
must serve `health_check_path` (default `/health`) on `application_port` (8080),
connect to private Redis TCP, and implement SDK secret retrieval and refresh.
The PostgreSQL target must use the isolated tier and its database security group.
Do not put database passwords or signing keys in the variable file.

The example cache version `7.1` is for fresh staging. The cache module leaves its
version unset by default to preserve a legacy deployment's original configuration.
Use the [legacy migration runbook](../../../docs/VULNERABILITY-AUDIT.md#cache-state-migration)
for the supplied baseline. Fresh staging creates a new VPC and is a separate path.

Complete the [state bootstrap](bootstrap/README.md), then build the rotation
package and initialize the backend from the repository root:

```sh
export AWS_PROFILE=ubuntu
python3 terraform/modules/security/rotation/build_package.py
terraform -chdir=terraform/environments/staging init -backend-config=$PWD/.aetherpay/staging.backend.json
```

For the first deployment only, create networking and secret infrastructure before
starting the service or enabling rotation. Targeting these modules also creates
the task-role identities and ingestion queue referenced by their policies, without
starting ECS. The later full plan creates ingress and the cache:

```sh
terraform -chdir=terraform/environments/staging plan -var-file=$PWD/.aetherpay/staging.tfvars -var='enable_rotation=false' -target=module.networking -target=module.security -out=$PWD/.aetherpay/seed.tfplan
terraform -chdir=terraform/environments/staging apply $PWD/.aetherpay/seed.tfplan
terraform -chdir=terraform/environments/staging output secret_arns
terraform -chdir=terraform/environments/staging output -raw seed_access_policy
```

Use an authorized bootstrap identity with the displayed exact seed permissions.
The helper needs boto3; install the pinned rotation requirements in a local virtual
environment, then run it from an interactive terminal:

```sh
python3 -m venv .aetherpay/seed-venv
.aetherpay/seed-venv/bin/pip install -r terraform/modules/security/rotation/requirements.txt
.aetherpay/seed-venv/bin/python scripts/seed_secrets.py --database-secret-arn '<database ARN>' --signature-secret-arn '<signature ARN>'
```

It prompts for the existing PostgreSQL application user's password without echo,
generates the signing key in memory, and skips secrets that already have an
`AWSCURRENT` version. No secret values are printed or written to files. The
PostgreSQL target and credentials must be valid before enabling rotation.

Then create and review a full plan, with rotation enabled:

```sh
terraform -chdir=terraform/environments/staging plan -var-file=$PWD/.aetherpay/staging.tfvars -var='enable_rotation=true' -out=$PWD/.aetherpay/staging.tfplan
terraform -chdir=terraform/environments/staging apply $PWD/.aetherpay/staging.tfplan
```

Use full plans for subsequent changes and CI. Targeted initialization is only for
the one-time dependency on secret values supplied outside Terraform. Application
SDK retrieval, refresh, retry, and signature overlap handling must be ready before
this full deployment. Live rotation and service health still require verification.

## Dependency wiring

Compute reads `module.cache[0].cache_endpoint` (null when `enable_cache` is false), `module.messaging.ingestion_queue`,
and `module.ingress.target_group_arn`. The target-group output waits for the HTTPS
listener and WAF association. Cache attributes become available after the resource
is ready. IAM and endpoint policies use the same queue ARN as the
scaling metric. Networking's cache rule uses the configured cache port, avoiding
a circular reference to the cache's computed endpoint.

Secret values remain outside Terraform. Existing endpoint and role policies are
scoped to the resulting queue, secrets, key, and ECR repository. No blanket
module-level `depends_on` is used.

## Deployment checks

Run these checks after an approved deployment; they have not been executed here.
Use the certificate's real hostname. The following probes validate that hostname
while connecting directly to the ALB, before the DNS alias is in place:

```sh
export AWS_PROFILE=ubuntu
export AWS_REGION=us-east-1
AETHERPAY_STAGE_HOST=ingestion.example.com
AETHERPAY_ALB_DNS=$(terraform -chdir=terraform/environments/staging output -raw alb_dns_name)

openssl s_client -connect "$AETHERPAY_ALB_DNS:443" -servername "$AETHERPAY_STAGE_HOST" -verify_hostname "$AETHERPAY_STAGE_HOST" -verify_return_error -tls1_3 </dev/null
openssl s_client -connect "$AETHERPAY_ALB_DNS:443" -servername "$AETHERPAY_STAGE_HOST" -tls1_2 </dev/null
curl --fail --tlsv1.3 --tls-max 1.3 --connect-to "$AETHERPAY_STAGE_HOST:443:$AETHERPAY_ALB_DNS:443" "https://$AETHERPAY_STAGE_HOST/health"

aws elbv2 describe-target-health --target-group-arn "$(terraform -chdir=terraform/environments/staging output -raw target_group_arn)"
aws ecs describe-services --cluster "$(terraform -chdir=terraform/environments/staging output -raw cluster_arn)" --services "$(terraform -chdir=terraform/environments/staging output -raw service_name)"
```

The TLS 1.3 probe and readiness request must succeed; the TLS 1.2 handshake must
fail. Substitute the configured health path if it differs. All registered targets
must become healthy and the ECS deployment must stabilize at the expected count.
There is no HTTP port 80 listener or public application port.

| Check | Expected result |
| --- | --- |
| WAF association | The ALB is associated with the output web ACL ARN; `AWSManagedRulesCommonRuleSet` and the blocking 1,000/300-second/source-IP rule are enabled. |
| WAF behavior | From a disposable staging test IP, sustained requests to a harmless endpoint above the configured rate eventually receive WAF blocks. Confirm `BlockedRequests` for the rate rule, then recovery after traffic stops. Enforcement is approximate; request 1,001 need not be the first blocked request. Check legitimate webhook fixtures against the managed rules before accepting production traffic. |
| Cache connectivity | From an approved diagnostic environment in an application subnet, `redis-cli -h <output address> -p <output port> PING` returns `PONG`. An unauthorized source security group cannot establish a connection. No bastion or unrestricted egress is needed. |
| Queue and scaling | Enqueue disposable, nonfinancial fixtures through the SQS endpoint using an authorized workload. Verify queue depth, CPU/memory metrics, and scale-out above the chosen thresholds. Confirm the worker drains them and scale-in waits for the longer quiet window. The sample requires five quiet samples within six minutes. |
| Autoscaler ownership | After scaling, a normal plan does not propose resetting `desired_count`; task definition and scaling bounds remain managed. |
| Secret rotation | Confirm each rotation finishes successfully, the application refreshes credentials, and signature verification handles the agreed previous-key overlap. |
| Cache migration | Follow the separate legacy-root runbook. The cache ID, endpoint, engine version, subnet group, and existing data remain unchanged after the address-only move. |

The baseline-compatible Redis resource is single-node and does not enable TLS or
automatic replica failover. Its existing identifiers and settings must remain
unchanged for a state-only migration. WAF common rules can block legitimate
payloads, including some bodies above their inspection-size threshold; review
real webhook fixtures before changing enforcement or adding an exception.

[GitHub Actions](../../../.github/workflows) runs automated linting, security
scanning, signed-plan apply, and drift detection.
