# Name prefix, standard tags, the ECR registry address built from the repository ARN,
# and the list of dependency ARNs that the cluster's precondition checks.
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })

  image_repository = "${split(":", var.ecr_repository_arn)[4]}.dkr.ecr.${split(":", var.ecr_repository_arn)[3]}.${data.aws_partition.current.dns_suffix}/${split("repository/", var.ecr_repository_arn)[1]}"
  resource_arns = concat(
    [var.ecr_repository_arn, var.ingestion_queue.arn, var.target_group_arn],
    values(var.secret_arns),
    tolist(var.secret_kms_key_arns),
  )
}

# Region from the provider configuration.
data "aws_region" "current" {}
# Partition from the provider configuration.
data "aws_partition" "current" {}
# Account ID of the credentials running Terraform.
data "aws_caller_identity" "current" {}

# ECS cluster. Its preconditions check that every dependency ARN is in this account,
# partition and Region, that the image belongs to the supplied ECR repository, and that
# the queue URL matches the queue ARN. The cluster is not created if a check fails.
resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-cluster"
  tags = local.common_tags

  lifecycle {
    precondition {
      condition = alltrue([
        for arn in local.resource_arns : try(
          split(":", arn)[1] == data.aws_partition.current.partition &&
          split(":", arn)[3] == data.aws_region.current.region &&
          split(":", arn)[4] == data.aws_caller_identity.current.account_id,
          false,
        )
      ])
      error_message = "Dependencies must belong to this AWS project and the provider's selected Region."
    }

    precondition {
      condition = (
        startswith(var.image_uri, "${local.image_repository}:") ||
        startswith(var.image_uri, "${local.image_repository}@sha256:")
      )
      error_message = "Image URI must reference the private ECR repository supplied to this module."
    }

    precondition {
      condition     = var.ingestion_queue.url == "https://sqs.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}/${data.aws_caller_identity.current.account_id}/${split(":", var.ingestion_queue.arn)[5]}"
      error_message = "Ingestion queue URL must match its ARN in this AWS project and selected Region."
    }
  }
}

# Fargate task definition for the ingestor: awsvpc networking, Linux X86_64 and one
# container. The environment holds addresses and secret ARNs only. The task role is for
# application code and the execution role is for pulling the image.
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-ingestor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "ingestor"
    image     = var.image_uri
    essential = true
    portMappings = [{
      containerPort = var.application_port
      protocol      = "tcp"
    }]

    # Only references are passed here. The app reads secret values at runtime.
    environment = concat(
      [
        { name = "AWS_REGION", value = data.aws_region.current.region },
        { name = "PORT", value = tostring(var.application_port) },
      ],
      var.cache_endpoint == null ? [] : [
        { name = "REDIS_HOST", value = var.cache_endpoint.address },
        { name = "REDIS_PORT", value = tostring(var.cache_endpoint.port) },
      ],
      [
        { name = "INGESTION_QUEUE_URL", value = var.ingestion_queue.url },
        { name = "DB_SECRET_ARN", value = var.secret_arns.database },
        { name = "SIGNATURE_SECRET_ARN", value = var.secret_arns.signature },
      ],
    )
  }])

  tags = local.common_tags
}

# Runs the task on Fargate in the application subnets with no public IP, registered with
# the ALB target group. The desired count starts at the minimum capacity; ignore_changes
# leaves later changes to the autoscaler.
resource "aws_ecs_service" "app" {
  name             = "${local.name_prefix}-ingestor"
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.capacity.min
  launch_type      = "FARGATE"
  platform_version = "1.4.0"

  network_configuration {
    subnets          = var.application_subnet_ids
    security_groups  = [var.application_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "ingestor"
    container_port   = var.application_port
  }

  # Permissions are attached before the first task starts.
  depends_on = [aws_iam_role_policy.execution, aws_iam_role_policy.task]

  lifecycle {
    # Terraform owns the service configuration; the autoscaler owns its count.
    ignore_changes = [desired_count]
  }

  tags = local.common_tags
}
