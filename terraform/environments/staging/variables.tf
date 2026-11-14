# Passed to every module. Use the same value as the bootstrap root, because the CI
# policies are built from it.
variable "project_name" {
  description = "Project prefix, matching the state bootstrap."
  type        = string
  default     = "aetherpay"
}

# Three us-east-1 AZ names. The networking module sorts them to give each AZ a fixed
# subnet slot.
variable "availability_zones" {
  description = "Three standard AZs in us-east-1."
  type        = list(string)
}

# Container port. It sets the target group port, the security group rules between the
# ALB and the tasks, and the container port mapping.
variable "application_port" {
  description = "Shared application security-group, container, and target-group port."
  type        = number
  default     = 8080
}

# Location of an existing PostgreSQL database. Its port opens the app-to-database rule
# and its host, port and name go to the rotation function. Terraform does not create the
# database.
variable "database" {
  description = "Actual PostgreSQL host, port, and database name; no credentials."
  type        = object({ host = string, port = number, name = string })
}

# Set false for a test deploy that does not need Redis. The default keeps it, because the
# application keeps its deduplication state there.
variable "enable_cache" {
  description = "Create the Redis cache. Disabling it leaves REDIS_HOST and REDIS_PORT out of the task."
  type        = bool
  default     = true
  nullable    = false
}

# Redis settings. The defaults match the legacy cache, so an existing cluster can move
# into the module without replacement.
variable "cache" {
  description = "Single-node Redis settings. Legacy adoption must preserve its actual identifiers and version."
  type = object({
    cluster_id           = optional(string, "aetherpay-cache")
    subnet_group_name    = optional(string, "redis-subnets")
    node_type            = optional(string, "cache.t3.micro")
    engine_version       = optional(string)
    parameter_group_name = optional(string, "default.redis7")
    port                 = optional(number, 6379)
  })
  default  = {}
  nullable = false
}

# Passed to the messaging module. Set it above the time a worker needs to process one
# message.
variable "queue_visibility_timeout_seconds" {
  description = "Ingestion message visibility timeout; size above the worker's processing time."
  type        = number
  default     = 60
  nullable    = false
}

# Passed to the messaging module as the number of failed receives before a message moves
# to the dead-letter queue.
variable "queue_max_receive_count" {
  description = "Failed receives before an ingestion message moves to the dead-letter queue."
  type        = number
  default     = 5
  nullable    = false
}

# ACM certificate for the HTTPS listener. It must be issued, belong to this account and
# be in us-east-1.
variable "certificate_arn" {
  description = "Issued ACM certificate in us-east-1 for the public ingestion hostname."
  type        = string
  nullable    = false
}

# Path the target group probes. The application must return 200 there.
variable "health_check_path" {
  description = "HTTP readiness endpoint served by the application."
  type        = string
  default     = "/health"
  nullable    = false
}

# ECR repository the task may pull from. The execution role and the ECR endpoint policy
# are limited to it.
variable "ecr_repository_arn" {
  description = "Private ECR repository containing the published ingestor image."
  type        = string
}

# Image the task runs. The compute module checks that it belongs to the repository
# above.
variable "image_uri" {
  description = "Published ECR image URI."
  type        = string
}

# Fargate CPU units. The compute module accepts only sizes Fargate supports.
variable "task_cpu" {
  description = "Fargate CPU units."
  type        = number
}

# Fargate memory in MiB. It must be a valid pairing with task_cpu.
variable "task_memory" {
  description = "Fargate memory in MiB."
  type        = number
}

# Lowest and highest task counts. The minimum is also the service's initial desired
# count.
variable "capacity" {
  description = "Initial/minimum and maximum task counts."
  type        = object({ min = number, max = number })
}

# Thresholds, evaluation periods and cooldowns for the scale-out and scale-in alarms.
# Scale-in must be slower than scale-out.
variable "scaling" {
  description = "Environment CPU/memory/queue thresholds and asymmetric scaling timing."
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
}

# Days between automatic rotations of the database and signature secrets.
variable "rotation_days" {
  description = "Database and signature secret rotation intervals in days."
  type        = object({ database = number, signature = number })
}

# Set to false only while seeding the first secret values. Set it back to true so the
# rotation schedule is attached.
variable "enable_rotation" {
  description = "False only for the targeted initial secret bootstrap; true for normal deployment."
  type        = bool
  default     = true
}

# Path to a prebuilt rotation ZIP. When null, the security module uses its own
# .build/rotation.zip.
variable "rotation_package_path" {
  description = "Optional prebuilt rotation ZIP path."
  type        = string
  default     = null
}

# Extra tags merged into the resources of every module.
variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}
