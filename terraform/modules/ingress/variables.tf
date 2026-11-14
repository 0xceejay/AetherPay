# Prefix for the ALB, target group and web ACL names.
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

# VPC that holds the target group.
variable "vpc_id" {
  description = "VPC containing the ALB and application targets."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^vpc-([0-9a-f]{8}|[0-9a-f]{17})$", var.vpc_id))
    error_message = "Supply a valid VPC ID."
  }
}

# Subnets for the ALB, one in each AZ.
variable "public_subnet_ids" {
  description = "Three distinct public subnet IDs, one in each availability zone."
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.public_subnet_ids) == 3 &&
      length(distinct(var.public_subnet_ids)) == 3 &&
      alltrue([for id in var.public_subnet_ids : can(regex("^subnet-([0-9a-f]{8}|[0-9a-f]{17})$", id))])
    )
    error_message = "Supply exactly three distinct public subnet IDs."
  }
}

# Security group for the ALB, created by the networking module.
variable "alb_security_group_id" {
  description = "Networking security group allowing public HTTPS and application traffic only."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^sg-([0-9a-f]{8}|[0-9a-f]{17})$", var.alb_security_group_id))
    error_message = "Supply a valid ALB security group ID."
  }
}

# ACM certificate for the HTTPS listener. The validation requires a us-east-1 ARN.
variable "certificate_arn" {
  description = "Issued ACM certificate ARN in this project and the selected Region, us-east-1."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/[0-9a-fA-F-]{36}$", var.certificate_arn))
    error_message = "Supply an ACM certificate ARN in us-east-1."
  }
}

# Port the target group forwards to.
variable "application_port" {
  description = "Private HTTP application and health-check port."
  type        = number
  default     = 8080
  nullable    = false

  validation {
    condition     = var.application_port >= 1 && var.application_port <= 65535 && floor(var.application_port) == var.application_port
    error_message = "Application port must be an integer between 1 and 65535."
  }
}

# Path the target group probes. A 200 response marks a target healthy.
variable "health_check_path" {
  description = "Application path returning HTTP 200 when ready to receive requests."
  type        = string
  default     = "/health"
  nullable    = false

  validation {
    condition     = startswith(var.health_check_path, "/") && length(var.health_check_path) <= 1024
    error_message = "Health-check path must begin with / and contain no more than 1024 characters."
  }
}

# Extra tags merged with the standard ones.
variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
  nullable    = false
}
