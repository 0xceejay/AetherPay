# Address and port of the Redis node. The compute module passes them to the task as
# REDIS_HOST and REDIS_PORT.
output "cache_endpoint" {
  description = "Actual Redis node endpoint for the application's task definition."
  value = {
    address = aws_elasticache_cluster.redis.cache_nodes[0].address
    port    = aws_elasticache_cluster.redis.port
  }
}

# Physical cluster ID, for checking that it matches the legacy cache after a state move.
output "cluster_id" {
  description = "Physical Redis cluster ID."
  value       = aws_elasticache_cluster.redis.cluster_id
}

# Physical subnet group name, for the same check.
output "subnet_group_name" {
  description = "Physical cache subnet-group name."
  value       = aws_elasticache_subnet_group.redis_subnets.name
}
