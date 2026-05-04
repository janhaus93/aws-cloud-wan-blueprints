# SD-WAN Cloud WAN Workshop — CloudFormation

Deploy a multi-region SD-WAN overlay network on AWS with Cloud WAN backbone using CloudFormation. This project provisions Ubuntu EC2 instances running VyOS routers inside LXD containers, establishes IPsec VPN tunnels with BGP peering, integrates AWS Cloud WAN with tunnel-less Connect attachments for cross-region route propagation, shares routes bidirectionally between a `Hybrid` segment (SD-WAN hubs) and a `Prod` segment (direct-attached prod VPC), and orchestrates the entire configuration lifecycle through AWS Step Functions.

## Architecture

```
┌──────────────────────── us-east-1 ─────────────────────────┐   ┌──────────────── eu-central-1 ────────────────┐
│                                                             │   │                                               │
│  ┌─────────────┐    IPsec/BGP    ┌─────────────┐           │   │  ┌─────────────┐   IPsec/BGP   ┌───────────┐  │
│  │  nv-sdwan   │◄──────────────►│ nv-branch1  │           │   │  │  fra-sdwan  │◄─────────────►│fra-branch1│  │
│  │  ASN 64501  │  VTI 100.1/2   │  ASN 64503  │           │   │  │  ASN 64502  │ VTI 100.13/14 │ ASN 64505 │  │
│  │  VPC 10.201 │                 │  VPC 10.20  │           │   │  │  VPC 10.200 │               │ VPC 10.10 │  │
│  │             │                 │  + test EC2 │           │   │  │             │               │ + test EC2│  │
│  └──────┬──────┘                 └─────────────┘           │   │  └──────┬──────┘               └───────────┘  │
│         │ BGP (tunnel-less, NO_ENCAP, plain eBGP)           │   │         │ BGP (tunnel-less, NO_ENCAP, plain) │
│  ┌──────┴────────────────────────────────────────────────┬──┴───┴─────────┴─────────────────────────────────┐  │
│  │                         AWS Cloud WAN Core Network                                                        │  │
│  │      Segments: Hybrid | Prod     Connect Peer CIDRs: 10.100.0.0/24 (NV), 10.100.1.0/24 (FRA)              │  │
│  │      segment-actions: share Hybrid↔Prod (bidirectional, no routing-policy-names, no community filters)    │  │
│  └───────────────────────────────────────────────────────────┬───────────────────────────────────────────────┘  │
│                                                              │ Prod (direct VPC attachment)                     │
│                                                        ┌─────┴──────┐                                            │
│                                                        │ nv-prod-vpc│                                            │
│                                                        │  10.50/16  │                                            │
│                                                        │  + Prod EC2│                                            │
│                                                        │  (SSM only)│                                            │
│                                                        └────────────┘                                            │
└─────────────────────────────────────────────────────────────┘   └──────────────────────────────────────────────┘

Each SD-WAN / Branch instance: Ubuntu 22.04 (c5.large) → LXD → VyOS container
3 ENIs per router instance: Management | Outside (WAN) | Inside (LAN)
nv-prod-vpc runs a single Amazon Linux EC2 reachable via SSM Session Manager only.
```

## What It Does

1. **Provisions VPC infrastructure** across 2 AWS regions (5 VPCs total: `nv-branch1`, `nv-sdwan`, `nv-prod` in us-east-1; `fra-branch1`, `fra-sdwan` in eu-central-1 — each with public/private subnets, NAT gateways, and internet gateways)
2. **Deploys Ubuntu EC2 instances** with 3 network interfaces each, Elastic IPs, and security groups for VPN traffic (SD-WAN / Branch routers); plus a single Amazon Linux EC2 in `nv-prod-vpc` with an instance profile scoped to SSM Session Manager
3. **Creates AWS Cloud WAN** global network, core network with inline policy (2 segments: `Hybrid` and `Prod`), VPC attachments (SD-WAN VPCs to `Hybrid`, `nv-prod-vpc` direct to `Prod`), tunnel-less Connect attachments, and Connect peers
4. **Stores runtime config in SSM Parameter Store** — instance IDs, EIPs, private IPs, Cloud WAN peer addresses, and per-branch test subnet CIDRs under `/sdwan/` for Lambda consumption
5. **Bootstraps VyOS routers** inside LXD containers with correct file permissions for the vyos user
6. **Configures IPsec VPN tunnels** (IKEv2, AES-256, SHA-256) and **eBGP peering** between SD-WAN and branch routers; branches advertise their `/20` VPC CIDR plus their test subnet `/24` (no dummy interfaces)
7. **Configures Cloud WAN BGP** — tunnel-less eBGP sessions between SDWAN routers and Cloud WAN Connect peers; plain eBGP with no community tagging, no prefix-lists, and no `CLOUDWAN-OUT` route-map
8. **Shares routes bidirectionally between `Hybrid` and `Prod`** — the Cloud WAN policy declares two `segment-actions` (`Hybrid`→`Prod` and `Prod`→`Hybrid`, both `share` with `mode: attachment-route`), so all routes flow between the two segments without any routing-policy filtering
9. **Verifies connectivity** — IPsec SA status, BGP sessions (VPN and Cloud WAN), interface state, VTI ping tests, and persists results to SSM Parameter Store at `/sdwan/verification-results`
10. **Orchestrates everything** via AWS Step Functions + Lambda — no local scripts needed after stack deployment

