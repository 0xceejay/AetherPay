# Version pins for this root: Terraform 1.10 or later (below 2.0) and the AWS provider
# 6.x.
terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
