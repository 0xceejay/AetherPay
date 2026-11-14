# ID of the VPC, for the other modules.
output "vpc_id" {
  description = "VPC identifier for downstream service modules."
  value       = aws_vpc.this.id
}

# IPv4 CIDR of the VPC.
output "vpc_cidr" {
  description = "Primary IPv4 network assigned to the VPC."
  value       = aws_vpc.this.cidr_block
}

# Subnet lists use the same AZ order across all three tiers.
output "public_subnet_ids" {
  description = "Three ALB/NAT-tier subnet IDs, sorted by AZ key."
  value       = [for k in sort(keys(aws_subnet.public)) : aws_subnet.public[k].id]

  # The internet-facing ALB needs the gateway and public routing in place.
  depends_on = [aws_route.public_internet, aws_route_table_association.public]
}

# IDs of the three private application subnets, sorted by AZ key.
output "application_subnet_ids" {
  description = "Three private app-tier subnet IDs, sorted by AZ key."
  value       = [for k in sort(keys(aws_subnet.application)) : aws_subnet.application[k].id]
  depends_on  = [aws_route_table_association.application]
}

# IDs of the three isolated subnets, sorted by AZ key.
output "database_subnet_ids" {
  description = "Three isolated database-tier subnet IDs, sorted by AZ key."
  value       = [for k in sort(keys(aws_subnet.database)) : aws_subnet.database[k].id]
  depends_on  = [aws_route_table_association.database]
}

# This exposes the CIDR allocation without needing to look up subnet IDs.
output "subnet_cidrs" {
  description = "CIDR audit table, by availability-zone key and tier."
  value = {
    for k in sort(keys(local.az_map)) : k => {
      az          = local.az_map[k].zone
      public      = aws_subnet.public[k].cidr_block
      application = aws_subnet.application[k].cidr_block
      isolated    = aws_subnet.database[k].cidr_block
    }
  }
}

# Group IDs are available to resources outside this module.
output "security_group_ids" {
  description = "Attach only the relevant group to each workload or endpoint; do not use the default VPC group."
  value = {
    alb         = aws_security_group.alb.id
    application = aws_security_group.application.id
    database    = aws_security_group.database.id
    cache       = aws_security_group.cache.id
    endpoints   = aws_security_group.endpoints.id
  }
}

# Endpoint IDs are available for the workload IAM conditions.
output "vpc_endpoint_ids" {
  description = "Private AWS service endpoints keyed by service name."
  value       = { secretsmanager = aws_vpc_endpoint.secretsmanager.id, s3 = aws_vpc_endpoint.s3.id }
}

