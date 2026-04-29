# SD-WAN Cloud WAN Workshop — Terraform

Deploy a multi-region SD-WAN overlay network on AWS with Cloud WAN backbone using Terraform. This project provisions Ubuntu EC2 instances running VyOS routers inside LXD containers, establishes IPsec VPN tunnels with plain eBGP peering, integrates AWS Cloud WAN with tunnel-less Connect attachments for cross-region route propagation, and orchestrates the entire configuration lifecycle through AWS Step Functions. A directly-attached prod VPC (`nv-prod-vpc`) is reachable over Cloud WAN from every branch.

## Current Architecture

The active blueprint implements a simplified two-segment Cloud WAN topology with a direct-attached prod VPC. The design collapses what used to be a three-segment (sdwan/Prod/Dev), community-tagged routing model into plain eBGP between branches and Cloud WAN, with segment sharing handled entirely by Cloud WAN policy actions.

## Architecture

```
┌───────────────── us-east-1 ─────────────────┐   ┌──────────── eu-central-1 ────────────┐
│                                              │   │                                       │
│  ┌─────────────┐   IPsec/BGP   ┌──────────┐ │   │  ┌─────────────┐  IPsec/BGP  ┌──────┐│
│  │  nv-sdwan   │◄─────────────►│nv-branch1│ │   │  │  fra-sdwan  │◄───────────►│fra-  ││
│  │  ASN 64501  │ VTI 100.1/2   │ASN 64503 │ │   │  │  ASN 64502  │VTI 100.13/14│branch1││
│  │  VPC 10.201 │               │VPC 10.20 │ │   │  │  VPC 10.200 │             │ASN   ││
│  │  plain eBGP │               │plain eBGP│ │   │  │  plain eBGP │             │64505 ││
│  │  (no r-map) │               │(no dummy)│ │   │  │  (no r-map) │             │VPC   ││
│  └──────┬──────┘               └──────────┘ │   │  └──────┬──────┘             │10.10 ││
│         │ NO_ENCAP BGP, no community tagging │   │         │ NO_ENCAP BGP       └──────┘│
│  ┌──────┴──────────────────────────────────────────────────┴─────────────────────────┐│
│  │              AWS Cloud WAN Core Network — Inside CIDR 10.100.0.0/16               ││
│  │         Segments: Hybrid | Prod     share actions: Hybrid ↔ Prod (no policy)      ││
│  └──────┬───────────────────────────────────────────────────────────────────────────┘│
│         │ native VPC attachment (segment = Prod)                                      │
│  ┌──────┴──────┐                                                                      │
│  │ nv-prod-vpc │                                                                      │
│  │  10.50.0/16 │   Prod_EC2 (10.50.1.x)                                              │
│  └─────────────┘                                                                      │
└──────────────────────────────────────────────┘   └───────────────────────────────────┘

Each SDWAN/branch instance: Ubuntu 22.04 (c5.large) → LXD → VyOS container
3 ENIs per SDWAN/branch instance: Management | Outside (WAN) | Inside (LAN)
nv-prod-vpc attaches directly to Cloud WAN — no VyOS, no IPsec, no Connect peer
```

## What It Does

1. **Provisions VPC infrastructure** across 2 AWS regions (5 VPCs — 2 SDWAN, 2 branch, 1 prod — each with public/private subnets, NAT gateways, and internet gateways) using the `terraform-aws-modules/vpc/aws` module
2. **Deploys Ubuntu EC2 instances** for SDWAN and branch routers with 3 network interfaces each, Elastic IPs, and security groups for VPN traffic. Provisions test EC2s only where reachability probes originate — one per branch VPC and one in `nv-prod-vpc`. The SDWAN VPCs carry only the VyOS router instance, no test EC2.
3. **Creates AWS Cloud WAN** global network, core network with external JSON policy (`cloudwan_policy.json`), VPC attachments, tunnel-less Connect attachments on the SDWAN side, and a native VPC attachment for `nv-prod-vpc`
4. **Stores runtime config in SSM Parameter Store** — instance IDs, EIPs, private IPs, Cloud WAN peer addresses, and per-branch test-subnet CIDRs under `/sdwan/` for Lambda consumption
5. **Bootstraps VyOS routers** inside LXD containers with correct file permissions for the vyos user
6. **Configures IPsec VPN tunnels** (IKEv2, AES-256, SHA-256) and **plain eBGP peering** between SDWAN and branch routers — each branch advertises its own VPC CIDR and its test-subnet CIDR, nothing else
7. **Configures Cloud WAN BGP** — tunnel-less eBGP sessions between SDWAN routers and Cloud WAN Connect peers, with no prefix-lists, no route-maps, and no community tagging
8. **Shares routes between segments** — Cloud WAN policy defines two bidirectional share actions (`Hybrid → Prod`, `Prod → Hybrid`) with no routing policy, giving branches direct reachability to `nv-prod-vpc` and vice versa
9. **Verifies connectivity** — IPsec SA status, BGP sessions (VPN and Cloud WAN), interface state, VTI ping tests, and persists results to SSM Parameter Store at `/sdwan/verification-results`
10. **Orchestrates everything** via AWS Step Functions + Lambda — no local scripts needed after `terraform apply`

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- AWS CLI configured with credentials for 2 regions (`us-east-1` and `eu-central-1`)
- An S3 bucket containing the VyOS LXD image (default: `fra-vyos-bucket` in `us-east-1`)

