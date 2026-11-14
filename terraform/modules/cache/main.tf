# The resource names stay the same as the baseline so only their module addresses move.
resource "aws_elasticache_subnet_group" "redis_subnets" {
  name       = var.subnet_group_name
  subnet_ids = var.subnet_ids
  tags       = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# This preserves the single-node Redis baseline and uses private TCP, without TLS.
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = var.cluster_id
  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_nodes      = 1
  parameter_group_name = var.parameter_group_name
  port                 = var.port
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnets.name
  security_group_ids   = var.security_group_ids
  tags                 = var.tags

  lifecycle {
    prevent_destroy = true
  }
}
