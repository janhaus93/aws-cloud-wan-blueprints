"""
Phase 4 Lambda Handler — Cloud WAN BGP Configuration via SSM Run Command.

Pushes tunnel-less BGP peering configuration to SDWAN VyOS routers for
Cloud WAN Connect peers. Targets nv-sdwan and fra-sdwan only.
Additive-only: does NOT modify or delete existing VPN/BGP configuration.
"""

import os
from ssm_utils import get_instance_configs, send_and_wait


SSM_PARAM_PREFIX = os.environ.get("SSM_PARAM_PREFIX", "/sdwan/")
SSM_TIMEOUT = int(os.environ.get("SSM_TIMEOUT", "300"))
SDWAN_BGP_ASN = 65001

# Private subnet gateways (first IP in each private subnet)
PRIVATE_SUBNET_GW = {
    "nv-sdwan": "10.201.1.1",
    "fra-sdwan": "10.200.1.1",
}

# Only SDWAN routers get Cloud WAN BGP config
SDWAN_ROUTERS = ["nv-sdwan", "fra-sdwan"]


def build_cloudwan_bgp_script(router_name, configs):
    """Generate a vbash script for Cloud WAN BGP on a single SDWAN router.

    For NO_ENCAP Connect peers, BGP runs directly over VPC fabric.
    Configures static routes to Cloud WAN peer IPs and BGP neighbors.

    Args:
        router_name: One of nv-sdwan, fra-sdwan
        configs: Dict from get_instance_configs() with cloudwan params

    Returns:
        str: vbash script for Cloud WAN BGP configuration
    """
    peer_ip1 = configs[router_name].get("cloudwan_peer_ip1", "")
    peer_ip2 = configs[router_name].get("cloudwan_peer_ip2", "")
    cloudwan_asn = configs[router_name].get("cloudwan_asn", "64512")
    gw = PRIVATE_SUBNET_GW[router_name]

    script = """#!/bin/vbash
source /opt/vyatta/etc/functions/script-template
configure

# Static routes to Cloud WAN peer IPs via private subnet gateway
set protocols static route {peer_ip1}/32 next-hop {gw}
""".format(peer_ip1=peer_ip1, gw=gw)

    if peer_ip2:
        script += "set protocols static route {peer_ip2}/32 next-hop {gw}\n".format(
            peer_ip2=peer_ip2, gw=gw
        )

    script += """
# BGP neighbor 1 for Cloud WAN
set protocols bgp {asn} neighbor {peer_ip1} remote-as {cloudwan_asn}
set protocols bgp {asn} neighbor {peer_ip1} ebgp-multihop 4
set protocols bgp {asn} neighbor {peer_ip1} address-family ipv4-unicast
""".format(asn=SDWAN_BGP_ASN, peer_ip1=peer_ip1, cloudwan_asn=cloudwan_asn)

    if peer_ip2:
        script += """
# BGP neighbor 2 for Cloud WAN (redundancy)
set protocols bgp {asn} neighbor {peer_ip2} remote-as {cloudwan_asn}
set protocols bgp {asn} neighbor {peer_ip2} ebgp-multihop 4
set protocols bgp {asn} neighbor {peer_ip2} address-family ipv4-unicast
""".format(asn=SDWAN_BGP_ASN, peer_ip2=peer_ip2, cloudwan_asn=cloudwan_asn)

    script += """
commit
save
exit
"""
    return script


def build_ssm_command(bgp_script):
    """Wrap a vbash script in an SSM command."""
    return """#!/bin/bash
set -e
cat > /tmp/vyos-cloudwan-bgp.sh <<'BGPEOF'
{bgp_script}
BGPEOF
lxc file push /tmp/vyos-cloudwan-bgp.sh router/tmp/vyos-cloudwan-bgp.sh
lxc exec router -- chmod +x /tmp/vyos-cloudwan-bgp.sh
lxc exec router -- /tmp/vyos-cloudwan-bgp.sh
""".format(bgp_script=bgp_script)


def handler(event, context):
    """Lambda handler for Phase 4 Cloud WAN BGP configuration.

    Reads instance configs and Cloud WAN Connect Peer params from SSM,
    generates per-router vbash scripts, and executes via SSM.
    """
    configs = get_instance_configs(param_prefix=SSM_PARAM_PREFIX)

    results = {}
    success_count = 0
    fail_count = 0

    for router_name in SDWAN_ROUTERS:
        if router_name not in configs:
            results[router_name] = {
                "status": "Failed",
                "command_id": "",
                "instance_id": "",
                "stdout": "",
                "stderr": f"Instance config not found for {router_name}",
            }
            fail_count += 1
            continue

        instance_id = configs[router_name]["instance_id"]
        region = configs[router_name]["region"]

        bgp_script = build_cloudwan_bgp_script(router_name, configs)
        ssm_cmd = build_ssm_command(bgp_script)

        result = send_and_wait(
            instance_id=instance_id,
            region=region,
            commands=ssm_cmd,
            timeout=SSM_TIMEOUT,
        )

        results[router_name] = result

        if result["status"] == "Success":
            success_count += 1
        else:
            fail_count += 1

    return {
        "phase": "phase4",
        "results": results,
        "success_count": success_count,
        "fail_count": fail_count,
    }
