# =============================================================================
# VPC Definitions - All Regions
# Using terraform-aws-modules/vpc/aws
# =============================================================================

# =============================================================================
# Frankfurt Region (eu-central-1)
# =============================================================================

# -----------------------------------------------------------------------------
# fra-branch1-vpc - Branch Office Frankfurt
# -----------------------------------------------------------------------------

module "fra_branch1_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.frankfurt
  }

  name = "fra-branch1-vpc"
  cidr = local.frankfurt.branch1.vpc_cidr

  azs             = [local.frankfurt.branch1.az]
  public_subnets  = [local.frankfurt.branch1.public_subnet, local.frankfurt.branch1.public_subnet_2]
  private_subnets = [local.frankfurt.branch1.private_subnet]

  public_subnet_names  = ["fra-branch1-vpc-public-1a", "fra-branch1-vpc-public-2-1a"]
  private_subnet_names = ["fra-branch1-vpc-private-1a"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Segment = local.frankfurt.branch1.segment
    Region  = "frankfurt"
  }

  public_subnet_tags = {
    Type = "public"
  }

  private_subnet_tags = {
    Type = "private"
  }
}

# -----------------------------------------------------------------------------
# fra-sdwan-vpc - SD-WAN Appliance Frankfurt
# -----------------------------------------------------------------------------

module "fra_sdwan_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.frankfurt
  }

  name = "fra-sdwan-vpc"
  cidr = local.frankfurt.sdwan.vpc_cidr

  azs             = [local.frankfurt.sdwan.az]
  public_subnets  = [local.frankfurt.sdwan.public_subnet, local.frankfurt.sdwan.public_subnet_2]
  private_subnets = [local.frankfurt.sdwan.private_subnet]

  public_subnet_names  = ["fra-sdwan-vpc-public-1a", "fra-sdwan-vpc-public-2-1a"]
  private_subnet_names = ["fra-sdwan-vpc-private-1a"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Segment = local.frankfurt.sdwan.segment
    Region  = "frankfurt"
  }

  public_subnet_tags = {
    Type = "public"
  }

  private_subnet_tags = {
    Type = "private"
  }
}

# =============================================================================
# North Virginia Region (us-east-1)
# =============================================================================

# -----------------------------------------------------------------------------
# nv-branch1-vpc - Branch Office 1 North Virginia
# -----------------------------------------------------------------------------

module "nv_branch1_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.virginia
  }

  name = "nv-branch1-vpc"
  cidr = local.virginia.branch1.vpc_cidr

  azs             = [local.virginia.branch1.az]
  public_subnets  = [local.virginia.branch1.public_subnet, local.virginia.branch1.public_subnet_2]
  private_subnets = [local.virginia.branch1.private_subnet]

  public_subnet_names  = ["nv-branch1-vpc-public-1a", "nv-branch1-vpc-public-2-1a"]
  private_subnet_names = ["nv-branch1-vpc-private-1a"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Segment = local.virginia.branch1.segment
    Region  = "virginia"
  }

  public_subnet_tags = {
    Type = "public"
  }

  private_subnet_tags = {
    Type = "private"
  }
}

# -----------------------------------------------------------------------------
# nv-sdwan-vpc - SD-WAN Appliance North Virginia
# -----------------------------------------------------------------------------

module "nv_sdwan_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.virginia
  }

  name = "nv-sdwan-vpc"
  cidr = local.virginia.sdwan.vpc_cidr

  azs             = [local.virginia.sdwan.az]
  public_subnets  = [local.virginia.sdwan.public_subnet, local.virginia.sdwan.public_subnet_2]
  private_subnets = [local.virginia.sdwan.private_subnet]

  public_subnet_names  = ["nv-sdwan-vpc-public-1a", "nv-sdwan-vpc-public-2-1a"]
  private_subnet_names = ["nv-sdwan-vpc-private-1a"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Segment = local.virginia.sdwan.segment
    Region  = "virginia"
  }

  public_subnet_tags = {
    Type = "public"
  }

  private_subnet_tags = {
    Type = "private"
  }
}
