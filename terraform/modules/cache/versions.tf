# Version pins for this module: Terraform 1.10 or later (below 2.0) and the AWS provider
# 6.x. They match the roots that call it.
terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
