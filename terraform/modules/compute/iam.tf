# Action lists shared by the identity policies and the endpoint policies, and the trust
# policy used by both roles.
locals {
  ecr_pull_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
  ]

  ingestion_queue_actions = [
    "sqs:SendMessage",
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility",
    "sqs:GetQueueAttributes",
  ]

  ecs_tasks_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        # ECS does not support narrowing this condition to one cluster.
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
        }
      }
    }]
  })
}

# The Fargate agent pulls the image; application code uses the separate task role.
resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-execution"
  assume_role_policy = local.ecs_tasks_assume_role_policy
  tags               = local.common_tags
}

# Role assumed by the application code in the container. Its permissions are in the
# ingestor-access policy below.
resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-task"
  assume_role_policy = local.ecs_tasks_assume_role_policy
  tags               = local.common_tags
}

# Lets the execution role get an ECR login token and pull the one repository, and only
# through the two ECR VPC endpoints.
resource "aws_iam_role_policy" "execution" {
  name = "ecr-pull"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken has no repository-level resource permission.
        Sid      = "EcrAuthentication"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid      = "PullApplicationImage"
        Effect   = "Allow"
        Action   = local.ecr_pull_actions
        Resource = var.ecr_repository_arn
        Condition = {
          StringEquals = {
            "aws:SourceVpce" = [
              aws_vpc_endpoint.workload["ecr.api"].id,
              aws_vpc_endpoint.workload["ecr.dkr"].id,
            ]
          }
        }
      },
    ]
  })
}

# Permissions for the application: use the ingestion queue, read the two secrets, and
# decrypt them with the secrets key. SQS and Secrets Manager calls must come through
# their VPC endpoints. Decryption works only through Secrets Manager and only for these
# two secrets.
resource "aws_iam_role_policy" "task" {
  name = "ingestor-access"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ProcessIngestionQueue"
        Effect   = "Allow"
        Action   = local.ingestion_queue_actions
        Resource = var.ingestion_queue.arn
        Condition = {
          StringEquals = {
            "aws:SourceVpce" = aws_vpc_endpoint.workload["sqs"].id
          }
        }
      },
      {
        Sid      = "ReadApplicationSecrets"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = values(var.secret_arns)
        Condition = {
          StringEquals = {
            "aws:SourceVpce" = var.secretsmanager_endpoint_id
          }
        }
      },
      {
        # Secrets Manager calls KMS on behalf of the task, outside its VPC endpoint.
        Sid      = "DecryptApplicationSecrets"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = sort(tolist(var.secret_kms_key_arns))
        Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"
            "kms:EncryptionContext:SecretARN" = values(var.secret_arns)
          }
        }
      },
    ]
  })
}
