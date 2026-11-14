# AetherPay compute

One ECS Fargate ingestor service in the three private application subnets.
The module creates its cluster, task definition, service, workload roles, and
CPU/memory/SQS scaling policies. The service has no public IP.

## Dependencies and inputs

The environment supplies the following resources before the service can run:

| Input | Source |
| --- | --- |
| `application_subnet_ids`, `application_security_group_id` | Networking outputs |
| `vpc_id`, `endpoint_security_group_id` | Networking outputs, used for the ECR and SQS endpoints this module creates |
| `secretsmanager_endpoint_id` | Networking's Secrets Manager endpoint, used in the secret-read IAM condition |
| `target_group_arn` | An ALB target group with target type `ip`, attached to its listener |
| `ecr_repository_arn`, `image_uri` | A private ECR repository and an already-published image |
| `cache_endpoint` | The cache resource's actual address and port |
| `ingestion_queue` | SQS queue ARN and URL |
| `secret_arns` | Database and API-signature Secrets Manager ARNs |
| `secret_kms_key_arns` | Customer-managed keys used by those secrets |
| `task_cpu`, `task_memory`, `capacity`, `scaling` | Environment sizing and scaling settings |

Regional dependencies must be in this AWS project and the provider's selected
Region, `us-east-1`. Image URI and queue URL must match their supplied ARNs.
Staging supplies secrets and keys from security, the queue from messaging, the
cache endpoint from cache, and ALB/WAF from ingress. Image publishing and the
PostgreSQL target remain external prerequisites.

`cache_endpoint` must come from a resource attribute so Terraform preserves the
dependency. For the assessment's existing cache resource, the wiring is:

```hcl
cache_endpoint = {
  address = aws_elasticache_cluster.redis.cache_nodes[0].address
  port    = aws_elasticache_cluster.redis.port
}
```

Ingress exports `target_group_arn` with output dependencies on its HTTPS listener
and WAF association. ECS waits for these before creating the service. The target
group port matches `application_port` and the networking rule, defaulting to 8080.

## Private API access

The execution role can authenticate to ECR and pull only the selected repository.
`ecr:GetAuthorizationToken` uses `Resource = "*"` because AWS does not support a
repository resource for that action. The application role has no ECR permissions.

The task role can process only the supplied ingestion queue, read only the two
supplied secrets through the Secrets Manager endpoint, and decrypt their keys
through Secrets Manager with the matching secret encryption context. The key
policies must also authorize this use. There are no application S3 permissions.

The module creates the `ecr.api`, `ecr.dkr`, and `sqs` interface endpoints in the
application subnets, so they exist only when the service does. Each endpoint policy
admits the ingestor's corresponding role: the execution role for ECR and the task role
for SQS. The Secrets Manager endpoint stays in networking, and the security module
supplies its policy, which also admits the two scoped rotation roles.

The parent configuration connects the modules using:

```hcl
# Inside module "networking":
secretsmanager_endpoint_policy = module.security.secretsmanager_endpoint_policy

# Inside module "compute":
application_subnet_ids        = module.networking.application_subnet_ids
application_security_group_id = module.networking.security_group_ids.application
vpc_id                        = module.networking.vpc_id
endpoint_security_group_id    = module.networking.security_group_ids.endpoints
secretsmanager_endpoint_id    = module.networking.vpc_endpoint_ids.secretsmanager
```

Role creation does not depend on any endpoint. Only the attached IAM permissions and
the endpoint policies reference each other, through the roles, so there is no cycle.
Module-level `depends_on` between networking and compute would introduce one.

Outputs: `cluster_arn`, `service_name`, `task_definition_arn`, and `role_arns`.
No secret values are exported.

From this directory, run `terraform fmt -check -recursive`,
`terraform init -backend=false`, and `terraform validate`. [GitHub Actions](../../../.github/workflows) runs
validation, TFLint, and security scanning on every pull request. No custom
Terraform test suite is included.

References: [ECS step scaling](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-autoscaling-stepscaling.html),
[metric math and missing samples](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/using-metric-math.html),
[task execution permissions](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html),
and [Secrets Manager encryption](https://docs.aws.amazon.com/secretsmanager/latest/userguide/security-encryption.html).
