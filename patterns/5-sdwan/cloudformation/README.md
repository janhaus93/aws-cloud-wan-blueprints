# SD-WAN Cloud WAN Workshop — CloudFormation

Deploy a multi-region SD-WAN overlay network on AWS with Cloud WAN backbone using CloudFormation. This project provisions Ubuntu EC2 instances running VyOS routers inside LXD containers, establishes IPsec VPN tunnels with BGP peering, integrates AWS Cloud WAN with tunnel-less Connect attachments for cross-region route propagation, enforces multi-segment traffic isolation via BGP community tagging, and orchestrates the entire configuration lifecycle through AWS Step Functions.

## Architecture

```
┌──────────────────────── us-east-1 ────────────────────────┐   ┌───────────────────── eu-central-1 ─────────────────────┐
│                                                            │   │                                                        │
│  ┌─────────────┐    IPsec/BGP    ┌─────────────┐          │   │  ┌─────────────┐    IPsec/BGP    ┌───────────┐         │
│  │  nv-sdwan   │◄──────────────►│ nv-branch1  │          │   │  │  fra-sdwan  │◄──────────────►│fra-branch1│         │
│  │  ASN 64501  │  VTI 100.1/2   │  ASN 64503  │          │   │  │  ASN 64502  │  VTI 100.13/14 │ ASN 64505 │         │
│  │  VPC 10.201 │                 │  VPC 10.20  │          │   │  │  VPC 10.200 │                │ VPC 10.10 │         │
│  │  route-map  │                 │dum0 Prod    │          │   │  │  route-map  │                │dum0 Prod  │         │
│  │  CLOUDWAN-  │                 │dum1 Dev     │          │   │  │  CLOUDWAN-  │                │dum1 Dev   │         │
│  │  OUT        │                 │             │          │   │  │  OUT        │                │           │         │
│  └──────┬──────┘                 └─────────────┘          │   │  └──────┬──────┘                └───────────┘         │
│         │ BGP (tunnel-less, NO_ENCAP)                      │   │         │ BGP (tunnel-less, NO_ENCAP)                  │
│         │ community tagging: *:100 Prod, *:200 Dev         │   │         │ community tagging: *:100 Prod, *:200 Dev     │
│  ┌──────┴──────────────────────────────────────────────────┴───┴─────────┴──────┐                                       │
│  │                         AWS Cloud WAN Core Network                           │                                       │
│  │         Segments: sdwan | Prod | Dev    Inside CIDR: 10.100.0.0/16           │                                       │
│  │         Routing policies: community-based filtering per segment               │                                       │
│  └──────────────────────────────────────────────────────────────────────────────┘                                       │
│                                                            │   │                                                        │
│  ┌─────────────┐                                           │   └────────────────────────────────────────────────────────┘
│  │ nv-branch2  │                                           │
│  │  VPC 10.30  │                                           │
│  └─────────────┘                                           │
└────────────────────────────────────────────────────────────┘

Each instance: Ubuntu 22.04 (c5.large) → LXD → VyOS container
3 ENIs per instance: Management | Outside (WAN) | Inside (LAN)
```

## What It Does

1. **Provisions VPC infrastructure** across 2 AWS regions (5 VPCs, each with public/private subnets, NAT gateways, and internet gateways)
2. **Deploys Ubuntu EC2 instances** with 3 network interfaces each, Elastic IPs, and security groups for VPN traffic
3. **Creates AWS Cloud WAN** global network, core network with inline policy (3 segments, routing policies), VPC attachments, tunnel-less Connect attachments, and Connect peers
4. **Stores runtime config in SSM Parameter Store** — instance IDs, EIPs, private IPs, and Cloud WAN peer addresses under `/sdwan/` for Lambda consumption
5. **Bootstraps VyOS routers** inside LXD containers with correct file permissions for the vyos user
6. **Configures IPsec VPN tunnels** (IKEv2, AES-256, SHA-256) and **eBGP peering** between SD-WAN and branch routers, with dummy interfaces on branches for Prod/Dev segment traffic
7. **Configures Cloud WAN BGP** — tunnel-less eBGP sessions between SDWAN routers and Cloud WAN Connect peers, with route-maps (`CLOUDWAN-OUT`) for BGP community tagging (Prod=`*:100`, Dev=`*:200`)
8. **Enforces segment isolation** — Cloud WAN routing policies match BGP communities and filter routes into Prod and Dev segments via `segment-actions` share rules
9. **Verifies connectivity** — IPsec SA status, BGP sessions (VPN and Cloud WAN), interface state, VTI ping tests, and persists results to SSM Parameter Store at `/sdwan/verification-results`
10. **Orchestrates everything** via AWS Step Functions + Lambda — no local scripts needed after stack deployment

## Prerequisites

- AWS CLI configured with credentials for 2 regions (`us-east-1` and `eu-central-1`)
- An S3 bucket containing:
  - The VyOS LXD image (default: `fra-vyos-bucket` in `us-east-1`)
  - The `lambda.zip` deployment package (upload from this repo)
  - All CloudFormation templates from the `templates/` directory

