# AetherPay networking

Three-tier, IPv4-only VPC foundation in the selected Region, `us-east-1`.
The module creates subnets, routing, security groups, and private AWS endpoints.
The ingress module supplies the ALB, TLS 1.3 listener, WAF, and rate limiting.

## Address allocation

The default VPC CIDR is `10.24.0.0/20`. Three sorted AZ names determine the
fixed `az1`, `az2`, and `az3` slots; reordering the same names preserves CIDRs.
Review resource replacements before changing an AZ or the VPC CIDR.

| Tier | az1 | az2 | az3 | Routes |
| --- | --- | --- | --- | --- |
| Public | 10.24.0.0/24 | 10.24.1.0/24 | 10.24.2.0/24 | Local and internet gateway |
| Application | 10.24.3.0/24 | 10.24.4.0/24 | 10.24.5.0/24 | Local and S3 gateway endpoint |
| Isolated | 10.24.6.0/24 | 10.24.7.0/24 | 10.24.8.0/24 | Local only |

The seven `/24` blocks from `10.24.9.0/24` through `10.24.15.0/24` remain
reserved. The isolated tier retains the `aws_subnet.database` resource name.

## Routing and access

- Every subnet has an explicit route-table association and automatic public-IP
  assignment disabled. Only the public tier has an internet default route.
- No NAT gateway, Elastic IP, or IPv6 allocation is created. ECS services use
  `assign_public_ip = false`. VPC DNS and DNS hostnames are enabled.
- The default security group has no rules. Dedicated groups allow these paths
  using configurable application, database, and cache ports:

| Source | Destination | Default TCP port |
| --- | --- | --- |
| Internet | ALB | 443 |
| ALB | Application | 8080 |
| Application | Database / cache | 5432 / 6379 |
| Application | Private API endpoints / regional S3 prefix list | 443 |

Database, cache, and endpoint groups accept only application-group traffic and
have no outbound rules; connection tracking permits responses. Default network
ACLs remain in place. Security groups restrict TCP access; they do not enable TLS.
The baseline-compatible Redis cache uses private TCP. PostgreSQL rotation uses
verified TLS, and the public ALB accepts TLS 1.3 only.

## Private AWS endpoints

The `secretsmanager` interface endpoint uses all three application subnets and private
DNS. The brief asks for private endpoints to the isolated tier and for secret access
limited to a VPC endpoint, so this endpoint is required: the secret policies deny reads
that do not come through it. The S3 gateway endpoint attaches only to the application
route table and permits `s3:GetObject` on the regional ECR image-layer bucket, with no
access to application buckets.

`secretsmanager_endpoint_policy` replaces the default deny on the Secrets Manager endpoint.
Until it is supplied, the endpoint denies all access. The ECR and SQS endpoints that the
ECS service needs belong to the compute module, which creates them with the service. They
use this module's `endpoints` security group. Push complete images to private ECR; this network does not support public image
pulls or package downloads at startup.

## Parent configuration and outputs

From `terraform/environments/staging`, use `AWS_PROFILE=ubuntu` locally:

```hcl
provider "aws" {
  region = "us-east-1"
}

module "networking" {
  source             = "../../modules/networking"
  environment        = "staging"
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  # Supply secretsmanager_endpoint_policy when the workload roles exist.
}
```

Outputs: `vpc_id`, `vpc_cidr`, `public_subnet_ids`, `application_subnet_ids`,
`database_subnet_ids`, `subnet_cidrs`, `security_group_ids`, `vpc_endpoint_ids`.

## Validation

Run `terraform fmt -check -recursive`, `terraform init -backend=false`, and
`terraform validate` from this directory. Provider installation needs network
access. [GitHub Actions](../../../.github/workflows) runs formatting, validation, TFLint, security
scanning, reviewed plans, and drift checks.
