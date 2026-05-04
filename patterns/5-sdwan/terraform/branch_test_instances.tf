# =============================================================================
# Branch EC2 Test Instances - IAM Resources
# =============================================================================
#
# This file contains all resources for the branch-ec2-test-instances feature.
# Keeping every new resource in a single file keeps git diffs minimal and makes
# feature removal trivial (flip var.enable_test_instances to false).
#
# This first section defines the IAM role, managed-policy attachment, and
# instance profile used by the four Test_EC2 instances. The role grants ONLY
# AmazonSSMManagedInstanceCore (no S3 access, no inline policy) — least
# privilege per Req 1.8. The existing sdwan-instance-role / sdwan-instance-
# profile in instances.tf are intentionally NOT touched (Req 11.4).
# =============================================================================

resource "aws_iam_role" "branch_test_instance_role" {
  provider = aws.frankfurt
  count    = var.enable_test_instances ? 1 : 0
  name     = "branch-test-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "branch-test-instance-role"
  }
}

resource "aws_iam_role_policy_attachment" "branch_test_ssm" {
  provider   = aws.frankfurt
  count      = var.enable_test_instances ? 1 : 0
  role       = aws_iam_role.branch_test_instance_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "branch_test_instance_profile" {
  provider = aws.frankfurt
  count    = var.enable_test_instances ? 1 : 0
  name     = "branch-test-instance-profile"
  role     = aws_iam_role.branch_test_instance_role[0].name

  tags = {
    Name = "branch-test-instance-profile"
  }
}
# =============================================================================
# Branch EC2 Test Instances - Security Groups
# =============================================================================
#
# One security group per participating Branch_VPC, attached to the Test_EC2
# instances created later in this file. Ingress allows ICMP (all types/codes)
# and TCP/22 from RFC1918 (10.0.0.0/8) for overlay reachability probes, and
# TCP/443 from the enclosing VPC CIDR so the SSM Agent can reach SSM endpoints
# via the NAT gateway path. Egress is unrestricted.
#
# Per Req 4.4, NO ingress rule references 0.0.0.0/0 — all ingress is scoped
# to private address space. Egress to 0.0.0.0/0 is required by Req 4.5.
# =============================================================================

resource "aws_security_group" "nv_branch1_test_ec2_sg" {
  provider    = aws.virginia
  count       = var.enable_test_instances ? 1 : 0
  name        = "nv-branch1-test-ec2-sg"
  description = "Security group for nv-branch1 Test_EC2 instances - ICMP/TCP22 from RFC1918, TCP443 from VPC for SSM"
  vpc_id      = module.nv_branch1_vpc.vpc_id

  ingress {
    description = "ICMP from RFC1918 for overlay reachability probes"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "SSH from RFC1918 for overlay reachability probes"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "HTTPS from VPC for SSM Agent"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.nv_branch1_vpc.vpc_cidr_block]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nv-branch1-test-ec2-sg"
  }
}

resource "aws_security_group" "fra_branch1_test_ec2_sg" {
  provider    = aws.frankfurt
  count       = var.enable_test_instances ? 1 : 0
  name        = "fra-branch1-test-ec2-sg"
  description = "Security group for fra-branch1 Test_EC2 instances - ICMP/TCP22 from RFC1918, TCP443 from VPC for SSM"
  vpc_id      = module.fra_branch1_vpc.vpc_id

  ingress {
    description = "ICMP from RFC1918 for overlay reachability probes"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "SSH from RFC1918 for overlay reachability probes"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "HTTPS from VPC for SSM Agent"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.fra_branch1_vpc.vpc_cidr_block]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "fra-branch1-test-ec2-sg"
  }
}

# =============================================================================
# Branch EC2 Test Instances - Per-Branch Test Subnets
# =============================================================================
#
# One /28 subnet per surviving Branch_VPC (nv-branch1, fra-branch1). CIDRs
# come from var.<branch>_test_subnet_cidr so operators can override them
# without editing resource blocks. Each subnet lands in the same AZ as the
# existing private subnet of its parent VPC (Req 2.8) and disables public-IP
# auto-assignment (Test_EC2 instances must remain private).
#
# Segment identity has been removed from this layer — after the architecture
# simplification refactor, segment identity is carried only by Cloud WAN
# attachment tag, not by branch-side subnet/instance tags (Req 2.6).
# =============================================================================

resource "aws_subnet" "nv_branch1_test_subnet" {
  provider                = aws.virginia
  count                   = var.enable_test_instances ? 1 : 0
  vpc_id                  = module.nv_branch1_vpc.vpc_id
  cidr_block              = var.nv_branch1_test_subnet_cidr
  availability_zone       = local.virginia.branch1.az
  map_public_ip_on_launch = false

  tags = {
    Name = "nv-branch1-test-subnet"
  }
}

resource "aws_subnet" "fra_branch1_test_subnet" {
  provider                = aws.frankfurt
  count                   = var.enable_test_instances ? 1 : 0
  vpc_id                  = module.fra_branch1_vpc.vpc_id
  cidr_block              = var.fra_branch1_test_subnet_cidr
  availability_zone       = local.frankfurt.branch1.az
  map_public_ip_on_launch = false

  tags = {
    Name = "fra-branch1-test-subnet"
  }
}

