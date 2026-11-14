# S3 backend with encryption and S3 native locking (use_lockfile). The bucket and key
# are not set here; they are supplied when running terraform init.
terraform {
  backend "s3" {
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
