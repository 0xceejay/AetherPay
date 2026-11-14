# First part of the queue name. At most 32 lowercase letters, digits and hyphens.
variable "project_name" {
  description = "Project name used for the ingestion queue."
  type        = string
  default     = "aetherpay"
  nullable    = false

  validation {
    condition     = length(var.project_name) <= 32 && can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "Project name must be 1-32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Second part of the queue name. At most 16 characters, same character rules.
variable "environment" {
  description = "Environment name used for the ingestion queue."
  type        = string
  default     = "dev"
  nullable    = false

  validation {
    condition     = length(var.environment) <= 16 && can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "Environment must be 1-16 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Seconds a received message stays hidden. Set it above the worker's processing time, or
# messages are redelivered while still in progress.
variable "visibility_timeout_seconds" {
  description = "Time allowed for processing before an unacknowledged message becomes visible again."
  type        = number
  default     = 60
  nullable    = false

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200 && floor(var.visibility_timeout_seconds) == var.visibility_timeout_seconds
    error_message = "Visibility timeout must be an integer between 0 and 43200 seconds."
  }
}

# Receives allowed before a message moves to the dead-letter queue.
variable "max_receive_count" {
  description = "Receives allowed before a message moves to the dead-letter queue."
  type        = number
  default     = 5
  nullable    = false

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000 && floor(var.max_receive_count) == var.max_receive_count
    error_message = "Maximum receive count must be an integer between 1 and 1000."
  }
}

# Extra tags merged with the standard ones.
variable "tags" {
  description = "Additional queue tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