# =============================================================================
# Branch EC2 Test Instances - Route Table Associations
# =============================================================================
#
# Associate each test subnet with the existing private route table of its
# parent VPC (Option A route table sharing — see design "Key Design Decisions").
# This ensures the pre-existing 0.0.0.0/0 → NAT GW default route (created by
# the upstream VPC module) automatically applies to Test_EC2 traffic, keeping
# SSM reachability working (Req 3.1). Overlay-destination static routes will
# be added onto the same private route table in task 7.
# =============================================================================

resource "aws_route_table_association" "nv_branch1_test_subnet" {
  provider       = aws.virginia
  count          = var.enable_test_instances ? 1 : 0
  subnet_id      = aws_subnet.nv_branch1_test_subnet[0].id
  route_table_id = module.nv_branch1_vpc.private_route_table_ids[0]
}

resource "aws_route_table_association" "fra_branch1_test_subnet" {
  provider       = aws.frankfurt
  count          = var.enable_test_instances ? 1 : 0
  subnet_id      = aws_subnet.fra_branch1_test_subnet[0].id
  route_table_id = module.fra_branch1_vpc.private_route_table_ids[0]
}

# =============================================================================
# Branch EC2 Test Instances - Test_EC2 Instances
# =============================================================================
#
# Two t3.micro Test_EC2 instances — one in nv-branch1 and one in fra-branch1.
# Each lands in its Branch_VPC test subnet created above and is attached to
# the per-VPC test security group. Access is strictly SSM-only: no SSH key
# pair (key_name is omitted entirely per Req 1.9), no public IP (Req 1.10),
# and the security group explicitly disallows any 0.0.0.0/0 ingress
# (Req 4.4). SSM Agent reaches the SSM endpoints via the pre-existing NAT
# default route on the shared private route table.
#
# The AMI data sources `data.aws_ami.ubuntu_virginia` and
# `data.aws_ami.ubuntu_frankfurt` are already declared in instances.tf and are
# reused here unchanged (Req 11.3 — read-only reference).
#
# Segment identity is no longer carried on these instances — segment identity
# lives purely on Cloud WAN attachment tags after the architecture
# simplification refactor (Req 2.6).
#
# Intentionally NOT set on these instances:
#   - source_dest_check (Req 1.12 — Test_EC2s are endpoints, not forwarders;
#     the attribute is left at its AWS default of true)
#   - key_name (Req 1.9 — SSM-only access)
#   - associate_public_ip_address is explicitly false (Req 1.10)
#
# The existing VyOS internal ENIs (aws_network_interface.*_sdwan_internal)
# already have source_dest_check = false and this feature does NOT touch them
# (Req 3.5).
# =============================================================================

resource "aws_instance" "nv_branch1_test_ec2" {
  provider                    = aws.virginia
  count                       = var.enable_test_instances ? 1 : 0
  ami                         = data.aws_ami.ubuntu_virginia.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.nv_branch1_test_subnet[0].id
  vpc_security_group_ids      = [aws_security_group.nv_branch1_test_ec2_sg[0].id]
  iam_instance_profile        = aws_iam_instance_profile.branch_test_instance_profile[0].name
  associate_public_ip_address = false

  tags = {
    Name = "nv-branch1-test-ec2"
  }
}

resource "aws_instance" "fra_branch1_test_ec2" {
  provider                    = aws.frankfurt
  count                       = var.enable_test_instances ? 1 : 0
  ami                         = data.aws_ami.ubuntu_frankfurt.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.fra_branch1_test_subnet[0].id
  vpc_security_group_ids      = [aws_security_group.fra_branch1_test_ec2_sg[0].id]
  iam_instance_profile        = aws_iam_instance_profile.branch_test_instance_profile[0].name
  associate_public_ip_address = false

  tags = {
    Name = "fra-branch1-test-ec2"
  }
}

# =============================================================================
# Branch EC2 Test Instances - Overlay Route Entries
# =============================================================================
#
# Steer traffic from the Test_EC2 subnets (and, transitively, the existing
# private subnet that shares this route table — see "Option A route table
# sharing" in the design) toward the local VyOS internal ENI for every CIDR
# in local.overlay_destination_set EXCEPT the branch's own VPC CIDR. AWS VPC
# route tables always contain an implicit, unremovable `local` route for the
# VPC CIDR; creating an aws_route for the same destination fails at apply
# time. The `if cidr != <own_vpc_cidr>` filter drops that single collision per
# branch, yielding 3 overlay routes per branch (6 total) after the
# architecture simplification refactor.
#
# Terraform does NOT support dynamic provider assignment per for_each
# iteration — the `provider` meta-argument must be a static reference — so
# the flattened (branch, cidr) space is split into two sibling resources,
# one per regional provider. Each for_each key is simply the destination CIDR
# (unique within the scope of a single branch's route table) so the resulting
# addresses are stable and readable, e.g.
#   aws_route.nv_branch1_test_overlay["10.10.0.0/20"]
#
# The explicit depends_on satisfies Req 3.6: Terraform must order the ENI
# attachment's completion before attempting aws_route creation, otherwise the
# ENI is not yet in a routable state when AWS validates the route target.
# =============================================================================

