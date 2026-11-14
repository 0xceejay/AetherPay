# GitHub Actions identity: OIDC federation, three purpose-specific roles, and the
# asymmetric key that signs saved plans. An administrator applies this root once;
# the pipeline then needs no stored AWS credentials.

# Partition of the current credentials, used when building ARNs.
data "aws_partition" "current" {}

# Values shared by the CI resources: account, partition and Region, tags, the OIDC
# subjects each role trusts, the state-bucket policies, and the staging ARN patterns
# that the refresh and deploy policies use.
locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = "us-east-1"

  ci_tags = merge(var.tags, {
    Project   = var.project_name
    ManagedBy = "Terraform"
    Purpose   = "github-actions"
  })

  # Immutable subjects: repo:OWNER@OWNER_ID/REPO@REPO_ID:...
  github_owner = split("/", var.github_repository)[0]
  github_repo  = split("/", var.github_repository)[1]
  github_subjects = var.github_oidc_subjects != null ? var.github_oidc_subjects : {
    pull_request = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo}@${var.github_repository_id}:pull_request"
    main         = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo}@${var.github_repository_id}:ref:refs/heads/main"
  }
  github_oidc_provider_arn = coalesce(var.github_oidc_provider_arn, try(aws_iam_openid_connect_provider.github[0].arn, null))

  # Plan runs for trusted PRs and for regeneration on main; apply and drift run on main only.
  ci_role_subjects = {
    plan  = [local.github_subjects.pull_request, local.github_subjects.main]
    apply = [local.github_subjects.main]
    drift = [local.github_subjects.main]
  }
  ci_role_names = { for role in keys(local.ci_role_subjects) : role => "${var.project_name}-ci-${role}" }
  # Built from names, not resource references, so the key policy can name the roles
  # without a dependency cycle.
  ci_role_arns = { for role, name in local.ci_role_names : role => "arn:${local.partition}:iam::${local.account_id}:role/${name}" }

  kms_key_admin_actions = [
    "kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:GetKeyRotationStatus",
    "kms:EnableKey", "kms:DisableKey", "kms:UpdateKeyDescription",
    "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
    "kms:TagResource", "kms:UntagResource", "kms:ListResourceTags",
    "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias",
  ]

  # State access. Plan and drift may only take and release the lock; apply may write state.
  state_policies = {
    for name, key in local.state_keys : name => {
      for access in ["read_only", "read_write"] : access => jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "ListStateBucket"
            Effect   = "Allow"
            Action   = "s3:ListBucket"
            Resource = aws_s3_bucket.state.arn
          },
          {
            Sid      = access == "read_write" ? "ReadWriteState" : "ReadState"
            Effect   = "Allow"
            Action   = access == "read_write" ? ["s3:GetObject", "s3:PutObject"] : ["s3:GetObject"]
            Resource = "${aws_s3_bucket.state.arn}/${key}"
          },
          {
            Sid      = "ManageStateLock"
            Effect   = "Allow"
            Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
            Resource = "${aws_s3_bucket.state.arn}/${key}.tflock"
          },
        ]
      })
    }
  }

  # Physical names created by the staging modules.
  staging        = "${var.project_name}-staging"
  staging_alb    = "${substr(local.staging, 0, 19)}-"
  arn_prefix     = "arn:${local.partition}"
  regional       = "${local.region}:${local.account_id}"
  staging_lb     = "${local.arn_prefix}:elasticloadbalancing:${local.regional}:loadbalancer/app/${local.staging_alb}*"
  staging_tg     = "${local.arn_prefix}:elasticloadbalancing:${local.regional}:targetgroup/${local.staging_alb}*"
  staging_lsn    = "${local.arn_prefix}:elasticloadbalancing:${local.regional}:listener/app/${local.staging_alb}*"
  staging_webacl = "${local.arn_prefix}:wafv2:${local.regional}:regional/webacl/${local.staging}-ingress/*"
  staging_ecs = [
    "${local.arn_prefix}:ecs:${local.regional}:cluster/${local.staging}-cluster",
    "${local.arn_prefix}:ecs:${local.regional}:service/${local.staging}-cluster/${local.staging}-ingestor",
    "${local.arn_prefix}:ecs:${local.regional}:task-definition/${local.staging}-ingestor:*",
  ]
  staging_queues = "${local.arn_prefix}:sqs:${local.regional}:${local.staging}-ingestion*"
  staging_alarms = "${local.arn_prefix}:cloudwatch:${local.regional}:alarm:${local.staging}-*"
  staging_cache = [
    "${local.arn_prefix}:elasticache:${local.regional}:cluster:${var.staging_cache_names.cluster_id}",
    "${local.arn_prefix}:elasticache:${local.regional}:subnetgroup:${var.staging_cache_names.subnet_group_name}",
    "${local.arn_prefix}:elasticache:${local.regional}:parametergroup:default.*",
  ]
  staging_ecs_roles = [
    "${local.arn_prefix}:iam::${local.account_id}:role/${local.staging}-execution",
    "${local.arn_prefix}:iam::${local.account_id}:role/${local.staging}-task",
  ]
  staging_rotation_roles = [
    "${local.arn_prefix}:iam::${local.account_id}:role/${local.staging}-rotate-db",
    "${local.arn_prefix}:iam::${local.account_id}:role/${local.staging}-rotate-sign",
  ]
  staging_functions = [
    "${local.arn_prefix}:lambda:${local.regional}:function:${local.staging}-rotate-db",
    "${local.arn_prefix}:lambda:${local.regional}:function:${local.staging}-rotate-sign",
  ]
  staging_secrets = "${local.arn_prefix}:secretsmanager:${local.regional}:secret:${var.project_name}/staging/*"
  staging_keys    = "${local.arn_prefix}:kms:${local.regional}:key/*"
  staging_alias   = "${local.arn_prefix}:kms:${local.regional}:alias/${local.staging}-secrets"

  in_region = { StringEquals = { "aws:RequestedRegion" = local.region } }
  # The security module tags its CMK with these values. The plan-signing key has
  # no Environment tag, so these statements cannot reach it.
  staging_key_tags = {
    StringEquals = {
      "aws:ResourceTag/Project"     = var.project_name
      "aws:ResourceTag/Environment" = "staging"
    }
  }
}

