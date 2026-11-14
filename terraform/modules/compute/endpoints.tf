# Interface endpoints the ECS service needs to start without internet access. The ECR pair
# lets tasks get a login token and pull the image, and SQS lets them reach the queue. They
# live here, not in networking, so a deploy that does not create the service does not
# pay for them. Each endpoint has a node in every application AZ and uses private DNS.
resource "aws_vpc_endpoint" "workload" {
  for_each = local.endpoint_policies

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.application_subnet_ids
  security_group_ids  = [var.endpoint_security_group_id]
  policy              = each.value

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-${replace(each.key, ".", "-")}-endpoint"
  })
}