## Quick Start

```bash
# 1. Initialize Terraform
terraform init

# 2. Review the plan
terraform plan

# 3. Deploy infrastructure (Cloud WAN resources can take 10-15 minutes)
terraform apply

# 4. Start the SD-WAN configuration orchestration
#    The command is printed as a Terraform output after apply:
terraform output -raw start_orchestration_command | bash
```

After `terraform apply` completes, the `start_orchestration_command` output provides the exact AWS CLI command to trigger the Step Functions state machine. You can also copy it from the Terraform output and run it manually.

The state machine runs 4 phases automatically:

| Phase   | Lambda         | What It Does                                                                                                                                                                       | Wait After |
|---------|----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------|
| Phase 1 | `sdwan-phase1` | Installs packages, initializes LXD, deploys VyOS container with base DHCP config                                                                                                   | 60s        |
| Phase 2 | `sdwan-phase2` | Pushes IPsec tunnel (IKEv2, MOBIKE disabled) and plain eBGP peering; installs a static route + `redistribute static` so each branch advertises its `/28` test subnet into BGP; scopes `redistribute connected/static` via the `SAFE-REDISTRIBUTE` route-map so only RFC1918 prefixes enter BGP; restarts strongSwan after commit so the daemon picks up the new config | 90s        |
| Phase 3 | `sdwan-phase3` | Configures tunnel-less eBGP neighbors on SDWAN routers toward their Cloud WAN Connect peers, with `next-hop-self` (so branch prefixes propagate with the SDWAN hub's Connect-peer IP as next-hop) and `soft-reconfiguration inbound` (for non-disruptive policy reloads) | 30s        |
| Phase 4 | `sdwan-phase4` | Verifies IPsec SAs, BGP sessions (VPN + Cloud WAN), interface state, VTI ping; persists results to SSM                                                                             | —          |

## Project Structure

```
.
├── main.tf                    # Terraform version, provider requirements, multi-region config
├── variables.tf               # Input variables (ASNs, test-subnet CIDRs, etc.)
├── locals.tf                  # Local values (VPC CIDRs, VPN PSK, overlay destination set, tags)
├── outputs.tf                 # Instance IDs, EIPs, Cloud WAN config, orchestration command
│
├── vpc.tf                     # SDWAN + branch VPCs (terraform-aws-modules/vpc/aws)
├── nv_prod_vpc.tf             # nv-prod-vpc: VPC, EC2, security group, Cloud WAN attachment, routes
├── instances.tf               # IAM roles, AMI data sources, security groups, SDWAN/branch EC2s,
│                              #   ENIs (mgmt/outside/inside), EIPs
├── branch_test_instances.tf   # One test EC2 per branch VPC (segment-neutral), test subnets, SSM
├── cloudwan.tf                # Cloud WAN: global network, core network with policy attachment
│                              #   (references cloudwan_policy.json), SDWAN VPC attachments tagged
│                              #   segment=Hybrid, Connect attachments, Connect peers
├── cloudwan_policy.json       # Cloud WAN core network policy with two segments (Hybrid, Prod),
│                              #   two bidirectional share actions, no routing policies
├── ssm-parameters.tf          # SSM Parameter Store for Lambda runtime config
│                              #   (instance IDs, EIPs, private IPs, Cloud WAN peer IPs/ASNs;
│                              #    per-branch test-subnet CIDRs and inside-gateway-ip live in
│                              #    branch_test_instances.tf)
├── orchestration.tf           # Lambda functions (Phase 1-4), IAM roles, Step Functions
│                              #   state machine, CloudWatch log group
│
└── lambda/                    # Lambda function source code (Python 3.12)
    ├── ssm_utils.py           # Shared SSM utilities (parameter reads, command execution)
    ├── phase1_handler.py      # Phase 1: base setup (packages, LXD, VyOS, permissions fix)
    ├── phase2_handler.py      # Phase 2: VPN/plain-eBGP config (no dummy interfaces)
    ├── phase3_handler.py      # Phase 3: Cloud WAN plain eBGP config (no route-maps)
    └── phase4_handler.py      # Phase 4: verification (IPsec, BGP, Cloud WAN BGP, ping)
```

## Configuration

### Key Variables

| Variable                       | Default               | Description                                    |
|--------------------------------|-----------------------|------------------------------------------------|
| `sdwan_instance_type`          | `c5.large`            | EC2 instance type for SD-WAN hosts             |
| `vyos_s3_bucket`               | `fra-vyos-bucket`     | S3 bucket with VyOS LXD image                  |
| `vyos_s3_key`                  | `vyos_dxgl-1.3.3-...` | VyOS image filename in S3                      |
| `vpn_psk`                      | auto-generated        | IPsec pre-shared key (32 chars if not set)     |
| `nv_sdwan_bgp_asn`             | `64501`               | BGP ASN for nv-sdwan                           |
| `fra_sdwan_bgp_asn`            | `64502`               | BGP ASN for fra-sdwan                          |
| `nv_branch1_bgp_asn`           | `64503`               | BGP ASN for nv-branch1                         |
| `fra_branch1_bgp_asn`          | `64505`               | BGP ASN for fra-branch1                        |
| `nv_branch1_test_subnet_cidr`  | `10.20.3.0/28`        | nv-branch1 test-subnet CIDR                    |
| `fra_branch1_test_subnet_cidr` | `10.10.3.0/28`        | fra-branch1 test-subnet CIDR                   |
| `cloudwan_connect_cidr_nv`     | `10.100.0.0/24`       | Cloud WAN inside CIDR for us-east-1            |
| `cloudwan_connect_cidr_fra`    | `10.100.1.0/24`       | Cloud WAN inside CIDR for eu-central-1         |
| `cloudwan_segment_name`        | `Hybrid`              | Cloud WAN segment name for SDWAN attachments   |
| `enable_test_instances`        | `true`                | Feature gate for branch + prod test EC2s       |
| `phase1_wait_seconds`          | `60`                  | Wait time after Phase 1 before Phase 2         |
| `phase2_wait_seconds`          | `90`                  | Wait time after Phase 2 before Phase 3         |

### BGP ASN Assignment

Each router has a unique ASN in the 64501–64505 range, deliberately below the Cloud WAN allocation window (64512–65534) to avoid conflicts:

| Router     | ASN   | Role                      |
|------------|-------|---------------------------|
| nv-sdwan   | 64501 | SDWAN hub (us-east-1)     |
| fra-sdwan  | 64502 | SDWAN hub (eu-central-1)  |
| nv-branch1 | 64503 | Branch (us-east-1)        |
| fra-branch1| 64505 | Branch (eu-central-1)     |

### VPN Topology (Intra-Region)

| Tunnel                  | VTI A             | VTI B             | Encryption                 |
|-------------------------|-------------------|-------------------|----------------------------|
| nv-sdwan ↔ nv-branch1   | 169.254.100.1/30  | 169.254.100.2/30  | AES-256 / SHA-256 / IKEv2  |
| fra-sdwan ↔ fra-branch1 | 169.254.100.13/30 | 169.254.100.14/30 | AES-256 / SHA-256 / IKEv2  |

### Cloud WAN BGP (Cross-Region, Tunnel-less)

| Router            | Cloud WAN Peer IPs               | Remote ASN | Transport            |
|-------------------|----------------------------------|------------|----------------------|
| nv-sdwan (64501)  | Auto-assigned from 10.100.0.0/24 | 64512      | NO_ENCAP (VPC fabric)|
| fra-sdwan (64502) | Auto-assigned from 10.100.1.0/24 | 64513      | NO_ENCAP (VPC fabric)|

Cloud WAN assigns 2 BGP peer IPs per Connect peer for redundancy. The actual IPs are stored in SSM Parameter Store and read by the Phase 3 Lambda at runtime. Advertisements are plain eBGP — no community tags, no prefix-lists, no route-maps.

### Cloud WAN Segments and Sharing

Cloud WAN policy defines two segments with bidirectional share actions and no routing policies:

| Segment | Attachments                                | Purpose                                    |
|---------|--------------------------------------------|--------------------------------------------|
| Hybrid  | nv-sdwan VPC + Connect, fra-sdwan VPC + Connect | SD-WAN-facing segment for hub VPCs   |
| Prod    | nv-prod-vpc (native VPC attachment)        | Direct-attached prod segment               |

Share actions: `Hybrid → Prod` and `Prod → Hybrid`, both `mode = attachment-route`, no `routing-policy-names`. Branches reach `nv-prod-vpc` through the overlay + Cloud WAN, and `nv-prod-vpc` reaches each branch VPC via routes on its private route table targeting the Core Network ARN.

### Branch BGP Advertisements

Each branch router advertises exactly three networks: its loopback `/32`, its Branch_VPC CIDR, and its test-subnet CIDR.

| Router      | Loopback (`/32`) | VPC CIDR        | Test-subnet CIDR |
|-------------|------------------|-----------------|------------------|
| nv-branch1  | (loopback IP)    | 10.20.0.0/20    | 10.20.3.0/28     |
| fra-branch1 | (loopback IP)    | 10.10.0.0/20    | 10.10.3.0/28     |

No dummy interfaces. No per-segment prefixes. No community tagging.

The test subnet sits on a different subnet than the VyOS internal ENI, so VyOS cannot advertise it via `network` alone (strongSwan only advertises prefixes with a matching RIB entry). Phase 2 therefore installs a VyOS static route for the test subnet with next-hop set to the AWS VPC router (the `.1` of the VyOS internal subnet, published via SSM parameter `/sdwan/<branch>/inside-gateway-ip`) and then uses `redistribute static route-map SAFE-REDISTRIBUTE` to push the /28 into BGP.

The `SAFE-REDISTRIBUTE` route-map and prefix-list permit only RFC1918 ranges (`10/8`, `172.16/12`, `192.168/16`) — any non-private prefix (a DHCP-learned default route, link-local, public space) is implicitly denied. This prevents `0.0.0.0/0` or similar noise from ever leaking into Cloud WAN via `redistribute connected`.

### Network CIDRs

| VPC              | Region        | CIDR            |
|------------------|---------------|-----------------|
| nv-branch1       | us-east-1     | 10.20.0.0/20    |
| nv-sdwan         | us-east-1     | 10.201.0.0/16   |
| nv-prod-vpc      | us-east-1     | 10.50.0.0/16    |
| fra-branch1      | eu-central-1  | 10.10.0.0/20    |
| fra-sdwan        | eu-central-1  | 10.200.0.0/16   |
| Cloud WAN inside | Global        | 10.100.0.0/16   |

### Branch Private Route Table — Overlay Destinations

Each branch private route table carries three overlay routes (the `Overlay_Destination_Set` minus the branch's own VPC CIDR), each targeting the branch router's internal ENI:

| Branch       | Overlay Destinations                                |
|--------------|------------------------------------------------------|
| nv-branch1   | 10.10.0.0/20, 10.100.0.0/16, 10.50.0.0/16           |
| fra-branch1  | 10.20.0.0/20, 10.100.0.0/16, 10.50.0.0/16           |

The `0.0.0.0/0 → NAT gateway` default route is preserved on every private route table so SSM Session Manager continues to work.

## Reachability Verification

After `terraform apply` and the Step Functions run both succeed, verify reachability with `ping` via SSM Session Manager. Source/destination pairs:

| Probe | From                  | To                    |
|-------|-----------------------|-----------------------|
| 1     | nv-branch1 test EC2   | fra-branch1 test EC2  |
| 2     | nv-branch1 test EC2   | nv-prod-ec2           |
| 3     | fra-branch1 test EC2  | nv-prod-ec2           |
| 4     | nv-prod-ec2           | nv-branch1 test EC2   |
| 5     | nv-prod-ec2           | fra-branch1 test EC2  |

Get the instance IDs and private IPs from Terraform outputs:

```bash
terraform output nv_branch1_test_ec2_instance_id
terraform output fra_branch1_test_ec2_instance_id
terraform output nv_prod_ec2_instance_id
terraform output nv_branch1_test_ec2_private_ip
terraform output fra_branch1_test_ec2_private_ip
terraform output nv_prod_ec2_private_ip
```

Then open an SSM session to the source instance and ping the destination's private IP:

```bash
aws ssm start-session --target <source-instance-id> --region <source-region>
# inside the session:
ping -c 4 <destination-private-ip>
```

Expected: 4/4 ICMP replies on every probe. TCP/22 is intentionally closed on the test EC2s (they have no sshd), so `nc -vz <ip> 22` returning `Connection refused` is also a valid L3-reachability signal.

## Cleanup

```bash
terraform destroy
```

Note: Cloud WAN resources can take 5–15 minutes to delete.

## License

This project is provided as-is for workshop and educational purposes.
