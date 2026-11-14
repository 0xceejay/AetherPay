# Prefix for the cluster, service, task family and role names.
variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
  default     = "aetherpay"
  nullable    = false

  validation {
    condition     = length(var.project_name) <= 32 && can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "Project name must be 1-32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Second part of the name prefix, for example staging.
variable "environment" {
  description = "Environment name used for resource naming."
  type        = string
  default     = "dev"
  nullable    = false

  validation {
    condition     = length(var.environment) <= 16 && can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "Environment must be 1-16 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Subnets the tasks launch in. Staging passes the three private application subnets.
variable "application_subnet_ids" {
  description = "The three private application subnet IDs from networking."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.application_subnet_ids) == 3 && length(distinct(var.application_subnet_ids)) == 3
    error_message = "Supply three distinct application subnet IDs."
  }
}

# Security group attached to each task's network interface.
variable "application_security_group_id" {
  description = "Application security group from networking, with restricted ingress and egress."
  type        = string
  nullable    = false
}

# Port the container listens on and the target group sends traffic to.
variable "application_port" {
  description = "Container port matching the application security-group rule and ALB target group."
  type        = number
  default     = 8080
  nullable    = false

  validation {
    condition     = var.application_port >= 1 && var.application_port <= 65535 && floor(var.application_port) == var.application_port
    error_message = "Application port must be an integer between 1 and 65535."
  }
}

# Target group the service registers tasks with. Taking it from the ingress output makes
# ECS wait until the listener and WAF exist.
variable "target_group_arn" {
  description = "ALB IP target-group ARN exported after the ingress listener has been attached."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:[^:]+:elasticloadbalancing:[^:]+:[0-9]{12}:targetgroup/[A-Za-z0-9-]+/[a-f0-9]+$", var.target_group_arn))
    error_message = "Supply an ALB target-group ARN."
  }
}

# Repository the execution role may pull from. The image URI must belong to it.
variable "ecr_repository_arn" {
  description = "Exact private ECR repository ARN allowed for image pulls."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:[^:]+:ecr:[^:]+:[0-9]{12}:repository/[a-z0-9][a-z0-9._/-]*$", var.ecr_repository_arn))
    error_message = "Supply one ECR repository ARN without wildcards."
  }
}

# Image the container runs, by tag or digest. A precondition on the cluster checks the
# repository.
variable "image_uri" {
  description = "Already-published private ECR image URI, including its tag or digest."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.image_uri)) > 0 && var.image_uri == trimspace(var.image_uri)
    error_message = "Image URI must be nonempty and contain no surrounding whitespace."
  }
}

# Fargate CPU units. The validation accepts only the Linux sizes Fargate offers.
variable "task_cpu" {
  description = "Fargate CPU units; supplied by the environment."
  type        = number
  nullable    = false

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384, 32768], var.task_cpu)
    error_message = "Task CPU must be a supported Linux Fargate CPU value."
  }
}

# Task memory in MiB. The validation checks it against the allowed range for the chosen
# CPU.
variable "task_memory" {
  description = "Fargate task memory in MiB, compatible with task_cpu."
  type        = number
  nullable    = false

  validation {
    condition = try(contains({
      "256"   = [512, 1024, 2048]
      "512"   = range(1024, 4097, 1024)
      "1024"  = range(2048, 8193, 1024)
      "2048"  = range(4096, 16385, 1024)
      "4096"  = range(8192, 30721, 1024)
      "8192"  = range(16384, 61441, 4096)
      "16384" = range(32768, 122881, 8192)
      "32768" = [61440, 122880, 249856]
    }[tostring(var.task_cpu)], var.task_memory), false)
    error_message = "Task memory must be a supported MiB value for the selected Fargate CPU."
  }
}

# Lowest and highest task counts. The maximum must be greater than the minimum.
variable "capacity" {
  description = "Initial/minimum task count and autoscaling maximum."
  type        = object({ min = number, max = number })
  nullable    = false

  validation {
    condition     = var.capacity.min >= 1 && var.capacity.max > var.capacity.min && floor(var.capacity.min) == var.capacity.min && floor(var.capacity.max) == var.capacity.max
    error_message = "Capacity bounds must be positive integers, with max greater than min."
  }
}

# Redis address and port, passed to the container as REDIS_HOST and REDIS_PORT. Null leaves
# both out, for a test deploy without the cache.
variable "cache_endpoint" {
  description = "Cache address and port wired directly from the cache resource output, or null when staging runs without the cache."
  type        = object({ address = string, port = number })
  default     = null

  validation {
    condition     = var.cache_endpoint == null || (length(trimspace(var.cache_endpoint.address)) > 0 && var.cache_endpoint.port >= 1 && var.cache_endpoint.port <= 65535 && floor(var.cache_endpoint.port) == var.cache_endpoint.port)
    error_message = "Supply a cache address and an integer port between 1 and 65535."
  }
}

