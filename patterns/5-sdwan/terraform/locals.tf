# Local Values for SD-WAN Cloud WAN Workshop

# Random PSK generation for VPN if not provided
resource "random_password" "vpn_psk" {
  count   = var.vpn_psk == null ? 1 : 0
  length  = 32
  special = false
}

locals {
  # VPN Pre-Shared Key - use provided value or generated one
  vpn_psk = coalesce(var.vpn_psk, try(random_password.vpn_psk[0].result, null))

  # Common tags applied to all resources
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Frankfurt Region (eu-central-1) VPC CIDR Definitions
  frankfurt = {
    branch1 = {
      vpc_cidr        = "10.10.0.0/20"
      public_subnet   = "10.10.0.0/24"
      public_subnet_2 = "10.10.2.0/24"
      private_subnet  = "10.10.1.0/24"
      az              = "eu-central-1a"
      segment         = "Prod"
    }
    sdwan = {
      vpc_cidr        = "10.200.0.0/16"
      public_subnet   = "10.200.0.0/24"
      public_subnet_2 = "10.200.2.0/24"
      private_subnet  = "10.200.1.0/24"
      az              = "eu-central-1a"
      segment         = "Hybrid"
    }
  }

  # North Virginia Region (us-east-1) VPC CIDR Definitions
  virginia = {
    branch1 = {
      vpc_cidr        = "10.20.0.0/20"
      public_subnet   = "10.20.0.0/24"
      public_subnet_2 = "10.20.2.0/24"
      private_subnet  = "10.20.1.0/24"
      az              = "us-east-1a"
      segment         = "Prod"
    }
    sdwan = {
      vpc_cidr        = "10.201.0.0/16"
      public_subnet   = "10.201.0.0/24"
      public_subnet_2 = "10.201.2.0/24"
      private_subnet  = "10.201.1.0/24"
      az              = "us-east-1a"
      segment         = "Hybrid"
    }
  }

  # ICMP allowed CIDR for cross-VPC connectivity testing
  allowed_icmp_cidr = "10.0.0.0/8"

  # Overlay destination set — CIDRs reached via VyOS internal ENI from each Branch_VPC
  # private route table. Each branch drops the entry equal to its own VPC CIDR.
  overlay_destination_set = [
    "10.10.0.0/20",
    "10.20.0.0/20",
    "10.100.0.0/16",
    "10.50.0.0/16",
  ]
}
