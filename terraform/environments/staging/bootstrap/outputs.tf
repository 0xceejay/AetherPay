# Name of the state bucket, for each root's backend configuration.
output "bucket_name" {
  description = "Encrypted, private Terraform state bucket."
  value       = aws_s3_bucket.state.id
}

# Backend settings for each root: bucket, key, Region, encryption and the S3 lock file.
# Credentials are not included.
output "backend_configs" {
  description = "Backend settings for bootstrap and staging; credentials are supplied separately."
  value = {
    for name, key in local.state_keys : name => {
      bucket       = aws_s3_bucket.state.id
      key          = key
      region       = "us-east-1"
      encrypt      = true
      use_lockfile = true
    }
  }
}

# State and lock-file IAM policy documents per root. The read_only version can take the
# lock but not write state; the read_write version can. The CI roles use the staging
# pair.
output "state_access_policies" {
  description = "Exact state/lock IAM policies per root: read_only takes the lock without writing state (plan, drift); read_write also writes state (apply)."
  value       = local.state_policies
}

# ARN of the GitHub OIDC provider the CI roles trust, whether this root created it or
# you supplied it.
output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC identity provider trusted by the CI roles."
  value       = local.github_oidc_provider_arn
}

# ARNs of the plan, apply and drift roles.
output "ci_role_arns" {
  description = "OIDC roles for the plan, apply, and drift jobs."
  value       = { for role, ci in aws_iam_role.ci : role => ci.arn }
}

# KMS key that signs saved plans (plan role) and verifies them (apply role).
output "plan_signing_key_arn" {
  description = "Asymmetric RSA_3072 key: the plan role signs, the apply role verifies."
  value       = aws_kms_key.plan_signing.arn
}

# Values to enter as GitHub Actions repository variables. None of them are secret.
output "github_actions_variables" {
  description = "Non-secret repository variables for the GitHub Actions workflows."
  value = {
    AWS_ACCOUNT_ID       = local.account_id
    AWS_PLAN_ROLE_ARN    = aws_iam_role.ci["plan"].arn
    AWS_APPLY_ROLE_ARN   = aws_iam_role.ci["apply"].arn
    AWS_DRIFT_ROLE_ARN   = aws_iam_role.ci["drift"].arn
    PLAN_SIGNING_KEY_ARN = aws_kms_key.plan_signing.arn
    TF_STATE_BUCKET      = aws_s3_bucket.state.id
    TF_STATE_KEY         = local.state_keys.staging
  }
}
