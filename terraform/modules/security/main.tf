# Region from the provider configuration.
data "aws_region" "current" {}
# Partition from the provider configuration.
data "aws_partition" "current" {}
# Account ID of the credentials running Terraform.
data "aws_caller_identity" "current" {}

# Names of the two secrets and the two rotation functions, the function ARNs built from
# those names, the rotation package path, the Secrets Manager actions rotation needs,
# and the key administration statement shared by both key policies.
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })
  secret_names = {
    database  = "${var.project_name}/${var.environment}/database"
    signature = "${var.project_name}/${var.environment}/signature"
  }
  rotation_names = {
    database  = "${local.name_prefix}-rotate-db"
    signature = "${local.name_prefix}-rotate-sign"
  }
  rotation_function_arns = {
    for kind, name in local.rotation_names : kind =>
    "arn:${data.aws_partition.current.partition}:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${name}"
  }
  rotation_package = coalesce(var.rotation_package_path, "${path.module}/.build/rotation.zip")
  rotation_actions = [
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetSecretValue",
    "secretsmanager:PutSecretValue",
    "secretsmanager:UpdateSecretVersionStage",
  ]

  key_admin_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DelegateKeyAdministration"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action = [
        "kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy",
        "kms:EnableKey", "kms:DisableKey", "kms:UpdateKeyDescription",
        "kms:EnableKeyRotation", "kms:DisableKeyRotation", "kms:GetKeyRotationStatus",
        "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
        "kms:TagResource", "kms:UntagResource", "kms:ListResourceTags",
        "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias",
      ]
      # In a key policy, AWS defines this as the single attached key.
      Resource = "*"
    }]
  }
}

# Customer-managed key that encrypts both secrets, with automatic rotation on and a 30
# day deletion window. The policy set here is temporary; aws_kms_key_policy.secrets
# replaces it once the secrets exist.
resource "aws_kms_key" "secrets" {
  description             = "${local.name_prefix} Secrets Manager envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  # Secret creation validates key access before its generated ARN is available.
  # This temporary grant accepts only validation calls, never secret versions.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.key_admin_policy.Statement, [{
      Sid       = "ValidateSecretKeyDuringCreation"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
      Resource  = "*"
      Condition = {
        StringEquals = {
          "kms:ViaService"                        = "secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"
          "kms:EncryptionContext:SecretVersionId" = "RequestToValidateKeyAccess"
        }
      }
    }])
  })
  tags = local.common_tags

  lifecycle {
    prevent_destroy = true
    # The separate policy adds exact secret ARNs after those secrets exist.
    ignore_changes = [policy]
  }
}

# Alias alias/<project>-<environment>-secrets for the key.
resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# Terraform manages secret metadata only. Values never pass through its state.
resource "aws_secretsmanager_secret" "this" {
  for_each = local.secret_names

  name                    = each.value
  description             = "${local.name_prefix} ${each.key} credentials"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 30
  tags                    = local.common_tags

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = split(":", var.application_role_arn)[1] == data.aws_partition.current.partition && split(":", var.application_role_arn)[4] == data.aws_caller_identity.current.account_id
      error_message = "The application role must belong to this AWS project."
    }
  }
}

# Final key policy. Management actions are delegated to IAM in this account, and Decrypt
# and GenerateDataKey work only for requests made through Secrets Manager for these two
# secrets. It is applied after the secrets exist because it names their ARNs.
resource "aws_kms_key_policy" "secrets" {
  key_id = aws_kms_key.secrets.key_id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.key_admin_policy.Statement, [{
      Sid       = "DelegateSecretEncryptionOnly"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource  = "*"
      Condition = {
        StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"
          "kms:EncryptionContext:SecretARN" = [for secret in aws_secretsmanager_secret.this : secret.arn]
        }
      }
    }])
  })
}
