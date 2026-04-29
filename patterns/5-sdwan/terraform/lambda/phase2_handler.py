"""
Phase 2 Lambda Handler — VPN/BGP Configuration via SSM Run Command.

Pushes IPsec VPN tunnels and BGP peering configuration to each VyOS router
on all 4 SD-WAN Ubuntu instances via SSM.

Replicates the logic from phase2-vpn-bgp-config.sh as an AWS Lambda function.
"""

import os
from ssm_utils import get_instance_configs, send_and_wait


# Configurable via environment variables
VPN_PSK = os.environ.get("VPN_PSK", "aws123")
SSM_PARAM_PREFIX = os.environ.get("SSM_PARAM_PREFIX", "/sdwan/")
SSM_TIMEOUT = int(os.environ.get("SSM_TIMEOUT", "300"))


# VPN tunnel topology — intra-region only
TUNNELS = [
    {
        "router_a": "nv-sdwan",
        "router_b": "nv-branch1",
        "vti_a": {"name": "vti0", "addr": "169.254.100.1/30"},
        "vti_b": {"name": "vti0", "addr": "169.254.100.2/30"},
    },
    {
        "router_a": "fra-sdwan",
        "router_b": "fra-branch1",
        "vti_a": {"name": "vti0", "addr": "169.254.100.13/30"},
        "vti_b": {"name": "vti0", "addr": "169.254.100.14/30"},
    },
]

# Per-router configuration: loopback, ASN, role
ROUTER_CONFIG = {
    "nv-sdwan":    {"loopback": "10.255.0.1",  "asn": 64501, "role": "sdwan"},
    "nv-branch1":  {"loopback": "10.255.1.1",  "asn": 64503, "role": "branch"},
    "fra-sdwan":   {"loopback": "10.255.10.1", "asn": 64502, "role": "sdwan"},
    "fra-branch1": {"loopback": "10.255.11.1", "asn": 64505, "role": "branch"},
}

# Branch VPC CIDRs for BGP network advertisement
BRANCH_VPC_CIDR = {
    "nv-branch1": "10.20.0.0/20",
    "fra-branch1": "10.10.0.0/20",
}


def get_tunnel_info(router_name):
    """Find the tunnel entry and peer info for a given router.

    Args:
        router_name: One of nv-sdwan, nv-branch1, fra-sdwan, fra-branch1

    Returns:
        list of dicts, each with keys:
            - my_vti: VTI interface name (e.g. vti0)
            - my_vti_addr: VTI address with mask (e.g. 169.254.100.1/30)
            - peer_name: Peer router name
            - peer_vti_ip: Peer VTI IP without mask (e.g. 169.254.100.2)
        Returns empty list if router has no tunnels.
    """
    results = []
    for tunnel in TUNNELS:
        if router_name == tunnel["router_a"]:
            peer_vti_ip = tunnel["vti_b"]["addr"].split("/")[0]
            results.append({
                "my_vti": tunnel["vti_a"]["name"],
                "my_vti_addr": tunnel["vti_a"]["addr"],
                "peer_name": tunnel["router_b"],
                "peer_vti_ip": peer_vti_ip,
            })
        elif router_name == tunnel["router_b"]:
            peer_vti_ip = tunnel["vti_a"]["addr"].split("/")[0]
            results.append({
                "my_vti": tunnel["vti_b"]["name"],
                "my_vti_addr": tunnel["vti_b"]["addr"],
                "peer_name": tunnel["router_a"],
                "peer_vti_ip": peer_vti_ip,
            })
    return results


