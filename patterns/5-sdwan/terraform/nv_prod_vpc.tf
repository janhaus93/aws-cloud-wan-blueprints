# =============================================================================
# nv-prod-vpc - Directly-Attached Production VPC (us-east-1)
# =============================================================================
#
# New VPC introduced by the architecture-simplification-prod-vpc refactor.
# Attached directly to Cloud WAN in the Prod segment via a native VPC
# attachment — NO VyOS, NO SD-WAN router, NO IPsec, NO BGP session. Traffic
# between this VPC and the branch VPCs traverses Cloud WAN natively and is
# cross-shared with the Hybrid segment via the bidirectional
# `segment-actions` in cloudwan_policy.json (Req 7).
#
# Contents of this file, in order:
#   1. module "nv_prod_vpc"                          — VPC module invocation
#   2. aws_security_group.nv_prod_ec2_sg             — Prod EC2 SG (no 0/0 ingress)
#   3. aws_instance.nv_prod_ec2                      — single t3.micro, SSM-only
#   4. aws_networkmanager_vpc_attachment.nv_prod     — Cloud WAN attachment, tag "Prod"
#   5. aws_route.nv_prod_to_nv_branch1               — overlay route to 10.20.0.0/20
#   6. aws_route.nv_prod_to_fra_branch1              — overlay route to 10.10.0.0/20
#
# Prod EC2 reuses `aws_iam_instance_profile.branch_test_instance_profile`
# declared in branch_test_instances.tf (which attaches only
# AmazonSSMManagedInstanceCore — exactly what Req 9.4 requires).
#
# This VPC is NOT placed in the Hybrid segment (Req 8.8) and is NOT paired
# with any Connect attachment or Connect peer (Req 8.5, 8.7).
# =============================================================================

# =============================================================================
# nv-prod-vpc - VPC Module
# =============================================================================

module "nv_prod_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  providers = { aws = aws.virginia }

  name = "nv-prod-vpc"
  cidr = "10.50.0.0/16"

  azs             = ["us-east-1a"]
  public_subnets  = ["10.50.0.0/24"]
  private_subnets = ["10.50.1.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Region  = "virginia"
    Segment = "Prod"
  }
}

# =============================================================================
# nv-prod-vpc - Prod EC2 Security Group
# =============================================================================
#
# Ingress allows ICMP and TCP/22 from RFC1918 (10.0.0.0/8) for overlay
# reachability probes from branch Test_EC2 instances, and TCP/443 from the
# enclosing VPC CIDR so the SSM Agent can reach SSM endpoints via the NAT
# gateway path. Egress is unrestricted.
#
# Per Req 9.3 / 9.5 / 14.6, NO ingress rule references 0.0.0.0/0 — all
# ingress is scoped to private address space. Egress to 0.0.0.0/0 is
# required by Req 9.5.
# =============================================================================

resource "aws_security_group" "nv_prod_ec2_sg" {
  provider    = aws.virginia
  name        = "nv-prod-ec2-sg"
  description = "Security group for nv-prod-vpc Prod_EC2 - ICMP/TCP22 from RFC1918, TCP443 from VPC for SSM"
  vpc_id      = module.nv_prod_vpc.vpc_id

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
    cidr_blocks = [module.nv_prod_vpc.vpc_cidr_block]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nv-prod-ec2-sg"
  }
}

# =============================================================================
# nv-prod-vpc - Prod EC2 Instance
# =============================================================================
#
# One t3.micro Ubuntu instance inside the nv-prod-vpc private subnet. Access
# is strictly SSM-only: no SSH key pair (key_name is omitted entirely per
# Req 9.3), no public IP (Req 9.3), and the security group above explicitly
# disallows any 0.0.0.0/0 ingress. SSM Agent reaches the SSM endpoints via
# the pre-existing NAT default route on the private route table.
#
# The AMI data source `data.aws_ami.ubuntu_virginia` is already declared in
# instances.tf and is reused here unchanged.
#
# The IAM instance profile `aws_iam_instance_profile.branch_test_instance_profile`
# is reused from branch_test_instances.tf — it attaches only
# AmazonSSMManagedInstanceCore (Req 9.4 — no other managed or inline policy).
# =============================================================================

resource "aws_instance" "nv_prod_ec2" {
  provider                    = aws.virginia
  ami                         = data.aws_ami.ubuntu_virginia.id
  instance_type               = "t3.micro"
  subnet_id                   = module.nv_prod_vpc.private_subnets[0]
  vpc_security_group_ids      = [aws_security_group.nv_prod_ec2_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.branch_test_instance_profile[0].name
  associate_public_ip_address = false

  tags = {
    Name = "nv-prod-ec2"
  }
}

# =============================================================================
# nv-prod-vpc - Cloud WAN VPC Attachment (Prod segment)
# =============================================================================
#
# Native Cloud WAN VPC attachment. The `segment = "Prod"` tag matches
# attachment-policy rule 200 in cloudwan_policy.json, which places this
# attachment in the Prod segment. No Connect attachment and no Connect peer
# are created (Req 8.5, 8.7) — this VPC talks to Cloud WAN natively, not
# through a VyOS overlay.
# =============================================================================

resource "aws_networkmanager_vpc_attachment" "nv_prod" {
  provider = aws.virginia

  core_network_id = aws_networkmanager_core_network.main.id
  vpc_arn         = module.nv_prod_vpc.vpc_arn
  subnet_arns     = [module.nv_prod_vpc.private_subnet_arns[0]]

  tags = {
    Name    = "nv-prod-vpc-attachment"
    segment = "Prod"
  }

  depends_on = [aws_networkmanager_core_network_policy_attachment.main]
}

# =============================================================================
# nv-prod-vpc - Overlay Routes to Branch VPCs via Cloud WAN
# =============================================================================
#
# One explicit route per Branch_VPC CIDR on the nv-prod-vpc private route
# table, targeting the Cloud WAN Core Network ARN (Req 8.6). The pre-existing
# 0.0.0.0/0 → NAT GW default route installed by the VPC module remains
# intact so the Prod_EC2 continues to reach SSM via NAT.
#
# No route is required for the Cloud WAN inside CIDR (10.100.0.0/16) here —
# the Prod_EC2 does not need to reach the Connect Peer addresses directly;
# only the SDWAN hub VPCs do.
# =============================================================================

resource "aws_route" "nv_prod_to_nv_branch1" {
  provider = aws.virginia

  route_table_id         = module.nv_prod_vpc.private_route_table_ids[0]
  destination_cidr_block = "10.20.0.0/20"
  core_network_arn       = aws_networkmanager_core_network.main.arn

  depends_on = [aws_networkmanager_vpc_attachment.nv_prod]
}

resource "aws_route" "nv_prod_to_fra_branch1" {
  provider = aws.virginia

  route_table_id         = module.nv_prod_vpc.private_route_table_ids[0]
  destination_cidr_block = "10.10.0.0/20"
  core_network_arn       = aws_networkmanager_core_network.main.arn

  depends_on = [aws_networkmanager_vpc_attachment.nv_prod]
}