## Prerequisites

- AWS CLI configured with credentials for 2 regions (`us-east-1` and `eu-central-1`)
- An S3 bucket containing:
  - The `lambda.zip` deployment package (upload from this repo)
  - All CloudFormation templates from the `templates/` directory

The VyOS LXD image is pulled at Phase 1 runtime from the public ECR repository `public.ecr.aws/<alias>/vyos:1.3.3` using the `oras` CLI (anonymous HTTPS pull — no AWS credentials required). Consumers need take no action on the image: the `oras` CLI is downloaded and installed by Phase 1 itself on each SD-WAN Ubuntu host, and the default `VyosEcrPublicUri` / `VyosEcrImageTag` parameter values already point at the maintainer's canonical public repository.

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
| Phase 2 | `sdwan-phase2` | Pushes IPsec tunnel and BGP peering config; branches advertise their VPC `/20` and test subnet `/24` via BGP `network` statements (no dummy interfaces) | 90s |
| Phase 3 | `sdwan-phase3` | Cloud WAN BGP config — tunnel-less eBGP neighbors on SDWAN routers; plain route exchange with no prefix-lists, no community tagging, and no `CLOUDWAN-OUT` route-map | 30s |
| Phase 4 | `sdwan-phase4` | Verification: IPsec, BGP, Cloud WAN BGP, connectivity — checks all sessions and persists results to SSM | — |

## Stack Architecture

The deployment uses a parent stack that orchestrates 4 nested/custom-resource stacks:

```
parent-stack.yaml
├── virginia-stack.yaml          (nested, us-east-1)
│   └── 3 VPCs (nv-branch1, nv-sdwan, nv-prod), SGs, EC2 (SD-WAN, Branch, Prod, Branch test), ENIs, EIPs, IAM role/profile
├── Custom::CrossRegionStack     (Lambda-backed, eu-central-1)
│   └── frankfurt-stack.yaml
│       └── 2 VPCs (fra-branch1, fra-sdwan), SGs, EC2 (SD-WAN, Branch, Branch test), ENIs, EIPs
├── cloudwan-stack.yaml          (nested, us-east-1)
│   └── Global Network, Core Network + policy (2 segments: Hybrid, Prod),
│       VPC attachments (2 SD-WAN → Hybrid, nv-prod → Prod),
│       Connect attachments, Connect peers, BGP lookup custom resources
└── orchestration-stack.yaml     (nested, us-east-1)
    └── Lambda IAM, Phase 1-4 Lambdas, SSM params (us-east-1 + eu-central-1),
        Step Functions state machine, CloudWatch log group
```

## Project Structure

```
.
├── README.md                      # This file
├── lambda.zip                     # Pre-built Lambda deployment package (rebuild with `cd lambda && zip -r ../lambda.zip *.py`)
│
├── lambda/                        # Lambda function source code (Python 3.12)
│   ├── ssm_utils.py               # Shared SSM utilities (parameter reads, command execution)
│   ├── phase1_handler.py          # Phase 1: base setup (packages, LXD, VyOS, permissions fix)
│   ├── phase2_handler.py          # Phase 2: VPN/BGP config — branches advertise VPC /20 + test subnet /24
│   ├── phase3_handler.py          # Phase 3: Cloud WAN BGP config — plain eBGP, no community tagging
│   ├── phase4_handler.py          # Phase 4: verification (IPsec, BGP, Cloud WAN BGP, ping)
│   └── cross_region_stack.py      # Custom resource handler for cross-region stack deployment
│
├── templates/                     # CloudFormation templates
│   ├── parent-stack.yaml          # Top-level stack — orchestrates all nested stacks
│   ├── virginia-stack.yaml        # us-east-1: 3 VPCs (nv-branch1, nv-sdwan, nv-prod), SGs, EC2, IAM
│   ├── frankfurt-stack.yaml       # eu-central-1: 2 VPCs (fra-branch1, fra-sdwan), SGs, EC2
│   ├── cloudwan-stack.yaml        # Cloud WAN: global network, core network, policy (Hybrid + Prod),
│   │                              #   attachments, connect peers, BGP lookup
│   └── orchestration-stack.yaml   # Step Functions, Lambda functions, SSM parameters,
│                                  #   IAM roles, CloudWatch log group
│
└── .kiro/specs/                   # Design artefacts for the "simplify to Hybrid+Prod topology" refactor
    └── architecture-simplification-prod-vpc/
        ├── requirements.md
        ├── design.md
        └── tasks.md
```