def build_vpn_bgp_script(router_name, instance_configs):
    """Generate a vbash script for VPN/BGP configuration on a single router.

    Produces the same VyOS configuration as the bash script's build_vpn_bgp_script():
    loopback, VTI interfaces, IPsec IKE/ESP groups, IPsec peers, BGP neighbors.

    Args:
        router_name: One of nv-sdwan, nv-branch1, fra-sdwan, fra-branch1
        instance_configs: Dict from get_instance_configs() with all instance info

    Returns:
        str: vbash script to configure VPN/BGP on the router
    """
    cfg = ROUTER_CONFIG[router_name]
    loopback = cfg["loopback"]
    asn = cfg["asn"]
    local_private_ip = instance_configs[router_name]["outside_private_ip"]

    tunnel_infos = get_tunnel_info(router_name)

    # Start vbash script
    script = """#!/bin/vbash
source /opt/vyatta/etc/functions/script-template
configure

# Loopback
set interfaces loopback lo address {loopback}/32
""".format(loopback=loopback)

    # Branch VPC CIDR + test-subnet BGP advertisements (branches only)
    branch_bgp_networks = ""
    if router_name in BRANCH_VPC_CIDR:
        branch_bgp_networks += "set protocols bgp {asn} network {cidr}\n".format(
            asn=asn, cidr=BRANCH_VPC_CIDR[router_name]
        )
        test_subnet = instance_configs[router_name].get("test_subnet")
        inside_gateway_ip = instance_configs[router_name].get("inside_gateway_ip")
        if test_subnet and inside_gateway_ip:
            # The test subnet is on a DIFFERENT subnet from the VyOS internal
            # ENI. Without a matching RIB entry VyOS refuses to advertise via
            # `network`, so install a static route toward the AWS VPC router
            # (.1 of the inside subnet) first.
            branch_bgp_networks += (
                "set protocols static route {cidr} next-hop {gw}\n".format(
                    cidr=test_subnet, gw=inside_gateway_ip
                )
            )
            branch_bgp_networks += "set protocols bgp {asn} network {cidr}\n".format(
                asn=asn, cidr=test_subnet
            )

    # VTI interfaces
    for t in tunnel_infos:
        script += """
# VTI to {peer_name}
set interfaces vti {my_vti} address {my_vti_addr}
""".format(peer_name=t["peer_name"], my_vti=t["my_vti"], my_vti_addr=t["my_vti_addr"])

    # IPsec global settings
    script += """
# IPsec global settings
set vpn ipsec interface eth0
set vpn ipsec esp-group ESP-GROUP compression disable
set vpn ipsec esp-group ESP-GROUP lifetime 3600
set vpn ipsec esp-group ESP-GROUP mode tunnel
set vpn ipsec esp-group ESP-GROUP pfs dh-group14
set vpn ipsec esp-group ESP-GROUP proposal 1 encryption aes256
set vpn ipsec esp-group ESP-GROUP proposal 1 hash sha256
set vpn ipsec ike-group IKE-GROUP key-exchange ikev2
set vpn ipsec ike-group IKE-GROUP lifetime 28800
set vpn ipsec ike-group IKE-GROUP mobike disable
set vpn ipsec ike-group IKE-GROUP proposal 1 dh-group 14
set vpn ipsec ike-group IKE-GROUP proposal 1 encryption aes256
set vpn ipsec ike-group IKE-GROUP proposal 1 hash sha256
"""

    # IPsec peers
    for t in tunnel_infos:
        peer_name = t["peer_name"]
        peer_eip = instance_configs[peer_name]["outside_eip"]
        peer_private_ip = instance_configs[peer_name]["outside_private_ip"]

        script += """
# IPsec peer: {peer_name}
set vpn ipsec site-to-site peer {peer_eip} authentication mode pre-shared-secret
set vpn ipsec site-to-site peer {peer_eip} authentication pre-shared-secret '{vpn_psk}'
set vpn ipsec site-to-site peer {peer_eip} authentication remote-id {peer_private_ip}
set vpn ipsec site-to-site peer {peer_eip} connection-type initiate
set vpn ipsec site-to-site peer {peer_eip} ike-group IKE-GROUP
set vpn ipsec site-to-site peer {peer_eip} local-address {local_private_ip}
set vpn ipsec site-to-site peer {peer_eip} vti bind {my_vti}
set vpn ipsec site-to-site peer {peer_eip} vti esp-group ESP-GROUP
""".format(
            peer_name=peer_name,
            peer_eip=peer_eip,
            vpn_psk=VPN_PSK,
            peer_private_ip=peer_private_ip,
            local_private_ip=local_private_ip,
            my_vti=t["my_vti"],
        )

    # BGP configuration
    for t in tunnel_infos:
        peer_name = t["peer_name"]
        peer_asn = ROUTER_CONFIG[peer_name]["asn"]
        my_vti_ip = t["my_vti_addr"].split("/")[0]

        script += """
# BGP neighbor: {peer_name}
set protocols bgp {asn} neighbor {peer_vti_ip} ebgp-multihop 2
set protocols bgp {asn} neighbor {peer_vti_ip} remote-as {peer_asn}
set protocols bgp {asn} neighbor {peer_vti_ip} update-source {my_vti_ip}
""".format(
            peer_name=peer_name,
            asn=asn,
            peer_vti_ip=t["peer_vti_ip"],
            peer_asn=peer_asn,
            my_vti_ip=my_vti_ip,
        )

    # BGP network and router-id
    # On branch routers we also `redistribute static` so the test-subnet
    # static route installed above is reliably advertised into BGP regardless
    # of whether VyOS's `network` statement picks up the non-connected RIB
    # entry on this VyOS version.
    redistribute_static = ""
    if router_name in BRANCH_VPC_CIDR:
        redistribute_static = (
            "set protocols bgp {asn} address-family ipv4-unicast "
            "redistribute static route-map SAFE-REDISTRIBUTE\n".format(asn=asn)
        )

    # Scope redistribute-connected to RFC1918-only prefixes so a default
    # route or any non-private connected prefix (for example a VTI /30, the
    # Cloud WAN inside CIDR 10.100.0.0/16, or a stray DHCP route) never
    # propagates into BGP. Without this, `redistribute connected` will inject
    # 0.0.0.0/0 or 169.254.0.0/16 into Cloud WAN and pollute the fabric.
    script += """
set protocols bgp {asn} network {loopback}/32
{branch_bgp_networks}set protocols bgp {asn} parameters router-id {loopback}
set policy prefix-list SAFE-REDISTRIBUTE rule 10 action permit
set policy prefix-list SAFE-REDISTRIBUTE rule 10 prefix 10.0.0.0/8
set policy prefix-list SAFE-REDISTRIBUTE rule 10 le 32
set policy prefix-list SAFE-REDISTRIBUTE rule 20 action permit
set policy prefix-list SAFE-REDISTRIBUTE rule 20 prefix 172.16.0.0/12
set policy prefix-list SAFE-REDISTRIBUTE rule 20 le 32
set policy prefix-list SAFE-REDISTRIBUTE rule 30 action permit
set policy prefix-list SAFE-REDISTRIBUTE rule 30 prefix 192.168.0.0/16
set policy prefix-list SAFE-REDISTRIBUTE rule 30 le 32
set policy route-map SAFE-REDISTRIBUTE rule 10 action permit
set policy route-map SAFE-REDISTRIBUTE rule 10 match ip address prefix-list SAFE-REDISTRIBUTE
set protocols bgp {asn} address-family ipv4-unicast redistribute connected route-map SAFE-REDISTRIBUTE
{redistribute_static}

commit
save
exit
""".format(asn=asn, loopback=loopback, branch_bgp_networks=branch_bgp_networks,
           redistribute_static=redistribute_static)

    return script


