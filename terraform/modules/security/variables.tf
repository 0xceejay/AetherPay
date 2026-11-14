# Prefix for the key alias, secret paths, function names and role names.
variable "project_name" {
  description = "Project prefix for keys, secrets, and rotation functions."
  type        = string
  default     = "aetherpay"
  nullable    = false

  validation {
    condition     = length(var.project_name) <= 32 && can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "Project name must be 1-32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Part of those names and of the secret path <project>/<environment>/<kind>.
variable "environment" {
  description = "Environment name used in resource names and secret paths."
  type        = string
  default     = "dev"
  nullable    = false

  validation {
    condition     = length(var.environment) <= 16 && can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "Environment must be 1-16 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Subnets the rotation functions attach to. The validation requires three.
variable "application_subnet_ids" {
  description = "Three private application subnet IDs for the rotation functions."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.application_subnet_ids) == 3 && length(distinct(var.application_subnet_ids)) == 3
    error_message = "Supply three distinct private application subnets."
  }
}

# Security group on the rotation functions. It must allow outbound HTTPS to the
# endpoints and the database port.
variable "application_security_group_id" {
  description = "Application security group allowing private Secrets Manager and PostgreSQL access."
  type        = string
  nullable    = false
}

# Secrets Manager endpoint. The IAM and resource policy conditions allow secret access
# only through it.
variable "secretsmanager_endpoint_id" {
  description = "Secrets Manager interface endpoint used by compute and rotation."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^vpce-[a-f0-9]+$", var.secretsmanager_endpoint_id))
    error_message = "Supply the Secrets Manager VPC endpoint ID from networking."
  }
}

# The ingestor task role. Apart from the rotation roles, it is the only role that may
# read the secrets.
variable "application_role_arn" {
  description = "Ingestor task-role ARN permitted to read the two secrets."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", var.application_role_arn))
    error_message = "Supply one exact IAM role ARN without wildcards."
  }
}

# PostgreSQL host, port and database name passed to the database rotation function.
variable "database" {
  description = "Actual PostgreSQL host, port, and database name; credentials are seeded separately."
  type        = object({ host = string, port = number, name = string })
  nullable    = false

  validation {
    condition = (
      length(trimspace(var.database.host)) > 0 &&
      length(trimspace(var.database.name)) > 0 &&
      var.database.port >= 1 && var.database.port <= 65535 && floor(var.database.port) == var.database.port
    )
    error_message = "Supply a PostgreSQL host, database name, and integer TCP port."
  }
}

# How often Secrets Manager rotates each secret.
variable "rotation_days" {
  description = "Automatic rotation interval in days for each secret."
  type        = object({ database = number, signature = number })
  nullable    = false

  validation {
    condition     = alltrue([for days in values(var.rotation_days) : days >= 1 && days <= 1000 && floor(days) == days])
    error_message = "Rotation intervals must be integer day counts between 1 and 1000."
  }
}

# Whether the rotation schedule is attached. Turn it off only while seeding the first
# values.
variable "enable_rotation" {
  description = "True for normal operation; false only during initial secret seeding."
  type        = bool
  default     = true
  nullable    = false
}

# ZIP deployed to both functions. Defaults to .build/rotation.zip in this module.
variable "rotation_package_path" {
  description = "Optional deployment ZIP path. Otherwise uses this module's .build/rotation.zip."
  type        = string
  default     = null
}

# Extra tags merged with the standard ones.
variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
