# Regional web ACL for the ALB. Requests are allowed by default and the two rules below
# can block them. CloudWatch metrics are on and sampled requests are off.
resource "aws_wafv2_web_acl" "this" {
  name  = "${local.name_prefix}-ingress"
  scope = "REGIONAL"
  tags  = local.common_tags

  default_action {
    allow {}
  }

  # Count every source IP before the managed rules can block a request.
  rule {
    name     = "requests-per-ip"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = 1000
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-requests-per-ip"
      sampled_requests_enabled   = false
    }
  }

  # AWS managed common rule set, applied with its own actions (override_action none
  # leaves them unchanged).
  rule {
    name     = "aws-common-rules"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-aws-common-rules"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-ingress"
    sampled_requests_enabled   = false
  }
}

# Attaches the web ACL to the ALB.
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}