# Registers GitHub's token issuer with IAM so workflows can exchange their OIDC token
# for AWS credentials. It is created only when no existing provider ARN is supplied
# (count is 0 or 1).
resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_oidc_provider_arn == null ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.ci_tags
}

# One role each for plan, apply and drift. A role can be assumed only by a GitHub token
# whose audience is sts.amazonaws.com and whose subject exactly matches one of that
# role's subjects. Sessions last at most one hour.
resource "aws_iam_role" "ci" {
  for_each = local.ci_role_subjects

  name                 = local.ci_role_names[each.key]
  description          = "GitHub Actions ${each.key} for ${var.github_repository} staging"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubActionsExactSubjects"
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = each.value
        }
      }
    }]
  })
  tags = local.ci_tags
}

# RSA 3072 key used only to sign and verify. The key policy lets the plan role sign and
# the apply role verify, and account administrators manage the key. Automatic rotation
# is off because AWS does not rotate asymmetric keys.
resource "aws_kms_key" "plan_signing" {
  description              = "${var.project_name} CI Terraform plan signing"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "RSA_3072"
  deletion_window_in_days  = 30
  # AWS does not rotate asymmetric keys automatically.
  enable_key_rotation = false
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DelegateKeyAdministration"
        Effect    = "Allow"
        Principal = { AWS = "${local.arn_prefix}:iam::${local.account_id}:root" }
        Action    = local.kms_key_admin_actions
        # In a key policy, "*" means this key only.
        Resource = "*"
      },
      {
        Sid       = "PlanRoleSignsOnly"
        Effect    = "Allow"
        Principal = { AWS = "${local.arn_prefix}:iam::${local.account_id}:root" }
        Action    = ["kms:DescribeKey", "kms:Sign"]
        Resource  = "*"
        Condition = { ArnEquals = { "aws:PrincipalArn" = local.ci_role_arns.plan } }
      },
      {
        Sid       = "ApplyRoleVerifiesOnly"
        Effect    = "Allow"
        Principal = { AWS = "${local.arn_prefix}:iam::${local.account_id}:root" }
        Action    = ["kms:DescribeKey", "kms:Verify"]
        Resource  = "*"
        Condition = { ArnEquals = { "aws:PrincipalArn" = local.ci_role_arns.apply } }
      },
    ]
  })
  tags = merge(local.ci_tags, { Purpose = "terraform-plan-signing" })

  lifecycle {
    prevent_destroy = true
  }
}

# Two policies, read_only and read_write, built from the staging state policy documents.
# Both allow taking and releasing the lock file.
resource "aws_iam_policy" "state" {
  for_each = { read_only = "Read staging state and manage its lock", read_write = "Read and write staging state and manage its lock" }

  name        = "${var.project_name}-ci-state-${replace(each.key, "_", "-")}"
  description = each.value
  policy      = local.state_policies.staging[each.key]
  tags        = local.ci_tags
}

