# ARN of the Application Load Balancer.
output "alb_arn" {
  description = "Application Load Balancer ARN."
  value       = aws_lb.this.arn
}

# DNS name of the ALB, for the application's DNS alias.
output "alb_dns_name" {
  description = "Application Load Balancer DNS name for the application DNS alias."
  value       = aws_lb.this.dns_name
}

# ARN of the application target group. It resolves only after the HTTPS listener and WAF
# association exist.
output "target_group_arn" {
  description = "Application target group, available after the HTTPS listener and WAF association exist."
  value       = aws_lb_target_group.application.arn

  # ECS must not attach tasks before the target group has a listener.
  depends_on = [aws_lb_listener.https, aws_wafv2_web_acl_association.alb]
}

# ARN of the regional web ACL.
output "web_acl_arn" {
  description = "Regional web ACL ARN."
  value       = aws_wafv2_web_acl.this.arn
}