## Configuration

### Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SdwanInstanceType` | `c5.large` | EC2 instance type for SD-WAN hosts |
| `VyosEcrPublicUri` | `public.ecr.aws/<alias>/vyos` | ECR Public URI of the VyOS LXD image OCI artifact (no tag suffix) |
| `VyosEcrImageTag` | `1.3.3` | OCI artifact tag to pull (matches upstream VyOS release identifier) |
| `NvSdwanBgpAsn` | `64501` | BGP ASN for the `nv-sdwan` Cloud WAN Connect Peer (must match the ASN VyOS advertises) |
| `FraSdwanBgpAsn` | `64502` | BGP ASN for the `fra-sdwan` Cloud WAN Connect Peer (must match the ASN VyOS advertises) |
| `SdwanBgpAsn` | `65001` | Deprecated — retained for backward compatibility only. Per-hub ASNs are `NvSdwanBgpAsn` / `FraSdwanBgpAsn`. |
| `CloudWanConnectCidrNv` | `10.100.0.0/24` | Cloud WAN inside CIDR for us-east-1 |
| `CloudWanConnectCidrFra` | `10.100.1.0/24` | Cloud WAN inside CIDR for eu-central-1 |
| `CloudWanSegmentName` | `Hybrid` | Cloud WAN segment name for SDWAN attachments |
| `NvBranch1TestSubnetCidr` | `10.20.3.0/24` | CIDR for the nv-branch1 test EC2 subnet (advertised into BGP by the branch VyOS) |
| `FraBranch1TestSubnetCidr` | `10.10.3.0/24` | CIDR for the fra-branch1 test EC2 subnet (advertised into BGP by the branch VyOS) |
| `LambdaS3Bucket` | *(required)* | S3 bucket containing `lambda.zip` |
| `LambdaS3Key` | *(required)* | S3 key for the Lambda deployment zip |
| `TemplateBaseUrl` | *(required)* | S3 URL prefix where nested stack templates are stored |
| `Phase1WaitSeconds` | `60` | Wait time after Phase 1 before Phase 2 |
| `Phase2WaitSeconds` | `90` | Wait time after Phase 2 before Phase 3 |
| `Phase3WaitSeconds` | `30` | Wait time after Phase 3 before Phase 4 |

### BGP ASN Assignment

Each router has a unique ASN. The SD-WAN hub ASNs are also exposed as CloudFormation parameters (`NvSdwanBgpAsn` / `FraSdwanBgpAsn`) so the Cloud WAN Connect Peers' `PeerAsn` stays in sync with what VyOS actually advertises — a mismatch results in `NOTIFICATION: Bad Peer AS` and BGP never comes up.

| Router | ASN | Role |
|--------|-----|------|
| nv-sdwan | 64501 | SDWAN hub (us-east-1) — matches `NvSdwanBgpAsn` parameter |
| fra-sdwan | 64502 | SDWAN hub (eu-central-1) — matches `FraSdwanBgpAsn` parameter |
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

The Cloud WAN core network policy defines two segments with bidirectional route sharing and no routing-policy filtering:

| Segment | Purpose | Attachments |
|---------|---------|-------------|
| `Hybrid` | SD-WAN hub connectivity | `nv-sdwan` VPC attachment, `fra-sdwan` VPC attachment, SDWAN Connect attachments |
| `Prod` | Direct-attached production | `nv-prod-vpc` VPC attachment |

The policy's `segment-actions` block contains two entries, both using `action: share` with `mode: attachment-route` and no `routing-policy-names`:

- `Hybrid` → shares with `Prod`
- `Prod` → shares with `Hybrid`