# Gives the plan role kms:Sign and the apply role kms:Verify, each limited to the
# plan-signing key.
resource "aws_iam_policy" "plan_signing" {
  for_each = { plan = "kms:Sign", apply = "kms:Verify" }

  name        = "${var.project_name}-ci-${each.key}-signing"
  description = "${each.value} with the plan-signing key only"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "UsePlanSigningKey"
      Effect   = "Allow"
      Action   = ["kms:DescribeKey", each.value]
      Resource = aws_kms_key.plan_signing.arn
    }]
  })
  tags = local.ci_tags
}

# Read-only access to refresh every staging resource. No secret values, decryption,
# or queue messages.
resource "aws_iam_policy" "refresh" {
  name        = "${var.project_name}-ci-staging-refresh"
  description = "Refresh staging resources for plan, apply, and drift"
  tags        = local.ci_tags
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # These describe/list operations have no resource-level permissions.
        Sid    = "DescribeRegionalMetadata"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones", "ec2:DescribeVpcs", "ec2:DescribeVpcAttribute",
          "ec2:DescribeSubnets", "ec2:DescribeRouteTables", "ec2:DescribeInternetGateways",
          "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "ec2:DescribeNetworkAcls",
          "ec2:DescribeVpcEndpoints", "ec2:DescribeVpcEndpointServices", "ec2:DescribePrefixLists",
          "ec2:DescribeNetworkInterfaces",
          "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTags",
          "ecs:DescribeTaskDefinition",
          "application-autoscaling:DescribeScalableTargets", "application-autoscaling:DescribeScalingPolicies",
          "application-autoscaling:ListTagsForResource",
          "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
          "elasticache:DescribeCacheClusters", "elasticache:DescribeCacheSubnetGroups",
          "elasticache:ListTagsForResource",
          # Alias metadata only: no signing, decryption, or key changes.
          "kms:ListAliases",
        ]
        Resource  = "*"
        Condition = local.in_region
      },
      {
        Sid      = "ReadStagingWorkloads"
        Effect   = "Allow"
        Action   = ["ecs:DescribeClusters", "ecs:DescribeServices", "ecs:ListTagsForResource"]
        Resource = local.staging_ecs
      },
      {
        Sid      = "ReadStagingQueueMetadata"
        Effect   = "Allow"
        Action   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueueTags"]
        Resource = local.staging_queues
      },
      {
        Sid      = "ReadStagingWebAcl"
        Effect   = "Allow"
        Action   = ["wafv2:GetWebACL", "wafv2:ListTagsForResource"]
        Resource = [local.staging_webacl, local.staging_lb]
      },
      {
        # GetWebACLForResource asks which web ACL protects a load balancer, so AWS checks it
        # against every regional web ACL in this account, not the one named in the request. A
        # statement scoped to the staging ACL can never match. It is read-only and limited to
        # this account and Region.
        Sid      = "FindWebAclForLoadBalancer"
        Effect   = "Allow"
        Action   = "wafv2:GetWebACLForResource"
        Resource = "${local.arn_prefix}:wafv2:${local.regional}:regional/webacl/*/*"
      },
      {
        Sid      = "ReadStagingWorkloadRoles"
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
        Resource = concat(local.staging_ecs_roles, local.staging_rotation_roles)
      },
      {
        Sid    = "ReadStagingRotationFunctions"
        Effect = "Allow"
        Action = [
          "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:GetFunctionCodeSigningConfig",
          "lambda:GetFunctionRecursionConfig", "lambda:ListVersionsByFunction", "lambda:GetPolicy", "lambda:ListTags",
        ]
        Resource = local.staging_functions
      },
      {
        Sid      = "ReadStagingSecretMetadataOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy"]
        Resource = local.staging_secrets
      },
      {
        Sid       = "ReadStagingKeyMetadataOnly"
        Effect    = "Allow"
        Action    = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags"]
        Resource  = local.staging_keys
        Condition = local.staging_key_tags
      },
    ]
  })
}

