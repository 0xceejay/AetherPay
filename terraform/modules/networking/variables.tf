# Prefix for all resource names. At most 32 lowercase letters, digits and hyphens.
variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "aetherpay"
  nullable    = false

  validation {
    condition     = length(var.project_name) <= 32 && can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "Project name must be 1-32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Second part of the name prefix. At most 16 characters, same character rules.
variable "environment" {
  description = "Environment name used for resource naming"
  type        = string
  default     = "dev"
  nullable    = false

  validation {
    condition     = length(var.environment) <= 16 && can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "Environment must be 1-16 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# The CIDR starts at the network address, with no host bits set.
variable "vpc_cidr" {
  description = "Canonical IPv4 /20 network, divided into nine /24 subnets and seven reserved /24 blocks."
  type        = string
  default     = "10.24.0.0/20"
  nullable    = false

  validation {
    condition = (
      can(cidrnetmask(var.vpc_cidr)) &&
      can(regex("/20$", var.vpc_cidr)) &&
      try(cidrhost(var.vpc_cidr, 0) == split("/", var.vpc_cidr)[0], false)
    )
    error_message = "VPC CIDR must be a canonical IPv4 /20 network, such as 10.24.0.0/20."
  }
}

# Three unique AZs give each tier one subnet per AZ.
variable "availability_zones" {
  description = "Exactly three distinct standard AZ names in the selected Region. Sorted names determine fixed subnet slots."
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.availability_zones) == 3 &&
      length(distinct(var.availability_zones)) == 3 &&
      alltrue([
        for az in var.availability_zones :
        can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$", az))
      ])
    )
    error_message = "Supply exactly three unique standard availability-zone names, such as us-east-1a, us-east-1b, and us-east-1c."
  }
}

# Ports can change while the security group restrictions stay in place.
variable "application_port" {
  description = "Private application and health-check port reachable only from the ALB security group."
  type        = number
  default     = 8080
  nullable    = false

  validation {
    condition     = var.application_port >= 1 && var.application_port <= 65535 && floor(var.application_port) == var.application_port
    error_message = "Application port must be an integer between 1 and 65535."
  }
}

# Port opened from the application group to the database group.
variable "database_port" {
  description = "Database connection port reachable only from the application security group."
  type        = number
  default     = 5432
  nullable    = false

  validation {
    condition     = var.database_port >= 1 && var.database_port <= 65535 && floor(var.database_port) == var.database_port
    error_message = "Database port must be an integer between 1 and 65535."
  }
}

# Port opened from the application group to the cache group.
variable "cache_port" {
  description = "Private Redis connection port reachable only from the application security group."
  type        = number
  default     = 6379
  nullable    = false

  validation {
    condition     = var.cache_port >= 1 && var.cache_port <= 65535 && floor(var.cache_port) == var.cache_port
    error_message = "Cache port must be an integer between 1 and 65535."
  }
}

# Replaces the default deny on the Secrets Manager endpoint.
variable "secretsmanager_endpoint_policy" {
  description = "JSON policy for the Secrets Manager endpoint. Null denies all access until the workload policy is supplied."
  type        = string
  default     = null

  validation {
    condition     = var.secretsmanager_endpoint_policy == null || try(jsondecode(var.secretsmanager_endpoint_policy).Version == "2012-10-17" && length(jsondecode(var.secretsmanager_endpoint_policy).Statement) > 0, false)
    error_message = "The endpoint policy must be a JSON document with Version 2012-10-17 and at least one Statement."
  }
}

# Extra tags merged with the standard ones.
variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
  nullable    = false
}
