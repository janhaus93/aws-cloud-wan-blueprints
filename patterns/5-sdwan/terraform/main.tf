# SD-WAN Cloud WAN Workshop
# Terraform Configuration

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

# -----------------------------------------------------------------------------
# AWS Provider Configuration for Multi-Region Deployment
# Frankfurt (eu-central-1) and North Virginia (us-east-1)
# -----------------------------------------------------------------------------

# Default provider
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      auto-delete = "no"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
  alias  = "frankfurt"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      auto-delete = "no"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      auto-delete = "no"
    }
  }
}
