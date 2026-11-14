# ARNs of the database and signature secrets. No secret values.
output "secret_arns" {
  description = "Database and signature secret ARNs for compute; no secret values."
  value       = { for kind, secret in aws_secretsmanager_secret.this : kind => secret.arn }
  depends_on  = [aws_kms_key_policy.secrets]
}

# ARN of the customer-managed key used by both secrets.
output "kms_key_arn" {
  description = "Customer-managed key ARN used by the two secrets."
  value       = aws_kms_key.secrets.arn
  depends_on  = [aws_kms_key_policy.secrets]
}

# ARNs of the two rotation functions.
output "rotation_function_arns" {
  description = "Rotation Lambda ARNs, one per secret."
  value       = { for kind, function in aws_lambda_function.rotation : kind => function.arn }
}

# Secrets Manager endpoint policy. It lets the task role read the two secrets and lets
# each rotation role run the rotation actions on its own secret.
output "secretsmanager_endpoint_policy" {
  description = "Combined endpoint policy for the ingestor and the two scoped rotation roles."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Sid       = "ReadSecretsFromIngestor"
      Effect    = "Allow"
      Principal = "*"
      Action    = "secretsmanager:GetSecretValue"
      Resource  = [for secret in aws_secretsmanager_secret.this : secret.arn]
      Condition = { ArnEquals = { "aws:PrincipalArn" = var.application_role_arn } }
      }], [for kind, role in aws_iam_role.rotation : {
      Sid       = "Rotate${title(kind)}Secret"
      Effect    = "Allow"
      Principal = "*"
      Action    = local.rotation_actions
      Resource  = aws_secretsmanager_secret.this[kind].arn
      Condition = { ArnEquals = { "aws:PrincipalArn" = role.arn } }
    }])
  })
}

# IAM policy document for an identity that seeds the first secret values. It can put
# values and use the key for that, but cannot read a value.
output "seed_access_policy" {
  description = "Exact permissions for a bootstrap identity to seed values without reading them."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:PutSecretValue"]
        Resource = [for secret in aws_secretsmanager_secret.this : secret.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.secrets.arn
        Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"
            "kms:EncryptionContext:SecretARN" = [for secret in aws_secretsmanager_secret.this : secret.arn]
          }
        }
      },
    ]
  })
}