def build_ssm_command(vpn_script):
    """Wrap a vbash script in an SSM command that writes, pushes, and executes it.

    Args:
        vpn_script: The vbash script string to execute inside the VyOS container

    Returns:
        str: Shell script for SSM RunShellScript that pushes and runs the vbash
    """
    return """#!/bin/bash
set -e

# Write VPN/BGP vbash script
cat > /tmp/vyos-vpn.sh <<'VPNEOF'
{vpn_script}
VPNEOF

# Push and execute in VyOS container
lxc file push /tmp/vyos-vpn.sh router/tmp/vyos-vpn.sh
lxc exec router -- chmod +x /tmp/vyos-vpn.sh
lxc exec router -- /tmp/vyos-vpn.sh

# Force strongSwan to reload and re-initiate the peers. VyOS 'commit' does not
# always reliably trigger a full strongSwan daemon reload after IPsec changes,
# leaving the running daemon holding a stale in-memory config. Without this,
# the config DB (show configuration commands | grep ipsec) looks correct but
# `ipsec statusall` shows zero Security Associations with no initiate activity,
# and `show vpn ike sa` reports state=down. An explicit restart + brief sleep
# forces the daemon to load the latest swanctl/strongswan.conf and, because
# our peers use connection-type=initiate, start the IKE exchange immediately.
lxc exec router -- sudo ipsec restart || true
sleep 5
""".format(vpn_script=vpn_script)


def handler(event, context):
    """Lambda handler for Phase 2 VPN/BGP configuration.

    Reads instance configs from SSM Parameter Store, generates per-router
    vbash scripts for IPsec VPN and BGP, and executes them via SSM.

    Args:
        event: Lambda event (passed from Step Functions, may contain Phase1 results)
        context: Lambda context object

    Returns:
        dict: Structured result with per-instance status:
            - phase: "phase2"
            - results: dict keyed by instance name with status details
            - success_count: number of successful instances
            - fail_count: number of failed instances
    """
    configs = get_instance_configs(param_prefix=SSM_PARAM_PREFIX)

    results = {}
    success_count = 0
    fail_count = 0

    for router_name in ROUTER_CONFIG:
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

        # Generate the vbash script for this router
        vpn_script = build_vpn_bgp_script(router_name, configs)

        # Wrap in SSM command
        ssm_cmd = build_ssm_command(vpn_script)

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
        "phase": "phase2",
        "results": results,
        "success_count": success_count,
        "fail_count": fail_count,
    }
