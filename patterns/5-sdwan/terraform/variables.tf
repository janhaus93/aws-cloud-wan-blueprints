# Input Variables for SD-WAN Cloud WAN Workshop

variable "instance_type" {
  description = "EC2 instance type for test instances"
  type        = string
  default     = "t3.micro"
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
  default     = "sdwan-cloudwan-workshop"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "workshop"
}

variable "sdwan_instance_type" {
  description = "EC2 instance type for SD-WAN Ubuntu instances"
  type        = string
  default     = "c5.large"
}

variable "vyos_s3_bucket" {
  description = "S3 bucket name containing the VyOS LXD image"
  type        = string
  default     = "fra-vyos-bucket"
}

variable "vyos_s3_region" {
  description = "AWS region of the VyOS S3 bucket"
  type        = string
  default     = "us-east-1"
}

variable "vyos_s3_key" {
  description = "S3 object key (filename) for the VyOS LXD image"
  type        = string
  default     = "vyos_dxgl-1.3.3-bc64a3a-5_lxd_amd64.tar.gz"
}

# VPN and BGP Configuration Variables

variable "vpn_psk" {
  description = "Pre-shared key for IPsec VPN authentication. If not provided, a random 32-character PSK will be generated."
  type        = string
  sensitive   = true
  default     = null
}

# Per-router BGP ASN variables (unique ASNs outside Cloud WAN range 64520-65525)

variable "nv_sdwan_bgp_asn" {
  description = "BGP ASN for nv-sdwan router (us-east-1 SDWAN hub)"
  type        = number
  default     = 64501
}

variable "fra_sdwan_bgp_asn" {
  description = "BGP ASN for fra-sdwan router (eu-central-1 SDWAN hub)"
  type        = number
  default     = 64502
}

variable "nv_branch1_bgp_asn" {
  description = "BGP ASN for nv-branch1 router (us-east-1 branch)"
  type        = number
  default     = 64503
}

variable "nv_branch2_bgp_asn" {
  description = "BGP ASN for nv-branch2 router (us-east-1 branch)"
  type        = number
  default     = 64504
}

variable "fra_branch1_bgp_asn" {
  description = "BGP ASN for fra-branch1 router (eu-central-1 branch)"
  type        = number
  default     = 64505
}

# Dummy interface address variables for branch routers (segment-specific prefixes)

variable "nv_branch1_prod_dummy" {
  description = "nv-branch1 dum0 (Prod) address"
  type        = string
  default     = "10.250.1.1/32"
}

variable "nv_branch1_dev_dummy" {
  description = "nv-branch1 dum1 (Dev) address"
  type        = string
  default     = "10.250.1.2/32"
}

variable "fra_branch1_prod_dummy" {
  description = "fra-branch1 dum0 (Prod) address"
  type        = string
  default     = "10.250.2.1/32"
}

variable "fra_branch1_dev_dummy" {
  description = "fra-branch1 dum1 (Dev) address"
  type        = string
  default     = "10.250.2.2/32"
}

# BGP community value variables for segment tagging

variable "bgp_community_prod" {
  description = "Community value suffix for Prod routes (used as ASN:value)"
  type        = string
  default     = "100"
}

variable "bgp_community_dev" {
  description = "Community value suffix for Dev routes (used as ASN:value)"
  type        = string
  default     = "200"
}

variable "vpn_tunnel_cidr" {
  description = "CIDR for VPN tunnel interfaces (/30 subnet)"
  type        = string
  default     = "169.254.100.0/30"
}

# Lambda and Step Functions Variables

variable "lambda_source_dir" {
  description = "Path to Lambda function source code directory"
  type        = string
  default     = "lambda"
}

variable "phase1_wait_seconds" {
  description = "Wait time after Phase1 before starting Phase2 (seconds)"
  type        = number
  default     = 60
}

variable "phase2_wait_seconds" {
  description = "Wait time after Phase2 before starting Phase3 (seconds)"
  type        = number
  default     = 90
}

# Cloud WAN Variables

variable "cloudwan_asn" {
  description = "BGP ASN for Cloud WAN Core Network"
  type        = number
  default     = 64512
}

variable "cloudwan_connect_cidr_nv" {
  description = "Inside CIDR for nv-sdwan Cloud WAN edge (/24 allocated to us-east-1)"
  type        = string
  default     = "10.100.0.0/24"
}

variable "cloudwan_connect_cidr_fra" {
  description = "Inside CIDR for fra-sdwan Cloud WAN edge (/24 allocated to eu-central-1)"
  type        = string
  default     = "10.100.1.0/24"
}

variable "cloudwan_segment_name" {
  description = "Cloud WAN segment name for SDWAN attachments"
  type        = string
  default     = "sdwan"
}
