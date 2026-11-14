# ARNs of the database and signature secrets, for seeding values and configuring the
# application.
output "secret_arns" {
  description = "Secret identifiers for initialization and application configuration."
  value       = module.security.secret_arns
}

# ARN of the customer-managed key that encrypts both secrets.
output "secret_kms_key_arn" {
  description = "Customer-managed secret encryption key identifier."
  value       = module.security.kms_key_arn
}

# IAM policy document giving an authorized identity just enough access to put the first
# secret values without reading them.
output "seed_access_policy" {
  description = "Scoped initialization permissions for an authorized bootstrap identity."
  value       = module.security.seed_access_policy
}

# ARNs of the two rotation Lambda functions, for rotation checks.
output "rotation_function_arns" {
  description = "Rotation function identifiers for operational checks."
  value       = module.security.rotation_function_arns
}

# ARN of the ECS cluster that runs the ingestor.
output "cluster_arn" {
  description = "Ingestor cluster identifier."
  value       = module.compute.cluster_arn
}

# Name of the ingestor ECS service, for deployment and operations commands.
output "service_name" {
  description = "Ingestor service identifier."
  value       = module.compute.service_name
}

# DNS name of the public ALB. Point the certificate's hostname at it, since HTTPS
# clients check the certificate.
output "alb_dns_name" {
  description = "Public ALB DNS name; use the certificate's hostname for HTTPS."
  value       = module.ingress.alb_dns_name
}

# ARN of the target group. It resolves only after the HTTPS listener and WAF association
# exist.
output "target_group_arn" {
  description = "Ingestor target group after listener and WAF association are ready."
  value       = module.ingress.target_group_arn
}

# ARN of the regional WAF web ACL attached to the ALB.
output "web_acl_arn" {
  description = "Regional WAF web ACL protecting the ALB."
  value       = module.ingress.web_acl_arn
}

# Address and port of the Redis node.
output "cache_endpoint" {
  description = "Provisioned private Redis address and port."
  value       = var.enable_cache ? module.cache[0].cache_endpoint : null
}

# ARN and URL of the ingestion queue.
output "ingestion_queue" {
  description = "Provisioned SQS ingestion queue ARN and URL."
  value       = module.messaging.ingestion_queue
}

# ARN and URL of the dead-letter queue.
output "dead_letter_queue" {
  description = "Ingestion dead-letter queue ARN and URL."
  value       = module.messaging.dead_letter_queue
}
