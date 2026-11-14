# The groups start with no ingress or egress rules.
# Separate rule resources let the groups reference each other without a dependency cycle and avoid the drift
# caused by mixing inline and standalone rules. Connection tracking handles replies to allowed traffic.
# name_prefix plus create_before_destroy lets a replacement group exist before the old one is deleted;
# attached interfaces would otherwise block the delete.

# Security group for the ALB. It accepts HTTPS from the internet and sends traffic only
# to the application group.
resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Public HTTPS ingress and application traffic only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.common_tags, { Name = "${local.name_prefix}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Security group for the application. It accepts traffic only from the ALB group.
# Outbound access is limited to the database, cache, endpoint and S3 rules below.
resource "aws_security_group" "application" {
  name_prefix = "${local.name_prefix}-application-"
  description = "Application ingress from ALB and approved private dependencies only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.common_tags, { Name = "${local.name_prefix}-application-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Security group for the PostgreSQL target in the isolated tier. It accepts connections
# only from the application group.
resource "aws_security_group" "database" {
  name_prefix = "${local.name_prefix}-database-"
  description = "Database connections from application workloads only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.common_tags, { Name = "${local.name_prefix}-database-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Security group for Redis. It accepts connections only from the application group.
resource "aws_security_group" "cache" {
  name_prefix = "${local.name_prefix}-cache-"
  description = "Private cache connections from application workloads only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.common_tags, { Name = "${local.name_prefix}-cache-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Security group on the interface VPC endpoints. It accepts HTTPS only from the application group.
resource "aws_security_group" "endpoints" {
  name_prefix = "${local.name_prefix}-endpoints-"
  description = "Private AWS API connections from application workloads only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.common_tags, { Name = "${local.name_prefix}-endpoints-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Lets any IPv4 address reach the ALB on port 443. This is the only rule here that opens a port to the internet.
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "Public HTTPS listener"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = local.common_tags
}

# Requests and health checks use the same application port.
resource "aws_vpc_security_group_egress_rule" "alb_to_application" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward requests and health checks to application workloads"
  referenced_security_group_id = aws_security_group.application.id
  ip_protocol                  = "tcp"
  from_port                    = var.application_port
  to_port                      = var.application_port
  tags                         = local.common_tags
}

# Application side of the ALB pair: accepts forwarded requests and health checks on the
# application port, from the ALB group only.
resource "aws_vpc_security_group_ingress_rule" "application_from_alb" {
  security_group_id            = aws_security_group.application.id
  description                  = "Requests and health checks from the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.application_port
  to_port                      = var.application_port
  tags                         = local.common_tags
}

# Database and cache access is limited to the application group.
resource "aws_vpc_security_group_egress_rule" "application_to_database" {
  security_group_id            = aws_security_group.application.id
  description                  = "Private PostgreSQL connections"
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = var.database_port
  to_port                      = var.database_port
  tags                         = local.common_tags
}

# Database side of the pair: accepts the database port from the application group.
resource "aws_vpc_security_group_ingress_rule" "database_from_application" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL connections from application workloads"
  referenced_security_group_id = aws_security_group.application.id
  ip_protocol                  = "tcp"
  from_port                    = var.database_port
  to_port                      = var.database_port
  tags                         = local.common_tags
}

# Lets the application group open connections to Redis on the cache port.
resource "aws_vpc_security_group_egress_rule" "application_to_cache" {
  security_group_id            = aws_security_group.application.id
  description                  = "Private cache connections"
  referenced_security_group_id = aws_security_group.cache.id
  ip_protocol                  = "tcp"
  from_port                    = var.cache_port
  to_port                      = var.cache_port
  tags                         = local.common_tags
}

# Cache side of the pair: accepts the cache port from the application group.
resource "aws_vpc_security_group_ingress_rule" "cache_from_application" {
  security_group_id            = aws_security_group.cache.id
  description                  = "Private cache connections from application workloads"
  referenced_security_group_id = aws_security_group.application.id
  ip_protocol                  = "tcp"
  from_port                    = var.cache_port
  to_port                      = var.cache_port
  tags                         = local.common_tags
}

# AWS API traffic goes through the private endpoint group on HTTPS.
resource "aws_vpc_security_group_egress_rule" "application_to_endpoints" {
  security_group_id            = aws_security_group.application.id
  description                  = "HTTPS access to private AWS service endpoints"
  referenced_security_group_id = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  tags                         = local.common_tags
}

# Endpoint side of the pair: accepts HTTPS from the application group.
resource "aws_vpc_security_group_ingress_rule" "endpoints_from_application" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "Private AWS API access from application workloads"
  referenced_security_group_id = aws_security_group.application.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  tags                         = local.common_tags
}

# S3 gateway endpoints have no security group, so this uses the regional
# prefix list. The endpoint policy limits which objects are accessible.
resource "aws_vpc_security_group_egress_rule" "application_to_s3" {
  security_group_id = aws_security_group.application.id
  description       = "HTTPS access to S3 through the gateway endpoint"
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = local.common_tags
}
