# EC2 network interface actions that a VPC-attached Lambda function's role needs.
locals {
  eni_actions = [
    "ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets",
    "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses",
  ]
}

# One execution role for each rotation function (database and signature), trusted by
# Lambda.
resource "aws_iam_role" "rotation" {
  for_each = local.rotation_names

  name = each.value
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

# Gives each rotation role access to its own secret only, through the Secrets Manager
# endpoint, plus the KMS permissions to encrypt that secret. The network interface
# actions apply to all resources because Lambda requires that; a deny stops the
# function's own code from using them.
resource "aws_iam_role_policy" "rotation" {
  for_each = local.rotation_names

  name = "rotate-one-secret"
  role = aws_iam_role.rotation[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RotateOwnSecretThroughPrivateEndpoint"
        Effect   = "Allow"
        Action   = local.rotation_actions
        Resource = aws_secretsmanager_secret.this[each.key].arn
        Condition = {
          StringEquals = { "aws:SourceVpce" = var.secretsmanager_endpoint_id }
        }
      },
      {
        Sid      = "EncryptOwnSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.secrets.arn
        Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"
            "kms:EncryptionContext:SecretARN" = aws_secretsmanager_secret.this[each.key].arn
          }
        }
      },
      {
        # Lambda requires these EC2 actions on all resources for its VPC interfaces.
        Sid      = "ManageLambdaVpcInterfaces"
        Effect   = "Allow"
        Action   = local.eni_actions
        Resource = "*"
      },
      {
        # Application code cannot use the service's interface-management permissions.
        Sid      = "DenyInterfaceManagementFromFunctionCode"
        Effect   = "Deny"
        Action   = local.eni_actions
        Resource = "*"
        Condition = {
          ArnEquals = { "lambda:SourceFunctionArn" = local.rotation_function_arns[each.key] }
        }
      },
    ]
  })
}

# Resource policy on each secret. It denies reads from outside the Secrets Manager VPC
# endpoint, and denies reads by any principal other than the task role and that secret's
# rotation role. Public policies are blocked.
resource "aws_secretsmanager_secret_policy" "this" {
  for_each = local.secret_names

  secret_arn          = aws_secretsmanager_secret.this[each.key].arn
  block_public_policy = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyReadsOutsidePrivateEndpoint"
        Effect    = "Deny"
        Principal = "*"
        Action    = "secretsmanager:GetSecretValue"
        Resource  = aws_secretsmanager_secret.this[each.key].arn
        Condition = {
          StringNotEquals = { "aws:SourceVpce" = var.secretsmanager_endpoint_id }
        }
      },
      {
        Sid       = "DenyReadsByOtherWorkloads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "secretsmanager:GetSecretValue"
        Resource  = aws_secretsmanager_secret.this[each.key].arn
        Condition = {
          ArnNotEquals = {
            "aws:PrincipalArn" = [var.application_role_arn, aws_iam_role.rotation[each.key].arn]
          }
        }
      },
    ]
  })
}
