# =============================================================================
# SD-WAN Ubuntu Instances - All Regions
# IAM, AMI, Security Groups, EC2 Instances, ENIs, and EIPs
# =============================================================================

# =============================================================================
# Shared Resources (IAM Role, Instance Profile, AMI Data Sources)
# =============================================================================

resource "aws_iam_role" "sdwan_instance_role" {
  provider = aws.frankfurt
  name     = "sdwan-instance-role"

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
    Name = "sdwan-instance-role"
  }
}

resource "aws_iam_role_policy_attachment" "sdwan_ssm_policy" {
  provider   = aws.frankfurt
  role       = aws_iam_role.sdwan_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "sdwan_s3_policy" {
  provider = aws.frankfurt
  name     = "sdwan-s3-access"
  role     = aws_iam_role.sdwan_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListAllMyBuckets"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.vyos_s3_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${var.vyos_s3_bucket}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "sdwan_instance_profile" {
  provider = aws.frankfurt
  name     = "sdwan-instance-profile"
  role     = aws_iam_role.sdwan_instance_role.name

  tags = {
    Name = "sdwan-instance-profile"
  }
}

# AMI Data Sources - Ubuntu 22.04 LTS

data "aws_ami" "ubuntu_frankfurt" {
  provider    = aws.frankfurt
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "ubuntu_virginia" {
  provider    = aws.virginia
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# Security Groups - Frankfurt (eu-central-1)
# =============================================================================

# -----------------------------------------------------------------------------
# fra-branch1-vpc Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "fra_branch1_public_sg" {
  provider    = aws.frankfurt
  name        = "fra-branch1-vpc-sdwan-public-sg"
  description = "Public security group for SD-WAN instance - IKE, NAT-T, SSM"
  vpc_id      = module.fra_branch1_vpc.vpc_id

  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSM HTTPS"
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
    Name = "fra-branch1-vpc-sdwan-public-sg"
  }
}

resource "aws_security_group" "fra_branch1_private_sg" {
  provider    = aws.frankfurt
  name        = "fra-branch1-vpc-sdwan-private-sg"
  description = "Private security group for SD-WAN instance - internal traffic"
  vpc_id      = module.fra_branch1_vpc.vpc_id

  ingress {
    description = "All from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.fra_branch1_vpc.vpc_cidr_block]
  }

  ingress {
    description = "All from RFC1918"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "fra-branch1-vpc-sdwan-private-sg"
  }
}

# -----------------------------------------------------------------------------
# fra-sdwan-vpc Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "fra_sdwan_public_sg" {
  provider    = aws.frankfurt
  name        = "fra-sdwan-vpc-sdwan-public-sg"
  description = "Public security group for SD-WAN instance - IKE, NAT-T, SSM"
  vpc_id      = module.fra_sdwan_vpc.vpc_id

  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSM HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.fra_sdwan_vpc.vpc_cidr_block]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "fra-sdwan-vpc-sdwan-public-sg"
  }
}

resource "aws_security_group" "fra_sdwan_private_sg" {
  provider    = aws.frankfurt
  name        = "fra-sdwan-vpc-sdwan-private-sg"
  description = "Private security group for SD-WAN instance - internal traffic"
  vpc_id      = module.fra_sdwan_vpc.vpc_id

  ingress {
    description = "All from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.fra_sdwan_vpc.vpc_cidr_block]
  }

  ingress {
    description = "All from RFC1918"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "BGP from Cloud WAN Connect Peer"
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    cidr_blocks = [var.cloudwan_connect_cidr_fra]
  }

  ingress {
    description = "All from Cloud WAN Connect CIDR"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cloudwan_connect_cidr_fra]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "fra-sdwan-vpc-sdwan-private-sg"
  }
}

# =============================================================================
# Security Groups - Virginia (us-east-1)
# =============================================================================

# -----------------------------------------------------------------------------
# nv-branch1-vpc Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "nv_branch1_public_sg" {
  provider    = aws.virginia
  name        = "nv-branch1-vpc-sdwan-public-sg"
  description = "Public security group for SD-WAN instance - IKE, NAT-T, SSM"
  vpc_id      = module.nv_branch1_vpc.vpc_id

  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ESP"
    from_port   = 0
    to_port     = 0
    protocol    = "50"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSM HTTPS"
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
    Name = "nv-branch1-vpc-sdwan-public-sg"
  }
}

