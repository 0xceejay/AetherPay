# The deny-all policy used until the security module supplies the Secrets Manager policy.
locals {
  # Access stays closed until a workload policy is supplied.
  # This replaces AWS's default full-access endpoint policy.
  deny_all_endpoint_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUntilWorkloadPoliciesAreConfigured"
      Effect    = "Deny"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
    }]
  })
}

# The Secrets Manager endpoint has a node in every application AZ. Private DNS resolves
# the service name to it. The ECR and SQS endpoints belong to the compute module, so they
# exist only when the ECS service does.
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids = [
    for az_key in sort(keys(local.az_map)) : aws_subnet.application[az_key].id
  ]
  security_group_ids = [aws_security_group.endpoints.id]
  policy             = coalesce(var.secretsmanager_endpoint_policy, local.deny_all_endpoint_policy)

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-secretsmanager-endpoint"
  })
}

# Only application subnets use this gateway endpoint.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.application.id]

  # ECR uses presigned S3 URLs for image layers. The policy allows the signing
  # principal and limits access to GetObject on the layer bucket.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ReadRegionalECRImageLayers"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "arn:${data.aws_partition.current.partition}:s3:::prod-${data.aws_region.current.region}-starport-layer-bucket/*"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-s3-endpoint"
  })
}
