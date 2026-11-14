# Ingress

An internet-facing IPv4 ALB spans the three public subnets. Its only listener is HTTPS on port 443, using `ELBSecurityPolicy-TLS13-1-3-2021-06` to accept TLS 1.3 exclusively. The networking module supplies the ALB security group and restricts task access to traffic from that group. Tasks stay in private subnets with no public IPs.

Supply an issued ACM certificate in this AWS project and `us-east-1`. The application hostname must match the certificate; its DNS record must point to the ALB. Certificate issuance and DNS records remain external inputs. The ALB forwards HTTP to the application port, defaulting to 8080. The health endpoint, `/health` by default, must return HTTP 200 without authentication.

The regional WAF blocks requests matching `AWSManagedRulesCommonRuleSet`. A preceding rate rule blocks source IPs exceeding 1,000 requests in a 300-second evaluation window. AWS WAF enforces rates approximately, so this is a flood-protection threshold rather than an exact application quota. Source IP means the direct ALB client; no forwarded-IP header is trusted. WAF failure does not allow requests to bypass inspection. Metrics are enabled, and request sampling is disabled.

Inputs are `vpc_id`, three distinct `public_subnet_ids`, `alb_security_group_id`, and `certificate_arn`. Optional inputs are `project_name` (`aetherpay`), `environment` (`dev`), `application_port` (`8080`), `health_check_path` (`/health`), and `tags` (`{}`). All resources use the caller's AWS provider in `us-east-1`.

Outputs are `alb_arn`, `alb_dns_name`, `target_group_arn`, and `web_acl_arn`. Pass `target_group_arn` directly to compute: its output dependencies ensure the listener and WAF association exist before ECS registers tasks.

After deployment, use the certificate hostname and SNI to verify that TLS 1.3 connects and TLS 1.2 fails. Confirm healthy target IPs and the WAF association, then check WAF block metrics with controlled test traffic. ALB, target-group, and WAF behavior must be verified against deployed resources.

References: [ALB TLS policies](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/describe-ssl-policies.html), [WAF rate settings](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based-high-level-settings.html).