resource "aws_security_group" "nv_branch1_private_sg" {
  provider    = aws.virginia
  name        = "nv-branch1-vpc-sdwan-private-sg"
  description = "Private security group for SD-WAN instance - internal traffic"
  vpc_id      = module.nv_branch1_vpc.vpc_id

  ingress {
    description = "All from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.nv_branch1_vpc.vpc_cidr_block]
  }

  ingress {
    description = "All from RFC1918"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nv-branch1-vpc-sdwan-private-sg"
  }
}

# -----------------------------------------------------------------------------
# nv-branch2-vpc Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "nv_branch2_public_sg" {
  provider    = aws.virginia
  name        = "nv-branch2-vpc-sdwan-public-sg"
  description = "Public security group for SD-WAN instance - IKE, NAT-T, SSM"
  vpc_id      = module.nv_branch2_vpc.vpc_id

  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSM HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.nv_branch2_vpc.vpc_cidr_block]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nv-branch2-vpc-sdwan-public-sg"
  }
}

resource "aws_security_group" "nv_branch2_private_sg" {
  provider    = aws.virginia
  name        = "nv-branch2-vpc-sdwan-private-sg"
  description = "Private security group for SD-WAN instance - internal traffic"
  vpc_id      = module.nv_branch2_vpc.vpc_id

  ingress {
    description = "All from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.nv_branch2_vpc.vpc_cidr_block]
  }

  ingress {
    description = "All from RFC1918"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nv-branch2-vpc-sdwan-private-sg"
  }
}

# -----------------------------------------------------------------------------
# nv-sdwan-vpc Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "nv_sdwan_public_sg" {
  provider    = aws.virginia
  name        = "nv-sdwan-vpc-sdwan-public-sg"
  description = "Public security group for SD-WAN instance - IKE, NAT-T, SSM"
  vpc_id      = module.nv_sdwan_vpc.vpc_id

  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ESP"
    from_port   = 0
    to_port     = 0
    protocol    = "50"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSM HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.nv_sdwan_vpc.vpc_cidr_block]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nv-sdwan-vpc-sdwan-public-sg"
  }
}

resource "aws_security_group" "nv_sdwan_private_sg" {
  provider    = aws.virginia
  name        = "nv-sdwan-vpc-sdwan-private-sg"
  description = "Private security group for SD-WAN instance - internal traffic"
  vpc_id      = module.nv_sdwan_vpc.vpc_id

  ingress {
    description = "All from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.nv_sdwan_vpc.vpc_cidr_block]
  }

  ingress {
    description = "All from RFC1918"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "BGP from Cloud WAN Connect Peer"
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    cidr_blocks = [var.cloudwan_connect_cidr_nv]
  }

  ingress {
    description = "All from Cloud WAN Connect CIDR"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cloudwan_connect_cidr_nv]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nv-sdwan-vpc-sdwan-private-sg"
  }
}

# =============================================================================
# EC2 Instances, ENIs, and EIPs - Frankfurt (eu-central-1)
# =============================================================================

# -----------------------------------------------------------------------------
# fra-branch1-vpc
# -----------------------------------------------------------------------------

resource "aws_instance" "fra_branch1_sdwan_instance" {
  provider                    = aws.frankfurt
  ami                         = data.aws_ami.ubuntu_frankfurt.id
  instance_type               = var.sdwan_instance_type
  subnet_id                   = module.fra_branch1_vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.fra_branch1_public_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.sdwan_instance_profile.name
  source_dest_check           = false
  associate_public_ip_address = true

  tags = {
    Name = "fra-branch1-vpc-sdwan-instance"
  }
}

resource "aws_network_interface" "fra_branch1_sdwan_outside" {
  provider          = aws.frankfurt
  subnet_id         = module.fra_branch1_vpc.public_subnets[1]
  security_groups   = [aws_security_group.fra_branch1_public_sg.id]
  source_dest_check = false

  tags = {
    Name = "fra-branch1-vpc-sdwan-outside"
  }
}

