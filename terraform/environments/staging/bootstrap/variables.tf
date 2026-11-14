# Prefix for the state bucket, the CI roles and their policies. Use the same value as
# the staging root.
variable "project_name" {
  description = "Project prefix for the state bucket."
  type        = string
  default     = "aetherpay"
  nullable    = false

  validation {
    condition     = length(var.project_name) <= 32 && can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "Project name must be 1-32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Extra tags for the state bucket. Project, ManagedBy and Purpose tags are added
# automatically.
variable "tags" {
  description = "Additional state bucket tags."
  type        = map(string)
  default     = {}
  nullable    = false
}

# owner/repo that the default OIDC subjects are built from. Only workflows from this
# repository can assume the CI roles.
variable "github_repository" {
  description = "GitHub owner/repository whose Actions jobs may assume the CI roles."
  type        = string
  default     = "0xceejay/AetherPay"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Use the exact owner/repository name."
  }
}

# Numeric IDs that make the default subjects immutable (owner@ID/repo@ID), so a
# renamed or recreated repository cannot reuse the trust. Look them up with
# `gh api repos/OWNER/REPO --jq '.owner.id, .id'`. They default to an empty string so
# tools that read the code without a variable file, such as TFLint, can still evaluate
# the subject strings. Validation requires real values when the roles are planned.
variable "github_owner_id" {
  description = "Numeric ID of the GitHub repository owner, used in the immutable OIDC subjects."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.github_owner_id == "" || can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "The owner ID must be a number."
  }

  validation {
    condition     = var.github_oidc_subjects != null || (can(regex("^[0-9]+$", var.github_owner_id)) && can(regex("^[0-9]+$", var.github_repository_id)))
    error_message = "Set github_owner_id and github_repository_id, or set github_oidc_subjects."
  }
}

variable "github_repository_id" {
  description = "Numeric ID of the GitHub repository, used in the immutable OIDC subjects."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.github_repository_id == "" || can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "The repository ID must be a number."
  }
}

# Optional override for the exact token subjects each role trusts. Null builds the
# immutable defaults from github_repository and the two IDs above. The validation
# rejects wildcards.
variable "github_oidc_subjects" {
  description = "Exact GitHub OIDC subjects. Null builds immutable owner@ID/repo@ID subjects from github_owner_id and github_repository_id."
  type = object({
    pull_request = string
    main         = string
  })
  default  = null
  nullable = true

  validation {
    condition = alltrue([
      for subject in try(values(var.github_oidc_subjects), []) :
      startswith(subject, "repo:") && !strcontains(subject, "*")
    ])
    error_message = "Subjects must be exact repo:... values without wildcards."
  }
}

# Set this when the account already has a GitHub OIDC provider. Null makes this root
# create one.
variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN in this project. Null creates the provider; an account has at most one per issuer URL."
  type        = string
  default     = null

  validation {
    condition     = var.github_oidc_provider_arn == null || can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "Supply the GitHub Actions OIDC provider ARN."
  }
}

# Redis identifiers the apply role may manage. They must equal the cache input of the
# staging root, because the IAM resource ARNs are built from them.
variable "staging_cache_names" {
  description = "Physical Redis identifiers used by staging, matching its cache input."
  type = object({
    cluster_id        = optional(string, "aetherpay-cache")
    subnet_group_name = optional(string, "redis-subnets")
  })
  default  = {}
  nullable = false
}