Route flow: branch routers advertise their VPC `/20` and test-subnet `/24` via eBGP to the local SDWAN hub → SDWAN hub advertises them tunnel-less (NO_ENCAP) to the Cloud WAN Connect peer into the `Hybrid` segment → Cloud WAN shares Hybrid routes into `Prod` and `nv-prod-vpc` routes back into `Hybrid`. No community tagging, no prefix-list filtering, and no routing policies are involved.

**Test-subnet advertisement detail.** The branch test subnets (`10.20.3.0/24`, `10.10.3.0/24`) live on a different subnet from the branch VyOS's internal ENI. To make VyOS accept them for BGP advertisement, Phase 2 installs a VyOS static route toward the AWS VPC implicit router (`.1` of the branch inside subnet, published via the `/sdwan/<branch>/inside-gateway-ip` SSM parameter) and relies on `redistribute static` through a `SAFE-REDISTRIBUTE` prefix-list / route-map that whitelists RFC1918 only. `redistribute connected` is also scoped to the same route-map so VTI `/30`s, link-local, and the Cloud WAN inside CIDR never leak into the fabric.

### Network CIDRs

| VPC | Region | CIDR | Cloud WAN segment |
|-----|--------|------|-------------------|
| nv-branch1 | us-east-1 | 10.20.0.0/20 | — (overlay only, via VyOS) |
| nv-branch1 test subnet | us-east-1 | 10.20.3.0/24 | — (advertised into Hybrid via branch VyOS) |
| nv-sdwan | us-east-1 | 10.201.0.0/16 | Hybrid |
| nv-prod | us-east-1 | 10.50.0.0/16 | Prod (direct VPC attachment) |
| fra-branch1 | eu-central-1 | 10.10.0.0/20 | — (overlay only, via VyOS) |
| fra-branch1 test subnet | eu-central-1 | 10.10.3.0/24 | — (advertised into Hybrid via branch VyOS) |
| fra-sdwan | eu-central-1 | 10.200.0.0/16 | Hybrid |
| Cloud WAN inside (NV) | us-east-1 | 10.100.0.0/24 | Connect Peer CIDR |
| Cloud WAN inside (FRA) | eu-central-1 | 10.100.1.0/24 | Connect Peer CIDR |

## Cross-Region Deployment

CloudFormation does not natively support deploying stacks in other regions from a parent stack. This project uses a custom resource Lambda (`cross_region_stack.py`) to deploy the Frankfurt stack in `eu-central-1` from the parent stack in `us-east-1`. Similarly, Frankfurt SSM parameters are created via a custom resource Lambda embedded in the orchestration stack.

## Verification

After Step Functions reports `SUCCEEDED`, you can confirm reachability end-to-end with five SSM Session Manager ping probes from each test EC2 and the Prod EC2. Instance IDs are in the parent stack outputs (`NvBranch1TestEc2InstanceId`, `FraBranch1TestEc2InstanceId`, `NvProdEc2InstanceId`) and the probe commands are listed in `NvBranch1TestEc2SsmCommand` / `FraBranch1TestEc2SsmCommand` / `NvProdEc2SsmCommand`.

| Probe | Source | Target | Path |
|-------|--------|--------|------|
| 1 | nv-branch1 test EC2 | fra-branch1 test EC2 | VyOS overlay (nv-branch1 → nv-sdwan → Cloud WAN Hybrid → fra-sdwan → fra-branch1) |
| 2 | nv-branch1 test EC2 | Prod EC2 | nv-branch1 → nv-sdwan → Cloud WAN Hybrid → Cloud WAN Prod → nv-prod-vpc |
| 3 | fra-branch1 test EC2 | Prod EC2 | fra-branch1 → fra-sdwan → Cloud WAN Hybrid → Cloud WAN Prod → nv-prod-vpc |
| 4 | Prod EC2 | nv-branch1 test EC2 | reverse of probe 2 |
| 5 | Prod EC2 | fra-branch1 test EC2 | reverse of probe 3 |

For each probe, open an SSM session (`aws ssm start-session --target <InstanceId> --region <region>`) and run `ping -c 4 <target-private-ip>`. All five should succeed.

## Publishing the VyOS Image to ECR Public (maintainers only)

> **Consumers do NOT need to run this procedure.** The default `VyosEcrPublicUri` parameter already points at the maintainer's public ECR repository, which permits anonymous pulls from any AWS account and region. This section is only for repository maintainers publishing a new VyOS release.

### 1. Create the ECR Public repository

