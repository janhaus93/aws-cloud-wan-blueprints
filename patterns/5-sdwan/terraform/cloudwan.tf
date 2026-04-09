# =============================================================================
# Cloud WAN Core Infrastructure
# Global Network, Core Network, Policy, VPC Attachments, Connect Attachments
# =============================================================================

# -----------------------------------------------------------------------------
# Global Network and Core Network
# -----------------------------------------------------------------------------

resource "aws_networkmanager_global_network" "main" {
  provider = aws.virginia

  description = "Global network for SD-WAN Cloud WAN workshop"

  tags = {
    Name = "${var.project_name}-global-network"
  }
}

resource "aws_networkmanager_core_network" "main" {
  provider = aws.virginia

  global_network_id   = aws_networkmanager_global_network.main.id
  create_base_policy  = true
  base_policy_regions = ["us-east-1", "eu-central-1"]

  tags = {
    Name = "${var.project_name}-core-network"
  }
}

# -----------------------------------------------------------------------------
# Core Network Policy
# -----------------------------------------------------------------------------

resource "aws_networkmanager_core_network_policy_attachment" "main" {
  provider = aws.virginia

  core_network_id = aws_networkmanager_core_network.main.id
  policy_document = file("cloudwan_policy.json")
}


# -----------------------------------------------------------------------------
# VPC Attachments
# -----------------------------------------------------------------------------

resource "aws_networkmanager_vpc_attachment" "nv_sdwan" {
  provider = aws.virginia

  core_network_id = aws_networkmanager_core_network.main.id
  vpc_arn         = module.nv_sdwan_vpc.vpc_arn
  subnet_arns     = [module.nv_sdwan_vpc.private_subnet_arns[0]]

  tags = {
    Name    = "nv-sdwan-vpc-attachment"
    segment = var.cloudwan_segment_name
  }

  depends_on = [aws_networkmanager_core_network_policy_attachment.main]
}

resource "aws_networkmanager_vpc_attachment" "fra_sdwan" {
  provider = aws.frankfurt

  core_network_id = aws_networkmanager_core_network.main.id
  vpc_arn         = module.fra_sdwan_vpc.vpc_arn
  subnet_arns     = [module.fra_sdwan_vpc.private_subnet_arns[0]]

  tags = {
    Name    = "fra-sdwan-vpc-attachment"
    segment = var.cloudwan_segment_name
  }

  depends_on = [aws_networkmanager_core_network_policy_attachment.main]
}


# -----------------------------------------------------------------------------
# Connect Attachments (Tunnel-less / NO_ENCAP)
# -----------------------------------------------------------------------------

resource "aws_networkmanager_connect_attachment" "nv_sdwan" {
  provider = aws.virginia

  core_network_id         = aws_networkmanager_core_network.main.id
  transport_attachment_id = aws_networkmanager_vpc_attachment.nv_sdwan.id
  edge_location           = "us-east-1"

  options {
    protocol = "NO_ENCAP"
  }

  tags = {
    Name    = "nv-sdwan-connect-attachment"
    segment = var.cloudwan_segment_name
  }
}

resource "aws_networkmanager_connect_attachment" "fra_sdwan" {
  provider = aws.frankfurt

  core_network_id         = aws_networkmanager_core_network.main.id
  transport_attachment_id = aws_networkmanager_vpc_attachment.fra_sdwan.id
  edge_location           = "eu-central-1"

  options {
    protocol = "NO_ENCAP"
  }

  tags = {
    Name    = "fra-sdwan-connect-attachment"
    segment = var.cloudwan_segment_name
  }
}

# -----------------------------------------------------------------------------
# Connect Peers (BGP peering with VyOS SDWAN routers)
# -----------------------------------------------------------------------------

resource "aws_networkmanager_connect_peer" "nv_sdwan" {
  provider = aws.virginia

  connect_attachment_id = aws_networkmanager_connect_attachment.nv_sdwan.id
  peer_address          = aws_network_interface.nv_sdwan_sdwan_internal.private_ip
  subnet_arn            = module.nv_sdwan_vpc.private_subnet_arns[0]

  bgp_options {
    peer_asn = var.nv_sdwan_bgp_asn
  }

  tags = {
    Name = "nv-sdwan-connect-peer"
  }
}

resource "aws_networkmanager_connect_peer" "fra_sdwan" {
  provider = aws.frankfurt

  connect_attachment_id = aws_networkmanager_connect_attachment.fra_sdwan.id
  peer_address          = aws_network_interface.fra_sdwan_sdwan_internal.private_ip
  subnet_arn            = module.fra_sdwan_vpc.private_subnet_arns[0]

  bgp_options {
    peer_asn = var.fra_sdwan_bgp_asn
  }

  tags = {
    Name = "fra-sdwan-connect-peer"
  }
}


# -----------------------------------------------------------------------------
# VPC Route Table Entries for Cloud WAN Inside CIDRs
# The private subnet route tables need routes to the Cloud WAN inside CIDR
# blocks so that BGP traffic can reach the Connect Peer addresses.
# -----------------------------------------------------------------------------

resource "aws_route" "nv_sdwan_to_cloudwan" {
  provider = aws.virginia

  route_table_id         = module.nv_sdwan_vpc.private_route_table_ids[0]
  destination_cidr_block = var.cloudwan_connect_cidr_nv
  core_network_arn       = aws_networkmanager_core_network.main.arn

  depends_on = [aws_networkmanager_vpc_attachment.nv_sdwan]
}

resource "aws_route" "fra_sdwan_to_cloudwan" {
  provider = aws.frankfurt

  route_table_id         = module.fra_sdwan_vpc.private_route_table_ids[0]
  destination_cidr_block = var.cloudwan_connect_cidr_fra
  core_network_arn       = aws_networkmanager_core_network.main.arn

  depends_on = [aws_networkmanager_vpc_attachment.fra_sdwan]
}