resource "aws_network_interface" "fra_branch1_sdwan_internal" {
  provider          = aws.frankfurt
  subnet_id         = module.fra_branch1_vpc.private_subnets[0]
  security_groups   = [aws_security_group.fra_branch1_private_sg.id]
  source_dest_check = false

  tags = {
    Name = "fra-branch1-vpc-sdwan-internal"
  }
}

resource "aws_network_interface_attachment" "fra_branch1_sdwan_outside_attach" {
  provider             = aws.frankfurt
  instance_id          = aws_instance.fra_branch1_sdwan_instance.id
  network_interface_id = aws_network_interface.fra_branch1_sdwan_outside.id
  device_index         = 1
}

resource "aws_network_interface_attachment" "fra_branch1_sdwan_internal_attach" {
  provider             = aws.frankfurt
  instance_id          = aws_instance.fra_branch1_sdwan_instance.id
  network_interface_id = aws_network_interface.fra_branch1_sdwan_internal.id
  device_index         = 2
}

resource "aws_eip" "fra_branch1_sdwan_mgmt_eip" {
  provider          = aws.frankfurt
  network_interface = aws_instance.fra_branch1_sdwan_instance.primary_network_interface_id
  domain            = "vpc"

  tags = {
    Name = "fra-branch1-vpc-sdwan-mgmt-eip"
  }
}

resource "aws_eip" "fra_branch1_sdwan_outside_eip" {
  provider          = aws.frankfurt
  network_interface = aws_network_interface.fra_branch1_sdwan_outside.id
  domain            = "vpc"

  tags = {
    Name = "fra-branch1-vpc-sdwan-outside-eip"
  }
}

# -----------------------------------------------------------------------------
# fra-sdwan-vpc
# -----------------------------------------------------------------------------

resource "aws_instance" "fra_sdwan_sdwan_instance" {
  provider                    = aws.frankfurt
  ami                         = data.aws_ami.ubuntu_frankfurt.id
  instance_type               = var.sdwan_instance_type
  subnet_id                   = module.fra_sdwan_vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.fra_sdwan_public_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.sdwan_instance_profile.name
  source_dest_check           = false
  associate_public_ip_address = true

  tags = {
    Name = "fra-sdwan-vpc-sdwan-instance"
  }
}

resource "aws_network_interface" "fra_sdwan_sdwan_outside" {
  provider          = aws.frankfurt
  subnet_id         = module.fra_sdwan_vpc.public_subnets[1]
  security_groups   = [aws_security_group.fra_sdwan_public_sg.id]
  source_dest_check = false

  tags = {
    Name = "fra-sdwan-vpc-sdwan-outside"
  }
}

resource "aws_network_interface" "fra_sdwan_sdwan_internal" {
  provider          = aws.frankfurt
  subnet_id         = module.fra_sdwan_vpc.private_subnets[0]
  security_groups   = [aws_security_group.fra_sdwan_private_sg.id]
  source_dest_check = false

  tags = {
    Name = "fra-sdwan-vpc-sdwan-internal"
  }
}

resource "aws_network_interface_attachment" "fra_sdwan_sdwan_outside_attach" {
  provider             = aws.frankfurt
  instance_id          = aws_instance.fra_sdwan_sdwan_instance.id
  network_interface_id = aws_network_interface.fra_sdwan_sdwan_outside.id
  device_index         = 1
}

resource "aws_network_interface_attachment" "fra_sdwan_sdwan_internal_attach" {
  provider             = aws.frankfurt
  instance_id          = aws_instance.fra_sdwan_sdwan_instance.id
  network_interface_id = aws_network_interface.fra_sdwan_sdwan_internal.id
  device_index         = 2
}

resource "aws_eip" "fra_sdwan_sdwan_mgmt_eip" {
  provider          = aws.frankfurt
  network_interface = aws_instance.fra_sdwan_sdwan_instance.primary_network_interface_id
  domain            = "vpc"

  tags = {
    Name = "fra-sdwan-vpc-sdwan-mgmt-eip"
  }
}

