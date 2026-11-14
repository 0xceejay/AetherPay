# Subnets the cache subnet group spans. Staging passes the three isolated subnets.
variable "subnet_ids" {
  description = "Existing cache subnets; staging uses the isolated tier."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.subnet_ids) > 0 && length(distinct(var.subnet_ids)) == length(var.subnet_ids)
    error_message = "Supply at least one subnet ID, without duplicates."
  }
}

# Security groups attached to the node. Staging passes the cache group, which accepts
# only the application group.
variable "security_group_ids" {
  description = "Security groups allowing cache traffic from the application only."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.security_group_ids) > 0 && length(distinct(var.security_group_ids)) == length(var.security_group_ids)
    error_message = "Supply at least one security group ID, without duplicates."
  }
}

# Name of the cluster. Keep it equal to the live cluster's ID when adopting an existing
# cache.
variable "cluster_id" {
  description = "Physical cache ID; retain the existing ID during a state refactor."
  type        = string
  default     = "aetherpay-cache"
  nullable    = false
}

# Name of the subnet group. Keep it equal to the live one when adopting an existing
# cache.
variable "subnet_group_name" {
  description = "Physical subnet-group name; retain the existing name during a state refactor."
  type        = string
  default     = "redis-subnets"
  nullable    = false
}

# Node size. Keep the live value when adopting an existing cache.
variable "node_type" {
  description = "Cache node class; retain the existing class during migration."
  type        = string
  default     = "cache.t3.micro"
  nullable    = false
}

# Redis version. Null leaves the version unmanaged, which avoids a change to an existing
# cache.
variable "engine_version" {
  description = "Optional Redis version constraint. Null leaves the existing version unmanaged; set a compatible version for a fresh cache."
  type        = string
  default     = null
}

# Parameter group. It must match the Redis major version.
variable "parameter_group_name" {
  description = "Parameter group matching the selected Redis version."
  type        = string
  default     = "default.redis7"
  nullable    = false
}

# TCP port of the node. Staging passes the same value to networking, which opens it from
# the application group.
variable "port" {
  description = "Private TCP port used by the application and cache security group."
  type        = number
  default     = 6379
  nullable    = false

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "Cache port must be an integer between 1 and 65535."
  }
}

# Applied to the cluster and subnet group exactly as given, so a state move shows no tag
# changes.
variable "tags" {
  description = "Cache and subnet-group tags, passed through unchanged for state migration."
  type        = map(string)
  default     = {}
  nullable    = false
}
