# State bootstrap

This root creates a private, versioned S3 bucket in `us-east-1`. State uses SSE-S3
encryption and Terraform's native S3 lock file. No DynamoDB table is needed.
The customer-managed key for application secrets belongs to the security module.

It also creates the GitHub Actions identity in [cicd.tf](cicd.tf): the OIDC
provider, plan/apply/drift roles trusted only for exact repository subjects, their
least-privilege policies, and the asymmetric plan-signing key.
The roles trust immutable subjects (`repo:OWNER@OWNER_ID/REPO@REPO_ID:...`), so set
`github_owner_id` and `github_repository_id` before the first apply. Get them with
`gh api repos/OWNER/REPO --jq '.owner.id, .id'`. To trust other exact subjects
instead, set `github_oidc_subjects`. If the project already has a GitHub OIDC
provider, set `github_oidc_provider_arn`. The applying administrator needs IAM,
KMS, and S3 permissions.

These are deployment instructions; creating the configuration does not run them.
Use Terraform 1.17.1 and the `ubuntu` AWS profile:

```sh
export AWS_PROFILE=ubuntu
mkdir -p -m 700 .aetherpay
terraform -chdir=terraform/environments/staging/bootstrap init
terraform -chdir=terraform/environments/staging/bootstrap plan -var-file=$PWD/.aetherpay/bootstrap.tfvars -out=$PWD/.aetherpay/state.tfplan
terraform -chdir=terraform/environments/staging/bootstrap apply $PWD/.aetherpay/state.tfplan
```

Run the rest only after the apply finishes without errors:

```sh
terraform -chdir=terraform/environments/staging/bootstrap output -json backend_configs > $PWD/.aetherpay/backends.json
python3 -c 'import json; d=json.load(open(".aetherpay/backends.json")); json.dump(d["bootstrap"],open(".aetherpay/bootstrap.backend.json","w")); json.dump(d["staging"],open(".aetherpay/staging.backend.json","w"))'
cp terraform/environments/staging/bootstrap/backend.tf.example terraform/environments/staging/bootstrap/backend.tf
terraform -chdir=terraform/environments/staging/bootstrap init -migrate-state -backend-config=$PWD/.aetherpay/bootstrap.backend.json
```

The last command asks whether to copy the existing local state to the new S3
backend. Type `yes` and press Enter.

The first apply uses local state because the bucket does not exist yet. The final
command migrates that state after the bucket is ready. Keep the local state and
backup protected until migration is verified. Credentials stay in the AWS profile.

`state_access_policies` contains, for each root, a `read_only` policy (list the
bucket, read the named state object, and read/write/delete its lock object) and a
`read_write` policy that can also write state. The CI plan and drift roles use the
staging `read_only` policy; apply uses `read_write`. No policy can delete a state
object. The bucket rejects HTTP for state and lock operations, blocks public
access, and prevents Terraform destruction.

After apply, `terraform output -json github_actions_variables` prints the role
ARNs, signing-key ARN, bucket, state key, and project ID for the repository
variables.

Reference: [Terraform S3 backend and locking](https://developer.hashicorp.com/terraform/language/backend/s3).