resource "aws_eip" "fra_sdwan_sdwan_outside_eip" {
  provider          = aws.frankfurt
  network_interface = aws_network_interface.fra_sdwan_sdwan_outside.id
  domain            = "vpc"

  tags = {
    Name = "fra-sdwan-vpc-sdwan-outside-eip"
  }
}

# =============================================================================
# EC2 Instances, ENIs, and EIPs - Virginia (us-east-1)
# =============================================================================

# -----------------------------------------------------------------------------
# nv-branch1-vpc
# -----------------------------------------------------------------------------

resource "aws_instance" "nv_branch1_sdwan_instance" {
  provider                    = aws.virginia
  ami                         = data.aws_ami.ubuntu_virginia.id
  instance_type               = var.sdwan_instance_type
  subnet_id                   = module.nv_branch1_vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.nv_branch1_public_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.sdwan_instance_profile.name
  source_dest_check           = false
  associate_public_ip_address = true

  tags = {
    Name = "nv-branch1-vpc-sdwan-instance"
  }
}

resource "aws_network_interface" "nv_branch1_sdwan_outside" {
  provider          = aws.virginia
  subnet_id         = module.nv_branch1_vpc.public_subnets[1]
  security_groups   = [aws_security_group.nv_branch1_public_sg.id]
  source_dest_check = false

  tags = {
    Name = "nv-branch1-vpc-sdwan-outside"
  }
}

resource "aws_network_interface" "nv_branch1_sdwan_internal" {
  provider          = aws.virginia
  subnet_id         = module.nv_branch1_vpc.private_subnets[0]
  security_groups   = [aws_security_group.nv_branch1_private_sg.id]
  source_dest_check = false

  tags = {
    Name = "nv-branch1-vpc-sdwan-internal"
  }
}

resource "aws_network_interface_attachment" "nv_branch1_sdwan_outside_attach" {
  provider             = aws.virginia
  instance_id          = aws_instance.nv_branch1_sdwan_instance.id
  network_interface_id = aws_network_interface.nv_branch1_sdwan_outside.id
  device_index         = 1
}

resource "aws_network_interface_attachment" "nv_branch1_sdwan_internal_attach" {
  provider             = aws.virginia
  instance_id          = aws_instance.nv_branch1_sdwan_instance.id
  network_interface_id = aws_network_interface.nv_branch1_sdwan_internal.id
  device_index         = 2
}

resource "aws_eip" "nv_branch1_sdwan_mgmt_eip" {
  provider          = aws.virginia
  network_interface = aws_instance.nv_branch1_sdwan_instance.primary_network_interface_id
  domain            = "vpc"

  tags = {
    Name = "nv-branch1-vpc-sdwan-mgmt-eip"
  }
}

resource "aws_eip" "nv_branch1_sdwan_outside_eip" {
  provider          = aws.virginia
  network_interface = aws_network_interface.nv_branch1_sdwan_outside.id
  domain            = "vpc"

  tags = {
    Name = "nv-branch1-vpc-sdwan-outside-eip"
  }
}

# -----------------------------------------------------------------------------
# nv-branch2-vpc
# -----------------------------------------------------------------------------

resource "aws_instance" "nv_branch2_sdwan_instance" {
  provider                    = aws.virginia
  ami                         = data.aws_ami.ubuntu_virginia.id
  instance_type               = var.sdwan_instance_type
  subnet_id                   = module.nv_branch2_vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.nv_branch2_public_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.sdwan_instance_profile.name
  source_dest_check           = false
  associate_public_ip_address = true

  tags = {
    Name = "nv-branch2-vpc-sdwan-instance"
  }
}

resource "aws_network_interface" "nv_branch2_sdwan_outside" {
  provider          = aws.virginia
  subnet_id         = module.nv_branch2_vpc.public_subnets[1]
  security_groups   = [aws_security_group.nv_branch2_public_sg.id]
  source_dest_check = false

  tags = {
    Name = "nv-branch2-vpc-sdwan-outside"
  }
}

