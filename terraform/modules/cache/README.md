# AetherPay cache

Preserves the assessment's single-node Redis cache as
`aws_elasticache_cluster.redis`, with a dedicated
`aws_elasticache_subnet_group.redis_subnets`. Both resources have
`prevent_destroy`. Defaults retain `aetherpay-cache`, `redis-subnets`,
`cache.t3.micro`, `default.redis7`, and TCP port 6379.

Staging supplies isolated subnet IDs and the cache security group. The
`cache_endpoint` output reads the created node's address and port directly;
passing it to compute gives Terraform the dependency on cache creation.

This resource preserves the baseline's private TCP connection. It does not
provide Redis TLS, authentication, or high availability. Converting it to a
replication group is a separate service migration, not an address-only refactor.
See the [provider's Redis resource guidance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_cluster).

For an existing cache, keep its backend, VPC, subnet IDs, security groups,
physical names, version, node class, parameter group, port, and tags unchanged.
Tags pass through exactly as supplied, and the module adds none of its own.
`engine_version = null` leaves the existing version unmanaged instead of
requesting an upgrade. For a new cache, supply a version compatible with its
parameter-group family.

The [vulnerability audit](../../../docs/VULNERABILITY-AUDIT.md) contains the state
backup, move/import commands, and the required no-change plan check. A state move
does not relocate a cache into staging's new VPC or subnets.

[GitHub Actions](../../../.github/workflows) runs the automated checks.