resource "aws_route" "nv_branch1_test_overlay" {
  provider = aws.virginia
  for_each = var.enable_test_instances ? toset([
    for cidr in local.overlay_destination_set : cidr
    if cidr != local.virginia.branch1.vpc_cidr
  ]) : toset([])

  route_table_id         = module.nv_branch1_vpc.private_route_table_ids[0]
  destination_cidr_block = each.value
  network_interface_id   = aws_network_interface.nv_branch1_sdwan_internal.id

  depends_on = [
    aws_network_interface_attachment.nv_branch1_sdwan_internal_attach,
  ]
}

resource "aws_route" "fra_branch1_test_overlay" {
  provider = aws.frankfurt
  for_each = var.enable_test_instances ? toset([
    for cidr in local.overlay_destination_set : cidr
    if cidr != local.frankfurt.branch1.vpc_cidr
  ]) : toset([])

  route_table_id         = module.fra_branch1_vpc.private_route_table_ids[0]
  destination_cidr_block = each.value
  network_interface_id   = aws_network_interface.fra_branch1_sdwan_internal.id

  depends_on = [
    aws_network_interface_attachment.fra_branch1_sdwan_internal_attach,
  ]
}

# =============================================================================
# Branch EC2 Test Instances - SSM Parameters for Test Subnet CIDRs
# =============================================================================
#
# Publish each Test Subnet CIDR under /sdwan/<branch>/test-subnet so the
# Phase 2 Lambda handler can discover it via the existing
# ssm_utils.get_instance_configs path (see design "Components and Interfaces →
# lambda/ssm_utils.py"). The `/sdwan/` prefix matches the IAM policy already
# granted to the Lambdas (ssm:GetParametersByPath on /sdwan/*), so no IAM
# change is required (Req 11.5).
#
# After the architecture simplification refactor, the old per-segment SSM
# parameter paths are gone. Each branch publishes exactly one test-subnet
# CIDR under the segment-neutral path `/sdwan/<branch>/test-subnet`
# (Req 2.7).
#
# These resources intentionally live in branch_test_instances.tf — NOT in
# ssm-parameters.tf — so that toggling var.enable_test_instances cleanly
# adds/removes the entire feature from one file.
# =============================================================================

resource "aws_ssm_parameter" "nv_branch1_test_subnet" {
  provider = aws.virginia
  count    = var.enable_test_instances ? 1 : 0
  name     = "/sdwan/nv-branch1/test-subnet"
  type     = "String"
  value    = aws_subnet.nv_branch1_test_subnet[0].cidr_block

  tags = {
    Name = "sdwan-nv-branch1-test-subnet"
  }
}

resource "aws_ssm_parameter" "fra_branch1_test_subnet" {
  provider = aws.frankfurt
  count    = var.enable_test_instances ? 1 : 0
  name     = "/sdwan/fra-branch1/test-subnet"
  type     = "String"
  value    = aws_subnet.fra_branch1_test_subnet[0].cidr_block

  tags = {
    Name = "sdwan-fra-branch1-test-subnet"
  }
}

# =============================================================================
# Branch EC2 Test Instances - SSM Parameters for Inside-Subnet Gateway IP
# =============================================================================
#
# Publish the VPC-assigned gateway address (first usable host) of each branch
# VyOS router's internal subnet. The Phase 2 Lambda handler needs this value
# to install a VyOS static route for the test subnet (which sits on a
# different subnet from the VyOS internal ENI) so that the BGP `network
# <test-subnet>` statement has a matching RIB entry and actually advertises.
#
# AWS reserves `.1` of every VPC subnet as the implicit router; cidrhost(..,1)
# returns the gateway address without hard-coding it. These parameters land
# under the same `/sdwan/` prefix the Lambdas already have IAM access to.
# =============================================================================

resource "aws_ssm_parameter" "nv_branch1_inside_gateway_ip" {
  provider = aws.virginia
  count    = var.enable_test_instances ? 1 : 0
  name     = "/sdwan/nv-branch1/inside-gateway-ip"
  type     = "String"
  value    = cidrhost(module.nv_branch1_vpc.private_subnets_cidr_blocks[0], 1)

  tags = {
    Name = "sdwan-nv-branch1-inside-gateway-ip"
  }
}

resource "aws_ssm_parameter" "fra_branch1_inside_gateway_ip" {
  provider = aws.frankfurt
  count    = var.enable_test_instances ? 1 : 0
  name     = "/sdwan/fra-branch1/inside-gateway-ip"
  type     = "String"
  value    = cidrhost(module.fra_branch1_vpc.private_subnets_cidr_blocks[0], 1)

  tags = {
    Name = "sdwan-fra-branch1-inside-gateway-ip"
  }
}
