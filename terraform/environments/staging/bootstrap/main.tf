# Everything in this root is created in us-east-1, the project's selected Region.
provider "aws" {
  region = "us-east-1"
}

# Account ID of the credentials running Terraform. It goes into the state bucket name.
data "aws_caller_identity" "current" {}

# State object keys for the two roots (bootstrap and staging), expanded into the S3
# object ARNs for each state file and its .tflock lock file. The bucket policy uses
# these ARNs.
locals {
  state_keys = {
    bootstrap = "bootstrap/terraform.tfstate"
    staging   = "staging/terraform.tfstate"
  }
  state_object_arns = flatten([
    for key in values(local.state_keys) :
    ["${aws_s3_bucket.state.arn}/${key}", "${aws_s3_bucket.state.arn}/${key}.tflock"]
  ])
}

# Bucket that holds remote state for the bootstrap and staging roots. The name includes
# the account ID and Region to keep it globally unique. force_destroy is off and
# prevent_destroy is on, so a destroy run cannot delete the state.
resource "aws_s3_bucket" "state" {
  bucket        = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}-us-east-1"
  force_destroy = false
  tags = merge(var.tags, {
    Project   = var.project_name
    ManagedBy = "Terraform"
    Purpose   = "terraform-state"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# Turns on all four S3 public access blocks for the state bucket.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# BucketOwnerEnforced disables ACLs, so only IAM and the bucket policy decide who has
# access.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Keeps every earlier version of each state object, so an older state can be restored
# after a bad write.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# The assessment requires a customer-managed key for secrets, not state storage.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Denies listing, reading, writing and deleting on the bucket, the state files and the
# lock files when the request does not use TLS.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RequireTlsForStateAndLocks"
      Effect    = "Deny"
      Principal = "*"
      Action    = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource  = concat([aws_s3_bucket.state.arn], local.state_object_arns)
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.state]
}