# Queue the tasks use. The ARN scopes IAM, the URL goes in the task environment, and the
# queue name selects the queue-depth metric.
variable "ingestion_queue" {
  description = "Existing ingestion SQS queue ARN and URL used by the app and scaling alarms."
  type        = object({ arn = string, url = string })
  nullable    = false

  validation {
    condition     = can(regex("^arn:[^:]+:sqs:[^:]+:[0-9]{12}:[A-Za-z0-9_-]+(\\.fifo)?$", var.ingestion_queue.arn))
    error_message = "Supply one SQS queue ARN without wildcards."
  }
}

# Secret ARNs placed in the task environment as DB_SECRET_ARN and SIGNATURE_SECRET_ARN.
# The application fetches the values itself.
variable "secret_arns" {
  description = "Database-credential and API-signature secret ARNs; no secret values."
  type        = object({ database = string, signature = string })
  nullable    = false

  validation {
    condition     = alltrue([for arn in values(var.secret_arns) : can(regex("^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", arn))])
    error_message = "Supply exact Secrets Manager secret ARNs without wildcards or version suffixes."
  }
}

# Keys the task role may use to decrypt those secrets.
variable "secret_kms_key_arns" {
  description = "Customer-managed key ARNs used by the referenced secrets."
  type        = set(string)
  nullable    = false

  validation {
    condition     = length(var.secret_kms_key_arns) > 0 && alltrue([for arn in var.secret_kms_key_arns : can(regex("^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/[a-f0-9-]+$", arn))])
    error_message = "Supply at least one exact KMS key ARN without wildcards."
  }
}

# VPC and endpoint security group for the ECR and SQS interface endpoints this module creates.
variable "vpc_id" {
  description = "VPC that holds the application subnets."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^vpc-[a-f0-9]+$", var.vpc_id))
    error_message = "Supply a VPC ID."
  }
}

variable "endpoint_security_group_id" {
  description = "Networking's endpoint security group, which accepts HTTPS from the application group only."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^sg-[a-f0-9]+$", var.endpoint_security_group_id))
    error_message = "Supply a security group ID."
  }
}

# The task role may read secrets only through this endpoint, which networking owns.
variable "secretsmanager_endpoint_id" {
  description = "Networking's Secrets Manager endpoint ID, used in the secret-read IAM condition."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^vpce-[a-f0-9]+$", var.secretsmanager_endpoint_id))
    error_message = "Supply a VPC endpoint ID."
  }
}

# Thresholds and capacity are environment choices, not assessment constants.
variable "scaling" {
  description = "CPU/memory percentages, visible queue-message thresholds, required one-minute samples, and cooldown seconds. Scale-in adds one reporting-lag slot."
  type = object({
    cpu_scale_out      = number
    cpu_scale_in       = number
    memory_scale_out   = number
    memory_scale_in    = number
    queue_scale_out    = number
    queue_scale_in     = number
    scale_out_periods  = number
    scale_in_periods   = number
    scale_out_cooldown = number
    scale_in_cooldown  = number
  })
  nullable = false

  validation {
    condition = alltrue([
      var.scaling.cpu_scale_in > 0 && var.scaling.cpu_scale_in < var.scaling.cpu_scale_out && var.scaling.cpu_scale_out <= 100,
      var.scaling.memory_scale_in > 0 && var.scaling.memory_scale_in < var.scaling.memory_scale_out && var.scaling.memory_scale_out <= 100,
      var.scaling.queue_scale_in > 0 && var.scaling.queue_scale_in < var.scaling.queue_scale_out,
      var.scaling.scale_out_periods >= 1 && var.scaling.scale_in_periods > var.scaling.scale_out_periods,
      var.scaling.scale_out_cooldown >= 0 && var.scaling.scale_in_cooldown > var.scaling.scale_out_cooldown,
      alltrue([for value in [var.scaling.scale_out_periods, var.scaling.scale_in_periods, var.scaling.scale_out_cooldown, var.scaling.scale_in_cooldown] : floor(value) == value]),
    ])
    error_message = "Use positive low thresholds below their high thresholds, CPU/memory at most 100%, and longer integer scale-in observation/cooldown values than scale-out."
  }
}

# Extra tags added to every resource in this module.
variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
