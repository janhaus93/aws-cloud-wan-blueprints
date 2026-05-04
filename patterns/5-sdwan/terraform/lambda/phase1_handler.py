"""
Phase 1 Lambda Handler — Base Setup via SSM Run Command.

Installs packages, initializes LXD, deploys VyOS container, and applies
base DHCP configuration on all 4 SD-WAN Ubuntu instances via SSM.

Replicates the logic from phase1-base-setup.sh as an AWS Lambda function.
"""

import os
from ssm_utils import get_instance_configs, send_and_wait


# ECR Public source for the VyOS LXD image (anonymous HTTPS pull via oras).
# The image used to be hosted in a private S3 bucket; it's now published to a
# public ECR Public registry so the workshop is portable and doesn't require
# bucket permissions. Anonymous pulls work out of the box for any caller.
VYOS_ECR_PUBLIC_URI = os.environ.get(
    "VYOS_ECR_PUBLIC_URI",
    "public.ecr.aws/x9x1a6t3/vyos",
)
VYOS_ECR_IMAGE_TAG = os.environ.get("VYOS_ECR_IMAGE_TAG", "1.3.3")

# Oras CLI pinning — upgrade requires changing BOTH constants together.
ORAS_VERSION = "1.2.0"
ORAS_SHA256 = "5b3f1cbb86d869eee68120b9b45b9be983f3738442f87ee5f06b00edd0bab336"
ORAS_URL = (
    f"https://github.com/oras-project/oras/releases/download/"
    f"v{ORAS_VERSION}/oras_{ORAS_VERSION}_linux_amd64.tar.gz"
)

UBUNTU_PASSWORD = os.environ.get("UBUNTU_PASSWORD", "aws123")
SSM_PARAM_PREFIX = os.environ.get("SSM_PARAM_PREFIX", "/sdwan/")
SSM_TIMEOUT = int(os.environ.get("SSM_TIMEOUT", "600"))