# Lets the apply role create and change the staging VPC, subnets, routes, security
# groups and endpoints, plus the load balancer and the WAF web ACL. EC2 actions are
# limited to the Region; load balancer and WAF actions are limited to staging resource
# names.
resource "aws_iam_policy" "deploy_network" {
  name        = "${var.project_name}-ci-staging-deploy-network"
  description = "Create and change the staging VPC, load balancer, and WAF"
  tags        = local.ci_tags
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # VPC networking actions are not sensitive storage, KMS, or secrets. Most
        # create actions have no usable resource ARN before the resource exists.
        Sid    = "ManageVpcNetworking"
        Effect = "Allow"
        Action = [
          "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
          "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
          "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
          "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
          "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:CreateRoute", "ec2:ReplaceRoute", "ec2:DeleteRoute",
          "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable", "ec2:ReplaceRouteTableAssociation",
          "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules",
          "ec2:UpdateSecurityGroupRuleDescriptionsIngress", "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
          "ec2:CreateVpcEndpoint", "ec2:ModifyVpcEndpoint", "ec2:DeleteVpcEndpoints",
          "ec2:CreateTags", "ec2:DeleteTags",
          # Interface endpoints with private DNS associate an AWS-managed hosted zone.
          "route53:AssociateVPCWithHostedZone",
        ]
        Resource  = "*"
        Condition = local.in_region
      },
      {
        Sid    = "ManageStagingLoadBalancer"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets", "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:ModifyListener", "elasticloadbalancing:ModifyListenerAttributes",
          "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:SetWebACL",
        ]
        Resource = [local.staging_lb, local.staging_tg, local.staging_lsn]
      },
      {
        Sid    = "ManageStagingWebAcl"
        Effect = "Allow"
        Action = [
          "wafv2:CreateWebACL", "wafv2:UpdateWebACL", "wafv2:DeleteWebACL", "wafv2:GetWebACL",
          "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL",
          "wafv2:ListResourcesForWebACL", "wafv2:TagResource", "wafv2:UntagResource", "wafv2:ListTagsForResource",
        ]
        Resource = [
          local.staging_webacl,
          local.staging_lb,
          # AWS managed rule groups referenced by the web ACL.
          "${local.arn_prefix}:wafv2:${local.region}:*:regional/managedruleset/*/*",
        ]
      },
    ]
  })
}