## Quick Start

```bash
# 1. Upload templates and Lambda zip to your S3 bucket
BUCKET=your-deployment-bucket
aws s3 cp templates/ s3://$BUCKET/templates/ --recursive
aws s3 cp lambda.zip s3://$BUCKET/lambda.zip

# 2. Deploy the parent stack
aws cloudformation create-stack \
  --stack-name sdwan-cloudwan-workshop \
  --template-url https://$BUCKET.s3.amazonaws.com/templates/parent-stack.yaml \
  --parameters \
    ParameterKey=LambdaS3Bucket,ParameterValue=$BUCKET \
    ParameterKey=LambdaS3Key,ParameterValue=lambda.zip \
    ParameterKey=TemplateBaseUrl,ParameterValue=https://$BUCKET.s3.amazonaws.com/templates \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# 3. Wait for stack creation (Cloud WAN resources can take 15-20 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name sdwan-cloudwan-workshop \
  --region us-east-1

# 4. Start the SD-WAN configuration orchestration
aws cloudformation describe-stacks \
  --stack-name sdwan-cloudwan-workshop \
  --query 'Stacks[0].Outputs[?OutputKey==`StartExecutionCommand`].OutputValue' \
  --output text \
  --region us-east-1 | bash
```

The state machine runs 4 phases automatically:

| Phase | Lambda | What It Does | Wait After |
|-------|--------|-------------|------------|
| Phase 1 | `sdwan-phase1` | Installs packages, initializes LXD, deploys VyOS container, applies DHCP config, fixes VyOS config file permissions (`chown vyos:vyattacfg`) | 60s |
| Phase 2 | `sdwan-phase2` | Pushes IPsec tunnel and BGP peering config; creates dummy interfaces (dum0/dum1) on branch routers for Prod/Dev segment prefixes | 90s |
| Phase 3 | `sdwan-phase3` | Cloud WAN BGP config — tunnel-less BGP neighbors on SDWAN routers, prefix-lists, route-map `CLOUDWAN-OUT` with community tagging | 30s |
| Phase 4 | `sdwan-phase4` | Verification: IPsec, BGP, Cloud WAN BGP, connectivity — checks all sessions and persists results to SSM | — |

## Stack Architecture

The deployment uses a parent stack that orchestrates 4 nested/custom-resource stacks:

```
parent-stack.yaml
├── virginia-stack.yaml          (nested, us-east-1)
│   └── 3 VPCs, SGs, EC2, ENIs, EIPs, IAM role/profile
├── Custom::CrossRegionStack     (Lambda-backed, eu-central-1)
│   └── frankfurt-stack.yaml
│       └── 2 VPCs, SGs, EC2, ENIs, EIPs
├── cloudwan-stack.yaml          (nested, us-east-1)
│   └── Global Network, Core Network + policy, VPC attachments,
│       Connect attachments, Connect peers, BGP lookup custom resources
└── orchestration-stack.yaml     (nested, us-east-1)
    └── Lambda IAM, Phase 1-4 Lambdas, SSM params (us-east-1 + eu-central-1),
        Step Functions state machine, CloudWatch log group
```

## Project Structure

```
.
├── README.md                      # This file
├── lambda.zip                     # Pre-built Lambda deployment package
│
├── lambda/                        # Lambda function source code (Python 3.12)
│   ├── ssm_utils.py               # Shared SSM utilities (parameter reads, command execution)
│   ├── phase1_handler.py          # Phase 1: base setup (packages, LXD, VyOS, permissions fix)
│   ├── phase2_handler.py          # Phase 2: VPN/BGP config + dummy interfaces on branches
│   ├── phase3_handler.py          # Phase 3: Cloud WAN BGP config + route-maps + community tagging
│   ├── phase4_handler.py          # Phase 4: verification (IPsec, BGP, Cloud WAN BGP, ping)
│   └── cross_region_stack.py      # Custom resource handler for cross-region stack deployment
│
└── templates/                     # CloudFormation templates
    ├── parent-stack.yaml          # Top-level stack — orchestrates all nested stacks
    ├── virginia-stack.yaml        # us-east-1: 3 VPCs, SGs, EC2 instances, IAM
    ├── frankfurt-stack.yaml       # eu-central-1: 2 VPCs, SGs, EC2 instances
    ├── frankfurt-ssm-stack.yaml   # eu-central-1: SSM parameters (if used standalone)
    ├── cloudwan-stack.yaml        # Cloud WAN: global network, core network, policy,
    │                              #   attachments, connect peers, BGP lookup
    └── orchestration-stack.yaml   # Step Functions, Lambda functions, SSM parameters,
                                   #   IAM roles, CloudWatch log group
```

## Configuration

### Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SdwanInstanceType` | `c5.large` | EC2 instance type for SD-WAN hosts |
| `VyosS3Bucket` | `fra-vyos-bucket` | S3 bucket with VyOS LXD image |
| `VyosS3Key` | `vyos_dxgl-1.3.3-...tar.gz` | VyOS image filename in S3 |
| `SdwanBgpAsn` | `65001` | BGP ASN for Cloud WAN Connect Peer BgpOptions |
| `CloudWanConnectCidrNv` | `10.100.0.0/24` | Cloud WAN inside CIDR for us-east-1 |
| `CloudWanConnectCidrFra` | `10.100.1.0/24` | Cloud WAN inside CIDR for eu-central-1 |
| `CloudWanSegmentName` | `sdwan` | Cloud WAN segment name for SDWAN attachments |
| `LambdaS3Bucket` | *(required)* | S3 bucket containing `lambda.zip` |
| `LambdaS3Key` | *(required)* | S3 key for the Lambda deployment zip |
| `TemplateBaseUrl` | *(required)* | S3 URL prefix where nested stack templates are stored |
| `Phase1WaitSeconds` | `60` | Wait time after Phase 1 before Phase 2 |
| `Phase2WaitSeconds` | `90` | Wait time after Phase 2 before Phase 3 |
| `Phase3WaitSeconds` | `30` | Wait time after Phase 3 before Phase 4 |

### BGP ASN Assignment

Each router has a unique ASN in the 64501–64505 range, configured in the Lambda handlers:

| Router | ASN | Role |
|--------|-----|------|
| nv-sdwan | 64501 | SDWAN hub (us-east-1) |
| fra-sdwan | 64502 | SDWAN hub (eu-central-1) |
| nv-branch1 | 64503 | Branch (us-east-1) |
| fra-branch1 | 64505 | Branch (eu-central-1) |

### VPN Topology (Intra-Region)

| Tunnel | VTI A | VTI B | Encryption |
|--------|-------|-------|------------|
| nv-sdwan ↔ nv-branch1 | 169.254.100.1/30 | 169.254.100.2/30 | AES-256 / SHA-256 / IKEv2 |
| fra-sdwan ↔ fra-branch1 | 169.254.100.13/30 | 169.254.100.14/30 | AES-256 / SHA-256 / IKEv2 |

### Cloud WAN BGP (Cross-Region, Tunnel-less)

| Router | Cloud WAN Peer IPs | Remote ASN | Transport |
|--------|--------------------|------------|-----------|
| nv-sdwan (64501) | Auto-assigned from 10.100.0.0/24 | Auto-assigned | NO_ENCAP (VPC fabric) |
| fra-sdwan (64502) | Auto-assigned from 10.100.1.0/24 | Auto-assigned | NO_ENCAP (VPC fabric) |

Cloud WAN assigns 2 BGP peer IPs per Connect peer for redundancy. The actual IPs are retrieved via a custom resource Lambda (`ConnectPeerBgpLookup`), stored in SSM Parameter Store, and read by the Phase 3 Lambda at runtime.

### BGP Segmentation

The Cloud WAN core network policy defines three segments with routing policies for community-based filtering:

| Segment | Purpose | Community Match | Routing Policy |
|---------|---------|-----------------|----------------|
| sdwan | SD-WAN hub connectivity | — (default) | — |
| Prod | Production traffic | `64501:100`, `64502:100` | `filterProdRoutes` |
| Dev | Development traffic | `64501:200`, `64502:200` | `filterDevRoutes` |

Route flow: Branch dummy interfaces → eBGP to SDWAN hub → route-map `CLOUDWAN-OUT` (community tagging) → Cloud WAN sdwan segment → `segment-actions` share with routing policy → Prod/Dev segments.

### Dummy Interfaces (Branch Routers)

| Router | Interface | Address | Segment |
|--------|-----------|---------|---------|
| nv-branch1 | dum0 | 10.250.1.1/32 | Prod |
| nv-branch1 | dum1 | 10.250.1.2/32 | Dev |
| fra-branch1 | dum0 | 10.250.2.1/32 | Prod |
| fra-branch1 | dum1 | 10.250.2.2/32 | Dev |

### Network CIDRs

| VPC | Region | CIDR |
|-----|--------|------|
| nv-branch1 | us-east-1 | 10.20.0.0/20 |
| nv-branch2 | us-east-1 | 10.30.0.0/20 |
| nv-sdwan | us-east-1 | 10.201.0.0/16 |
| fra-branch1 | eu-central-1 | 10.10.0.0/20 |
| fra-sdwan | eu-central-1 | 10.200.0.0/16 |
| Cloud WAN inside | Global | 10.100.0.0/16 |

## Cross-Region Deployment

CloudFormation does not natively support deploying stacks in other regions from a parent stack. This project uses a custom resource Lambda (`cross_region_stack.py`) to deploy the Frankfurt stack in `eu-central-1` from the parent stack in `us-east-1`. Similarly, Frankfurt SSM parameters are created via a custom resource Lambda embedded in the orchestration stack.

## Cleanup

```bash
aws cloudformation delete-stack \
  --stack-name sdwan-cloudwan-workshop \
  --region us-east-1
```

Note: Cloud WAN resources can take 5–15 minutes to delete. The cross-region deployer Lambda will automatically clean up the Frankfurt stack.

## License

This project is provided as-is for workshop and educational purposes.
