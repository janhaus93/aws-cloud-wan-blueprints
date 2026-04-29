# =============================================================================
# Instance ID Outputs (for SSM targeting)
# =============================================================================

output "nv_branch1_instance_id" {
  description = "Virginia Branch1 - EC2 Instance ID"
  value       = aws_instance.nv_branch1_sdwan_instance.id
}

output "nv_sdwan_instance_id" {
  description = "Virginia SD-WAN - EC2 Instance ID"
  value       = aws_instance.nv_sdwan_sdwan_instance.id
}

output "fra_branch1_instance_id" {
  description = "Frankfurt Branch1 - EC2 Instance ID"
  value       = aws_instance.fra_branch1_sdwan_instance.id
}

output "fra_sdwan_instance_id" {
  description = "Frankfurt SD-WAN - EC2 Instance ID"
  value       = aws_instance.fra_sdwan_sdwan_instance.id
}

# =============================================================================
# Elastic IP Outputs - Outside interfaces (for VPN tunnel endpoints)
# =============================================================================

output "nv_branch1_outside_private_ip" {
  description = "Virginia Branch1 - Outside ENI Private IP"
  value       = aws_network_interface.nv_branch1_sdwan_outside.private_ip
}

output "nv_sdwan_outside_private_ip" {
  description = "Virginia SD-WAN - Outside ENI Private IP"
  value       = aws_network_interface.nv_sdwan_sdwan_outside.private_ip
}

output "fra_branch1_outside_private_ip" {
  description = "Frankfurt Branch1 - Outside ENI Private IP"
  value       = aws_network_interface.fra_branch1_sdwan_outside.private_ip
}

output "fra_sdwan_outside_private_ip" {
  description = "Frankfurt SD-WAN - Outside ENI Private IP"
  value       = aws_network_interface.fra_sdwan_sdwan_outside.private_ip
}

output "fra_branch1_outside_eip" {
  description = "Frankfurt Branch1 - Outside EIP (VPN endpoint)"
  value       = aws_eip.fra_branch1_sdwan_outside_eip.public_ip
}

output "fra_sdwan_outside_eip" {
  description = "Frankfurt SD-WAN - Outside EIP (VPN endpoint)"
  value       = aws_eip.fra_sdwan_sdwan_outside_eip.public_ip
}

output "nv_branch1_outside_eip" {
  description = "Virginia Branch1 - Outside EIP (VPN endpoint)"
  value       = aws_eip.nv_branch1_sdwan_outside_eip.public_ip
}

output "nv_sdwan_outside_eip" {
  description = "Virginia SD-WAN - Outside EIP (VPN endpoint)"
  value       = aws_eip.nv_sdwan_sdwan_outside_eip.public_ip
}

# =============================================================================
# Elastic IP Outputs - Management interfaces (for SSH/SSM access)
# =============================================================================

output "fra_branch1_mgmt_eip" {
  description = "Frankfurt Branch1 - Management EIP"
  value       = aws_eip.fra_branch1_sdwan_mgmt_eip.public_ip
}

output "fra_sdwan_mgmt_eip" {
  description = "Frankfurt SD-WAN - Management EIP"
  value       = aws_eip.fra_sdwan_sdwan_mgmt_eip.public_ip
}

output "nv_branch1_mgmt_eip" {
  description = "Virginia Branch1 - Management EIP"
  value       = aws_eip.nv_branch1_sdwan_mgmt_eip.public_ip
}

output "nv_sdwan_mgmt_eip" {
  description = "Virginia SD-WAN - Management EIP"
  value       = aws_eip.nv_sdwan_sdwan_mgmt_eip.public_ip
}

# =============================================================================
# VPN Configuration Reference
# =============================================================================

output "vpn_psk" {
  description = "VPN Pre-Shared Key for all tunnels"
  value       = local.vpn_psk
  sensitive   = true
}

output "vpn_bgp_asns" {
  description = "BGP ASNs for VPN routers (per-router unique ASNs)"
  value = {
    nv_sdwan    = var.nv_sdwan_bgp_asn
    fra_sdwan   = var.fra_sdwan_bgp_asn
    nv_branch1  = var.nv_branch1_bgp_asn
    fra_branch1 = var.fra_branch1_bgp_asn
  }
}

# =============================================================================
# Cloud WAN Outputs
# =============================================================================

output "cloudwan_core_network_id" {
  description = "Cloud WAN Core Network ID"
  value       = aws_networkmanager_core_network.main.id
}

output "cloudwan_core_network_arn" {
  description = "Cloud WAN Core Network ARN"
  value       = aws_networkmanager_core_network.main.arn
}

output "cloudwan_nv_sdwan_vpc_attachment_id" {
  description = "Cloud WAN VPC Attachment ID for nv-sdwan"
  value       = aws_networkmanager_vpc_attachment.nv_sdwan.id
}

output "cloudwan_fra_sdwan_vpc_attachment_id" {
  description = "Cloud WAN VPC Attachment ID for fra-sdwan"
  value       = aws_networkmanager_vpc_attachment.fra_sdwan.id
}

output "cloudwan_nv_sdwan_connect_attachment_id" {
  description = "Cloud WAN Connect Attachment ID for nv-sdwan"
  value       = aws_networkmanager_connect_attachment.nv_sdwan.id
}

output "cloudwan_fra_sdwan_connect_attachment_id" {
  description = "Cloud WAN Connect Attachment ID for fra-sdwan"
  value       = aws_networkmanager_connect_attachment.fra_sdwan.id
}

output "cloudwan_nv_sdwan_connect_peer_config" {
  description = "Connect peer BGP configuration for nv-sdwan"
  value       = aws_networkmanager_connect_peer.nv_sdwan.configuration
}

output "cloudwan_fra_sdwan_connect_peer_config" {
  description = "Connect peer BGP configuration for fra-sdwan"
  value       = aws_networkmanager_connect_peer.fra_sdwan.configuration
}

output "cloudwan_asn" {
  description = "Cloud WAN Core Network BGP ASN"
  value       = var.cloudwan_asn
}

# =============================================================================
# SDWAN Internal ENI Private IP Outputs (for Connect Peer peer_address)
# =============================================================================

output "nv_sdwan_internal_private_ip" {
  description = "Virginia SD-WAN - Internal ENI Private IP (Connect Peer peer_address)"
  value       = aws_network_interface.nv_sdwan_sdwan_internal.private_ip
}

output "fra_sdwan_internal_private_ip" {
  description = "Frankfurt SD-WAN - Internal ENI Private IP (Connect Peer peer_address)"
  value       = aws_network_interface.fra_sdwan_sdwan_internal.private_ip
}


# -----------------------------------------------------------------------------
# Step Functions - Quick Start Command
# -----------------------------------------------------------------------------

output "start_orchestration_command" {
  description = "CLI command to start the SD-WAN orchestration state machine"
  value       = "aws stepfunctions start-execution --state-machine-arn ${aws_sfn_state_machine.sdwan_orchestration.arn} --region us-east-1"
}
