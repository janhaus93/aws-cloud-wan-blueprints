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

variable "fra_branch1_bgp_asn" {
  description = "BGP ASN for fra-branch1 router (eu-central-1 branch)"
  type        = number
  default     = 64505
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
  default     = "Hybrid"
}

# =============================================================================
# Branch EC2 Test Instances — Feature Gate and Subnet CIDRs
# =============================================================================

variable "enable_test_instances" {
  description = "Enable provisioning of branch test EC2 instances and the nv-prod-vpc test EC2"
  type        = bool
  default     = true
}

variable "nv_branch1_test_subnet_cidr" {
  description = "CIDR for the nv-branch1 test subnet (must be a /28 inside 10.20.0.0/20)"
  type        = string
  default     = "10.20.3.0/28"

  validation {
    condition     = can(cidrnetmask(var.nv_branch1_test_subnet_cidr)) && tonumber(split("/", var.nv_branch1_test_subnet_cidr)[1]) == 28
    error_message = "nv_branch1_test_subnet_cidr must be a valid /28 CIDR block."
  }
}

variable "fra_branch1_test_subnet_cidr" {
  description = "CIDR for the fra-branch1 test subnet (must be a /28 inside 10.10.0.0/20)"
  type        = string
  default     = "10.10.3.0/28"

  validation {
    condition     = can(cidrnetmask(var.fra_branch1_test_subnet_cidr)) && tonumber(split("/", var.fra_branch1_test_subnet_cidr)[1]) == 28
    error_message = "fra_branch1_test_subnet_cidr must be a valid /28 CIDR block."
  }
}
