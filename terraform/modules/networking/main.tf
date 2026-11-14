# name_prefix is used in resource names. az_map gives each sorted AZ a slot (az1 to az3)
# that fixes its subnet CIDRs. common_tags are the standard tags.
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Sorting keeps the same subnet CIDRs if the AZ list is rearranged.
  az_map = {
    for index, az in sort(var.availability_zones) :
    "az${index + 1}" => { index = index, zone = az }
  }
  # These project tags take precedence over matching extra tags.
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })
}

# Endpoint names and ARNs use the provider's region and partition.
data "aws_region" "current" {}

# Partition from the provider, used in the S3 endpoint policy ARN.
data "aws_partition" "current" {}

# The VPC, 10.24.0.0/20 by default. DNS support and hostnames are on, which private
# endpoint DNS needs, and IPv6 is off. A precondition checks that every AZ belongs to
# the provider's Region.
resource "aws_vpc" "this" {
  cidr_block                       = var.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = false
  tags                             = merge(local.common_tags, { Name = "${local.name_prefix}-vpc" })

  lifecycle {
    precondition {
      condition = alltrue([
        for az in var.availability_zones :
        startswith(az, data.aws_region.current.region) &&
        length(az) == length(data.aws_region.current.region) + 1
      ])
      error_message = "All availability zones must belong to the AWS provider's selected Region."
    }
  }
}

# Public uses blocks 0 to 2, app uses 3 to 5, and isolated uses 6 to 8. Blocks 9 to 15 stay reserved.
resource "aws_subnet" "public" {
  for_each = local.az_map

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value.index)
  availability_zone       = each.value.zone
  map_public_ip_on_launch = false
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-${each.key}"
    Tier = "public"
  })
}

# Private application tier: the fourth to sixth /24 blocks (indexes 3 to 5), one per AZ, with no public IP at launch.
resource "aws_subnet" "application" {
  for_each = local.az_map

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value.index + 3)
  availability_zone       = each.value.zone
  map_public_ip_on_launch = false
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-application-${each.key}"
    Tier = "application"
  })
}

# Isolated tier: the seventh to ninth /24 blocks (indexes 6 to 8), one per AZ, with no public IP at launch.
resource "aws_subnet" "database" {
  for_each = local.az_map

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value.index + 6)
  availability_zone       = each.value.zone
  map_public_ip_on_launch = false
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-isolated-${each.key}"
    Tier = "isolated"
  })
}

# The default security group stays empty, with no ingress or egress rules.
resource "aws_default_security_group" "lockdown" {
  vpc_id = aws_vpc.this.id
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-default-sg"
  })
}

# Internet gateway. Only the public route table points to it.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-igw" })
}

# Route table shared by the three public subnets. Its internet route is added by the next resource.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-public-rt" })
}

# Only the public tier has an internet default route.
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# The S3 endpoint adds a route to this table for image-layer downloads.
resource "aws_route_table" "application" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-application-rt" })
}

# Isolated subnets have only the VPC's local route.
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-isolated-rt" })
}

# Each subnet uses its tier's route table.
resource "aws_route_table_association" "public" {
  for_each = local.az_map

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# Ties each application subnet to the application route table.
resource "aws_route_table_association" "application" {
  for_each = local.az_map

  subnet_id      = aws_subnet.application[each.key].id
  route_table_id = aws_route_table.application.id
}

# Ties each isolated subnet to the isolated route table.
resource "aws_route_table_association" "database" {
  for_each = local.az_map

  subnet_id      = aws_subnet.database[each.key].id
  route_table_id = aws_route_table.isolated.id
}

