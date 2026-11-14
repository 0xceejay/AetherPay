# Region from the provider configuration. The ALB precondition requires us-east-1.
data "aws_region" "current" {}
# Account ID of the credentials running Terraform. The listener precondition compares it
# with the certificate's account.
data "aws_caller_identity" "current" {}

# Name prefix and standard tags. short_name is the first 19 characters of the prefix
# plus an 8 character hash.
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  # ALB and target-group names have a 32-character limit.
  short_name = "${substr(local.name_prefix, 0, 19)}-${substr(sha256(local.name_prefix), 0, 8)}"
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })
}

# Internet-facing ALB in the three public subnets, using the ALB security group. It
# drops invalid HTTP headers and rejects traffic if WAF is unavailable (fail open is
# off). A precondition limits it to us-east-1.
resource "aws_lb" "this" {
  name                       = "${local.short_name}-alb"
  internal                   = false
  load_balancer_type         = "application"
  ip_address_type            = "ipv4"
  subnets                    = var.public_subnet_ids
  security_groups            = [var.alb_security_group_id]
  drop_invalid_header_fields = true
  enable_waf_fail_open       = false
  tags                       = local.common_tags

  lifecycle {
    precondition {
      condition     = data.aws_region.current.region == "us-east-1"
      error_message = "Ingress resources must use the project's selected Region, us-east-1."
    }
  }
}

# Fargate registers task ENI addresses after the listener and WAF are ready.
resource "aws_lb_target_group" "application" {
  name        = "${local.short_name}-app"
  vpc_id      = var.vpc_id
  port        = var.application_port
  protocol    = "HTTP"
  target_type = "ip"
  tags        = local.common_tags

  health_check {
    enabled  = true
    protocol = "HTTP"
    port     = "traffic-port"
    path     = var.health_check_path
    matcher  = "200"
  }
}

# HTTPS listener on port 443 that forwards everything to the application target group.
# It uses the TLS 1.3 only security policy and the supplied ACM certificate. A
# precondition checks that the certificate belongs to this account.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-3-2021-06"
  certificate_arn   = var.certificate_arn
  tags              = local.common_tags

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.application.arn
  }

  lifecycle {
    precondition {
      condition     = split(":", var.certificate_arn)[4] == data.aws_caller_identity.current.account_id
      error_message = "The ACM certificate must belong to this AWS project."
    }
  }
}