Create a repository named `vyos` under the maintainer's ECR Public registry alias. ECR Public repositories allow anonymous pulls by default — no extra policy or IAM configuration is required for the pull side.

```bash
aws ecr-public create-repository \
  --repository-name vyos \
  --region us-east-1
```

(ECR Public's API endpoint lives in `us-east-1` regardless of where the image is pulled from; the gallery itself serves global anonymous pulls.)

### 2. Download the upstream VyOS tarball

Fetch the current `vyos_dxgl-1.3.3-bc64a3a-5_lxd_amd64.tar.gz` tarball from its upstream location. Compute its SHA-256 digest and record the value as the canonical byte-identity reference used in step 6b.

```bash
sha256sum vyos_dxgl-1.3.3-bc64a3a-5_lxd_amd64.tar.gz
# → record this digest — the pulled blob in step 6b must match it byte-for-byte
```

### 3. Install the `oras` CLI locally

Install the [`oras`](https://oras.land/docs/) CLI, pinned to the same version that `lambda/phase1_handler.py` uses (see the `ORAS_VERSION` module-level constant). Pinning the maintainer CLI to the handler's pinned version keeps the publish and pull sides in lockstep.

### 4. Push the tarball as a single-layer OCI artifact

Push the tarball unmodified as the single blob of a single-manifest OCI artifact. The artifact media type identifies the payload as a VyOS LXD image tarball; annotations carry provenance metadata.

```bash
oras push public.ecr.aws/<alias>/vyos:1.3.3 \
    --artifact-type application/vnd.vyos.lxd.image.tar.gz \
    --annotation org.opencontainers.image.source=<repo-url> \
    --annotation org.opencontainers.image.version=1.3.3 \
    --annotation org.opencontainers.image.description="VyOS 1.3.3 LXD image" \
    vyos_dxgl-1.3.3-bc64a3a-5_lxd_amd64.tar.gz:application/vnd.vyos.lxd.image.tar.gz
```

Notes on the command:

- The trailing `<file>:<media-type>` syntax tells `oras` to push the file as a layer with that media type (rather than inferring one).
- `oras` automatically sets the layer's `org.opencontainers.image.title` annotation to the filename `vyos_dxgl-1.3.3-bc64a3a-5_lxd_amd64.tar.gz`. This is what makes a subsequent `oras pull` write the blob to disk under the same filename — Phase 1 relies on this behaviour and then renames the file to `/tmp/vyos.tar.gz`.

### 5. Apply the `latest` tag to the same manifest digest

Apply a mutable `latest` tag that points at the exact manifest digest produced in step 4:

```bash
oras tag public.ecr.aws/<alias>/vyos:1.3.3 latest
```

Confirm both tags resolve to the same manifest digest:

```bash
oras manifest fetch --descriptor public.ecr.aws/<alias>/vyos:1.3.3
oras manifest fetch --descriptor public.ecr.aws/<alias>/vyos:latest
```

The two descriptors printed must carry identical `digest` fields.

### 6. Verify the published artifact

#### 6a. HTTP 200 on the unauthenticated manifest endpoint

```bash
curl -fsSI "https://public.ecr.aws/v2/<alias>/vyos/manifests/1.3.3"
curl -fsSI "https://public.ecr.aws/v2/<alias>/vyos/manifests/latest"
```

Both requests must return `200 OK`. Any 4xx / 5xx here means the repository is not anonymously pullable and Phase 1 will fail on Consumer deployments.

#### 6b. Byte-identity verification via anonymous `oras pull`

From a machine with no AWS credentials configured (or with `AWS_PROFILE` / `AWS_ACCESS_KEY_ID` deliberately unset), pull the artifact back down and recompute the digest:

```bash
mkdir -p /tmp/verify
oras pull public.ecr.aws/<alias>/vyos:1.3.3 --output /tmp/verify/
sha256sum /tmp/verify/vyos_dxgl-1.3.3-bc64a3a-5_lxd_amd64.tar.gz
```

The resulting SHA-256 digest MUST equal the digest recorded in step 2. Any mismatch indicates the bytes in ECR Public are not the same bytes as the upstream tarball, and the release must be re-published before Consumers use it.

## Cleanup

```bash
aws cloudformation delete-stack \
  --stack-name sdwan-cloudwan-workshop \
  --region us-east-1
```

Note: Cloud WAN resources can take 5–15 minutes to delete. The cross-region deployer Lambda will automatically clean up the Frankfurt stack.

## License

This project is provided as-is for workshop and educational purposes.