# Lets the apply role manage the staging ECS cluster and service, task definitions,
# autoscaling, CloudWatch alarms, Redis and SQS queues, and create the service-linked
# roles those services need.
resource "aws_iam_policy" "deploy_workload" {
  name        = "${var.project_name}-ci-staging-deploy-workload"
  description = "Create and change staging ECS, scaling, alarms, Redis, and SQS"
  tags        = local.ci_tags
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageStagingEcs"
        Effect = "Allow"
        Action = [
          "ecs:CreateCluster", "ecs:UpdateCluster", "ecs:DeleteCluster",
          "ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService",
          "ecs:TagResource", "ecs:UntagResource",
        ]
        Resource = local.staging_ecs
      },
      {
        # Task-definition registration has no resource-level permission. PassRole
        # limits which roles a definition can use.
        Sid       = "RegisterTaskDefinitions"
        Effect    = "Allow"
        Action    = ["ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition"]
        Resource  = "*"
        Condition = local.in_region
      },
      {
        # Scalable targets and policies have generated ARNs.
        Sid    = "ManageServiceScaling"
        Effect = "Allow"
        Action = [
          "application-autoscaling:RegisterScalableTarget", "application-autoscaling:DeregisterScalableTarget",
          "application-autoscaling:PutScalingPolicy", "application-autoscaling:DeleteScalingPolicy",
          "application-autoscaling:TagResource", "application-autoscaling:UntagResource",
        ]
        Resource  = "*"
        Condition = local.in_region
      },
      {
        Sid      = "ManageStagingAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
        Resource = local.staging_alarms
      },
      {
        Sid    = "ManageStagingCache"
        Effect = "Allow"
        Action = [
          "elasticache:CreateCacheSubnetGroup", "elasticache:ModifyCacheSubnetGroup", "elasticache:DeleteCacheSubnetGroup",
          "elasticache:CreateCacheCluster", "elasticache:ModifyCacheCluster", "elasticache:DeleteCacheCluster",
          "elasticache:AddTagsToResource", "elasticache:RemoveTagsFromResource", "elasticache:ListTagsForResource",
        ]
        Resource = local.staging_cache
      },
      {
        Sid    = "ManageStagingQueues"
        Effect = "Allow"
        Action = [
          "sqs:CreateQueue", "sqs:DeleteQueue", "sqs:SetQueueAttributes", "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl", "sqs:TagQueue", "sqs:UntagQueue", "sqs:ListQueueTags",
        ]
        Resource = local.staging_queues
      },
      {
        Sid      = "CreateRequiredServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "${local.arn_prefix}:iam::${local.account_id}:role/aws-service-role/*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com",
              "elasticache.amazonaws.com", "ecs.application-autoscaling.amazonaws.com",
            ]
          }
        }
      },
    ]
  })
}

# Lets the apply role manage the four staging workload roles, the rotation Lambda
# functions, secret metadata and the secrets KMS key. It has no permission to read or
# write secret values.
resource "aws_iam_policy" "deploy_identity" {
  name        = "${var.project_name}-ci-staging-deploy-identity"
  description = "Create and change staging workload roles, rotation functions, secret metadata, and the secrets CMK"
  tags        = local.ci_tags
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Only the four workload roles. The CI roles and their policies are excluded.
        Sid    = "ManageStagingWorkloadRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
          "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:ListInstanceProfilesForRole",
        ]
        Resource = concat(local.staging_ecs_roles, local.staging_rotation_roles)
      },
      {
        Sid       = "PassEcsRolesToEcsOnly"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.staging_ecs_roles
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Sid       = "PassRotationRolesToLambdaOnly"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.staging_rotation_roles
        Condition = { StringEquals = { "iam:PassedToService" = "lambda.amazonaws.com" } }
      },
      {
        # InvokeFunction is required to call RotateSecret on these functions.
        Sid    = "ManageStagingRotationFunctions"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
          "lambda:DeleteFunction", "lambda:AddPermission", "lambda:RemovePermission",
          "lambda:TagResource", "lambda:UntagResource", "lambda:InvokeFunction",
        ]
        Resource = local.staging_functions
      },
      {
        # Secret metadata, policies, and rotation only. No GetSecretValue or PutSecretValue.
        Sid    = "ManageStagingSecretMetadata"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret", "secretsmanager:UpdateSecret", "secretsmanager:DeleteSecret",
          "secretsmanager:DescribeSecret", "secretsmanager:TagResource", "secretsmanager:UntagResource",
          "secretsmanager:PutResourcePolicy", "secretsmanager:GetResourcePolicy",
          "secretsmanager:DeleteResourcePolicy", "secretsmanager:RotateSecret", "secretsmanager:CancelRotateSecret",
        ]
        Resource = local.staging_secrets
      },
      {
        # CreateSecret checks key access with a fixed validation context. This
        # context cannot decrypt a stored secret version.
        Sid      = "ValidateSecretKeyAccessOnly"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = local.staging_keys
        Condition = {
          StringEquals = {
            "kms:ViaService"                        = "secretsmanager.${local.region}.amazonaws.com"
            "kms:EncryptionContext:SecretVersionId" = "RequestToValidateKeyAccess"
            "aws:ResourceTag/Project"               = var.project_name
            "aws:ResourceTag/Environment"           = "staging"
          }
        }
      },
      {
        # CreateKey has no key ARN yet; the request must carry the staging tags.
        Sid      = "CreateTaggedStagingKey"
        Effect   = "Allow"
        Action   = ["kms:CreateKey", "kms:TagResource"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion"        = local.region
            "aws:RequestTag/Project"     = var.project_name
            "aws:RequestTag/Environment" = "staging"
          }
        }
      },
      {
        Sid    = "ManageTaggedStagingKey"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:GetKeyRotationStatus",
          "kms:EnableKeyRotation", "kms:ListResourceTags", "kms:TagResource", "kms:UntagResource",
          "kms:UpdateKeyDescription", "kms:ScheduleKeyDeletion", "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias",
        ]
        Resource  = local.staging_keys
        Condition = local.staging_key_tags
      },
      {
        Sid      = "ManageStagingKeyAlias"
        Effect   = "Allow"
        Action   = ["kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"]
        Resource = local.staging_alias
      },
    ]
  })
}

# Which managed policies each CI role receives, flattened into one map so a single
# attachment resource can create them.
locals {
  ci_role_policies = {
    plan  = [aws_iam_policy.state["read_only"].arn, aws_iam_policy.plan_signing["plan"].arn, aws_iam_policy.refresh.arn]
    drift = [aws_iam_policy.state["read_only"].arn, aws_iam_policy.refresh.arn]
    apply = [
      aws_iam_policy.state["read_write"].arn, aws_iam_policy.plan_signing["apply"].arn, aws_iam_policy.refresh.arn,
      aws_iam_policy.deploy_network.arn, aws_iam_policy.deploy_workload.arn, aws_iam_policy.deploy_identity.arn,
    ]
  }
  ci_role_policy_attachments = merge([
    for role, policies in local.ci_role_policies : {
      for index, policy in policies : "${role}-${index}" => { role = role, policy = policy }
    }
  ]...)
}

# Attaches each policy listed for each role in ci_role_policies.
resource "aws_iam_role_policy_attachment" "ci" {
  for_each = local.ci_role_policy_attachments

  role       = aws_iam_role.ci[each.value.role].name
  policy_arn = each.value.policy
}
