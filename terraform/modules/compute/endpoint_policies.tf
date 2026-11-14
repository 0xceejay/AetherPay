# VPC endpoint policies for ECR and SQS, applied to the endpoints in endpoints.tf. The ECR
# policies admit only the execution role and the SQS policy admits only the task role, each
# limited to the repository or queue it needs. The Secrets Manager endpoint belongs to
# networking, and the security module supplies its policy.
locals {
  ecr_endpoint_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AuthenticateExecutionRole"
        Effect    = "Allow"
        Principal = "*"
        Action    = "ecr:GetAuthorizationToken"
        Resource  = "*"
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = aws_iam_role.execution.arn
          }
        }
      },
      {
        Sid       = "PullApplicationImage"
        Effect    = "Allow"
        Principal = "*"
        Action    = local.ecr_pull_actions
        Resource  = var.ecr_repository_arn
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = aws_iam_role.execution.arn
          }
        }
      },
    ]
  })

  endpoint_policies = {
    "ecr.api" = local.ecr_endpoint_policy
    "ecr.dkr" = local.ecr_endpoint_policy

    sqs = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "ProcessIngestionQueue"
        Effect    = "Allow"
        Principal = "*"
        Action    = local.ingestion_queue_actions
        Resource  = var.ingestion_queue.arn
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = aws_iam_role.task.arn
          }
        }
      }]
    })
  }
}