resource "aws_network_interface" "nv_branch2_sdwan_internal" {
  provider          = aws.virginia
  subnet_id         = module.nv_branch2_vpc.private_subnets[0]
  security_groups   = [aws_security_group.nv_branch2_private_sg.id]
  source_dest_check = false

  tags = {
    Name = "nv-branch2-vpc-sdwan-internal"
  }
}

resource "aws_network_interface_attachment" "nv_branch2_sdwan_outside_attach" {
  provider             = aws.virginia
  instance_id          = aws_instance.nv_branch2_sdwan_instance.id
  network_interface_id = aws_network_interface.nv_branch2_sdwan_outside.id
  device_index         = 1
}

resource "aws_network_interface_attachment" "nv_branch2_sdwan_internal_attach" {
  provider             = aws.virginia
  instance_id          = aws_instance.nv_branch2_sdwan_instance.id
  network_interface_id = aws_network_interface.nv_branch2_sdwan_internal.id
  device_index         = 2
}

resource "aws_eip" "nv_branch2_sdwan_mgmt_eip" {
  provider          = aws.virginia
  network_interface = aws_instance.nv_branch2_sdwan_instance.primary_network_interface_id
  domain            = "vpc"

  tags = {
    Name = "nv-branch2-vpc-sdwan-mgmt-eip"
  }
}

resource "aws_eip" "nv_branch2_sdwan_outside_eip" {
  provider          = aws.virginia
  network_interface = aws_network_interface.nv_branch2_sdwan_outside.id
  domain            = "vpc"

  tags = {
    Name = "nv-branch2-vpc-sdwan-outside-eip"
  }
}

# -----------------------------------------------------------------------------
# nv-sdwan-vpc
# -----------------------------------------------------------------------------

resource "aws_instance" "nv_sdwan_sdwan_instance" {
  provider                    = aws.virginia
  ami                         = data.aws_ami.ubuntu_virginia.id
  instance_type               = var.sdwan_instance_type
  subnet_id                   = module.nv_sdwan_vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.nv_sdwan_public_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.sdwan_instance_profile.name
  source_dest_check           = false
  associate_public_ip_address = true

  tags = {
    Name = "nv-sdwan-vpc-sdwan-instance"
  }
}

resource "aws_network_interface" "nv_sdwan_sdwan_outside" {
  provider          = aws.virginia
  subnet_id         = module.nv_sdwan_vpc.public_subnets[1]
  security_groups   = [aws_security_group.nv_sdwan_public_sg.id]
  source_dest_check = false

  tags = {
    Name = "nv-sdwan-vpc-sdwan-outside"
  }
}

resource "aws_network_interface" "nv_sdwan_sdwan_internal" {
  provider          = aws.virginia
  subnet_id         = module.nv_sdwan_vpc.private_subnets[0]
  security_groups   = [aws_security_group.nv_sdwan_private_sg.id]
  source_dest_check = false

  tags = {
    Name = "nv-sdwan-vpc-sdwan-internal"
  }
}

resource "aws_network_interface_attachment" "nv_sdwan_sdwan_outside_attach" {
  provider             = aws.virginia
  instance_id          = aws_instance.nv_sdwan_sdwan_instance.id
  network_interface_id = aws_network_interface.nv_sdwan_sdwan_outside.id
  device_index         = 1
}

resource "aws_network_interface_attachment" "nv_sdwan_sdwan_internal_attach" {
  provider             = aws.virginia
  instance_id          = aws_instance.nv_sdwan_sdwan_instance.id
  network_interface_id = aws_network_interface.nv_sdwan_sdwan_internal.id
  device_index         = 2
}

resource "aws_eip" "nv_sdwan_sdwan_mgmt_eip" {
  provider          = aws.virginia
  network_interface = aws_instance.nv_sdwan_sdwan_instance.primary_network_interface_id
  domain            = "vpc"

  tags = {
    Name = "nv-sdwan-vpc-sdwan-mgmt-eip"
  }
}

resource "aws_eip" "nv_sdwan_sdwan_outside_eip" {
  provider          = aws.virginia
  network_interface = aws_network_interface.nv_sdwan_sdwan_outside.id
  domain            = "vpc"

  tags = {
    Name = "nv-sdwan-vpc-sdwan-outside-eip"
  }
}
