# All staging resources are created in us-east-1, the project's selected Region.
provider "aws" {
  region = "us-east-1"
}

# Standard tags. Only the cache module receives these directly, because it does not
# build its own tags; the other modules merge the same keys themselves.
locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = "staging"
    ManagedBy   = "Terraform"
  })
}

# VPC, subnets, route tables, security groups, the Secrets Manager endpoint and the S3
# gateway endpoint. The Secrets Manager endpoint policy comes from the security module,
# because it also covers the rotation roles. Compute creates the ECR and SQS endpoints.
module "networking" {
  source                         = "../../modules/networking"
  project_name                   = var.project_name
  environment                    = "staging"
  availability_zones             = var.availability_zones
  application_port               = var.application_port
  database_port                  = var.database.port
  cache_port                     = var.cache.port
  secretsmanager_endpoint_policy = module.security.secretsmanager_endpoint_policy
  tags                           = var.tags
}

# Public ALB with the TLS 1.3 HTTPS listener, the target group and the regional WAF web
# ACL, placed in the public subnets.
module "ingress" {
  source                = "../../modules/ingress"
  project_name          = var.project_name
  environment           = "staging"
  vpc_id                = module.networking.vpc_id
  public_subnet_ids     = module.networking.public_subnet_ids
  alb_security_group_id = module.networking.security_group_ids.alb
  certificate_arn       = var.certificate_arn
  application_port      = var.application_port
  health_check_path     = var.health_check_path
  tags                  = var.tags
}

# Single-node Redis in the isolated subnets, reachable only through the cache security
# group. Names and sizes come from var.cache so an existing cache can be adopted
# unchanged.
module "cache" {
  count                = var.enable_cache ? 1 : 0
  source               = "../../modules/cache"
  subnet_ids           = module.networking.database_subnet_ids
  security_group_ids   = [module.networking.security_group_ids.cache]
  cluster_id           = var.cache.cluster_id
  subnet_group_name    = var.cache.subnet_group_name
  node_type            = var.cache.node_type
  engine_version       = var.cache.engine_version
  parameter_group_name = var.cache.parameter_group_name
  port                 = var.cache.port
  tags                 = local.common_tags
}

# The cache module gained a count, so an existing state keeps its resources at the new address.
moved {
  from = module.cache
  to   = module.cache[0]
}

# Ingestion SQS queue and its dead-letter queue.
module "messaging" {
  source                     = "../../modules/messaging"
  project_name               = var.project_name
  environment                = "staging"
  visibility_timeout_seconds = var.queue_visibility_timeout_seconds
  max_receive_count          = var.queue_max_receive_count
  tags                       = var.tags
}

# ECS cluster, Fargate service, IAM roles and autoscaling for the ingestor. It takes the
# cache address from cache, the queue from messaging, the secret ARNs from security and
# the target group from ingress, so Terraform creates those first.
module "compute" {
  source                        = "../../modules/compute"
  project_name                  = var.project_name
  environment                   = "staging"
  application_subnet_ids        = module.networking.application_subnet_ids
  application_security_group_id = module.networking.security_group_ids.application
  application_port              = var.application_port
  vpc_id                        = module.networking.vpc_id
  endpoint_security_group_id    = module.networking.security_group_ids.endpoints
  secretsmanager_endpoint_id    = module.networking.vpc_endpoint_ids.secretsmanager
  secret_arns                   = module.security.secret_arns
  secret_kms_key_arns           = [module.security.kms_key_arn]
  target_group_arn              = module.ingress.target_group_arn
  ecr_repository_arn            = var.ecr_repository_arn
  image_uri                     = var.image_uri
  task_cpu                      = var.task_cpu
  task_memory                   = var.task_memory
  capacity                      = var.capacity
  cache_endpoint                = var.enable_cache ? module.cache[0].cache_endpoint : null
  ingestion_queue               = module.messaging.ingestion_queue
  scaling                       = var.scaling
  tags                          = var.tags
}

# KMS key, the database and signature secrets, their rotation Lambda functions and
# resource policies. It takes the task role ARN from compute so each secret policy can
# name the one role allowed to read it.
module "security" {
  source                        = "../../modules/security"
  project_name                  = var.project_name
  environment                   = "staging"
  application_subnet_ids        = module.networking.application_subnet_ids
  application_security_group_id = module.networking.security_group_ids.application
  secretsmanager_endpoint_id    = module.networking.vpc_endpoint_ids.secretsmanager
  application_role_arn          = module.compute.role_arns.task
  database                      = var.database
  rotation_days                 = var.rotation_days
  enable_rotation               = var.enable_rotation
  rotation_package_path         = var.rotation_package_path
  tags                          = var.tags
}