def build_phase1_commands():
    """Generate the Phase1 shell script payload for SSM RunShellScript.

    Runs on each SD-WAN Ubuntu host: apt packages, snap wait + installs,
    ubuntu password, LXD preseed, oras CLI install, anonymous VyOS LXD
    image pull from ECR Public, container creation (eth0→ens6, eth1→ens7),
    base config.boot, and the Phase 1 VyOS script (eth0 DHCP with
    default-route-distance 10, eth1 no-default-route).

    Includes idempotency: stops/deletes existing router container before
    recreating; oras CLI install checks the existing version before
    re-downloading.

    Returns:
        str: Shell script to execute on each instance via SSM.
    """
    return f"""#!/bin/bash
set -e

# SSM RunShellScript runs with a minimal environment (no HOME). Oras needs
# HOME to locate its config/credential store at startup, even for anonymous
# pulls. Set it explicitly.
export HOME=/root

apt-get update -y
apt-get install -y python3-pip net-tools tmux curl unzip jq

# Wait for snapd to be ready before any snap operations
snap wait system seed.loaded
snap refresh --hold=forever
snap install lxd
snap install aws-cli --classic

# Set ubuntu password
echo "ubuntu:{UBUNTU_PASSWORD}" | chpasswd

# LXD init preseed
cat > /tmp/lxd.yaml <<'EOF'
config:
  images.auto_update_cached: false
storage_pools:
- name: default
  driver: dir
profiles:
- devices:
    root:
      path: /
      pool: default
      type: disk
  name: default
EOF
cat /tmp/lxd.yaml | lxd init --preseed || true

# Install oras CLI (pinned, SHA-256-verified, idempotent)
if ! command -v oras >/dev/null 2>&1 || [ "$(oras version 2>/dev/null | awk '/Version:/ {{print $2}}')" != "{ORAS_VERSION}" ]; then
    cd /tmp
    curl -fsSL -o oras.tar.gz "{ORAS_URL}"
    echo "{ORAS_SHA256}  oras.tar.gz" | sha256sum --check
    tar -xzf oras.tar.gz oras
    install -m 0755 oras /usr/local/bin/oras
    rm -f oras.tar.gz oras
fi

# Pull VyOS LXD image from ECR Public (anonymous)
rm -f /tmp/vyos.tar.gz
cd /tmp
oras pull "{VYOS_ECR_PUBLIC_URI}:{VYOS_ECR_IMAGE_TAG}"
mv /tmp/vyos_dxgl-1.3.3-bc64a3a-5_lxd_amd64.tar.gz /tmp/vyos.tar.gz
lxc image import /tmp/vyos.tar.gz --alias vyos 2>/dev/null || true

# Router container config
cat > /tmp/router.yaml <<'EOF'
architecture: x86_64
config:
  limits.cpu: '1'
  limits.memory: 2048MiB
devices:
  eth0:
    nictype: physical
    parent: ens6
    type: nic
  eth1:
    nictype: physical
    parent: ens7
    type: nic
EOF

# Idempotency: remove existing container if present
lxc stop router --force 2>/dev/null || true
lxc delete router 2>/dev/null || true

cat /tmp/router.yaml | lxc init vyos router

# Base config.boot
cat > /tmp/config.boot <<'EOF'
interfaces {{
    ethernet eth0 {{
        address dhcp
        description OUTSIDE
    }}
    ethernet eth1 {{
        address dhcp
        description INSIDE
    }}
    loopback lo {{
    }}
}}
system {{
    config-management {{
        commit-revisions 100
    }}
    host-name vyos
    login {{
        user vyos {{
            authentication {{
                plaintext-password "aws123"
            }}
        }}
    }}
    syslog {{
        global {{
            facility all {{
                level info
            }}
        }}
    }}
}}
EOF

lxc file push /tmp/config.boot router/opt/vyatta/etc/config/config.boot
lxc start router
sleep 30

# Phase 1 VyOS script - DHCP with route distances
cat > /tmp/vyos-phase1.sh <<'EOF'
#!/bin/vbash
source /opt/vyatta/etc/functions/script-template
configure
set interfaces ethernet eth0 description 'OUTSIDE'
set interfaces ethernet eth0 address dhcp
set interfaces ethernet eth0 dhcp-options default-route-distance 10
set interfaces ethernet eth1 description 'INSIDE'
set interfaces ethernet eth1 address dhcp
set interfaces ethernet eth1 dhcp-options no-default-route
commit
save
exit
EOF

lxc file push /tmp/vyos-phase1.sh router/tmp/vyos-phase1.sh
lxc exec router -- chmod +x /tmp/vyos-phase1.sh
lxc exec router -- /tmp/vyos-phase1.sh
"""


def handler(event, context):
    """Lambda handler for Phase 1 base setup.

    Reads instance configs from SSM Parameter Store, builds the Phase1
    command payload, and executes it on each instance via SSM RunShellScript.

    Args:
        event: Lambda event (passed from Step Functions, may contain prior phase results)
        context: Lambda context object

    Returns:
        dict: Structured result with per-instance status:
            - phase: "phase1"
            - results: dict keyed by instance name with status details
            - success_count: number of successful instances
            - fail_count: number of failed instances
    """
    # Load instance configurations from SSM Parameter Store
    configs = get_instance_configs(param_prefix=SSM_PARAM_PREFIX)

    # Build the command payload once (same for all instances)
    commands = build_phase1_commands()

    results = {}
    success_count = 0
    fail_count = 0

    for instance_name, config in configs.items():
        instance_id = config["instance_id"]
        region = config["region"]

        result = send_and_wait(
            instance_id=instance_id,
            region=region,
            commands=commands,
            timeout=SSM_TIMEOUT,
        )

        results[instance_name] = result

        if result["status"] == "Success":
            success_count += 1
        else:
            fail_count += 1

    return {
        "phase": "phase1",
        "results": results,
        "success_count": success_count,
        "fail_count": fail_count,
    }
