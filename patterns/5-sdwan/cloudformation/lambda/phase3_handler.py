"""
Phase 3 Lambda Handler — Verification via SSM Run Command.

Verifies IPsec tunnel status, BGP sessions, interfaces, and VTI connectivity
on all 4 SD-WAN Ubuntu instances via SSM.

Replicates the logic from phase3-verify.sh as an AWS Lambda function.
"""

import os
from ssm_utils import get_instance_configs, send_and_wait


# Configurable via environment variables
SSM_PARAM_PREFIX = os.environ.get("SSM_PARAM_PREFIX", "/sdwan/")
SSM_TIMEOUT = int(os.environ.get("SSM_TIMEOUT", "300"))


# VPN tunnel topology — used to derive ping targets per router
TUNNELS = [
    {
        "router_a": "nv-sdwan",
        "router_b": "nv-branch1",
        "vti_a_addr": "169.254.100.1",
        "vti_b_addr": "169.254.100.2",
    },
    {
        "router_a": "fra-sdwan",
        "router_b": "fra-branch1",
        "vti_a_addr": "169.254.100.13",
        "vti_b_addr": "169.254.100.14",
    },
]


def get_ping_targets(router_name):
    """Return the VTI peer addresses a router should ping for verification.

    For each tunnel the router participates in, returns the remote VTI address.

    Args:
        router_name: One of nv-sdwan, nv-branch1, fra-sdwan, fra-branch1

    Returns:
        list[str]: VTI peer IP addresses to ping
    """
    targets = []
    for tunnel in TUNNELS:
        if router_name == tunnel["router_a"]:
            targets.append(tunnel["vti_b_addr"])
        elif router_name == tunnel["router_b"]:
            targets.append(tunnel["vti_a_addr"])
    return targets


# All routers to verify
ROUTERS = ["nv-sdwan", "nv-branch1", "fra-sdwan", "fra-branch1"]

# VyOS op-mode command wrapper path
VYOS_OP_WRAPPER = "/opt/vyatta/bin/vyatta-op-cmd-wrapper"


def build_verify_command(router_name):
    """Build an SSM command that runs VyOS show commands and ping tests.

    Executes inside the LXC router container via lxc exec:
    - show vpn ipsec sa
    - show ip bgp summary
    - show interfaces
    - ping tests to VTI peer addresses

    Args:
        router_name: One of nv-sdwan, nv-branch1, fra-sdwan, fra-branch1

    Returns:
        str: Shell script for SSM RunShellScript
    """
    ping_targets = get_ping_targets(router_name)

    ping_cmds = ""
    for target in ping_targets:
        ping_cmds += f"""
echo "--- Ping {target} ---"
lxc exec router -- ping -c 3 -W 2 {target} && echo "PING_OK {target}" || echo "PING_FAIL {target}"
"""

    return f"""#!/bin/bash
echo "=== Verifying {router_name} ==="

echo "--- IPsec SA Status ---"
lxc exec router -- {VYOS_OP_WRAPPER} show vpn ipsec sa || echo "IPSEC_CHECK_FAILED"

echo "--- BGP Summary ---"
lxc exec router -- {VYOS_OP_WRAPPER} show ip bgp summary || echo "BGP_CHECK_FAILED"

echo "--- Interfaces ---"
lxc exec router -- {VYOS_OP_WRAPPER} show interfaces || echo "INTERFACES_CHECK_FAILED"

echo "--- Ping Tests ---"
{ping_cmds}
echo "=== Verification complete for {router_name} ==="
"""


def parse_verify_output(stdout, router_name):
    """Parse the verification command output into structured results.

    Args:
        stdout: Raw stdout from the SSM command
        router_name: Router name for ping target lookup

    Returns:
        dict: Verification details with ipsec, bgp, interfaces, and ping results
    """
    ping_targets = get_ping_targets(router_name)

    ping_results = {}
    for target in ping_targets:
        if f"PING_OK {target}" in stdout:
            ping_results[target] = "ok"
        elif f"PING_FAIL {target}" in stdout:
            ping_results[target] = "fail"
        else:
            ping_results[target] = "unknown"

    return {
        "ipsec": "fail" if "IPSEC_CHECK_FAILED" in stdout else "ok",
        "bgp": "fail" if "BGP_CHECK_FAILED" in stdout else "ok",
        "interfaces": "fail" if "INTERFACES_CHECK_FAILED" in stdout else "ok",
        "ping": ping_results,
    }


def handler(event, context):
    """Lambda handler for Phase 3 verification.

    Reads instance configs from SSM Parameter Store, runs VyOS show commands
    and ping tests on each router via SSM, and returns structured results.

    Args:
        event: Lambda event (passed from Step Functions, may contain prior phase results)
        context: Lambda context object

    Returns:
        dict: Structured result with per-instance verification status:
            - phase: "phase3"
            - results: dict keyed by instance name with status and verification details
            - success_count: number of successful instances
            - fail_count: number of failed instances
    """
    configs = get_instance_configs(param_prefix=SSM_PARAM_PREFIX)

    results = {}
    success_count = 0
    fail_count = 0

    for router_name in ROUTERS:
        if router_name not in configs:
            results[router_name] = {
                "status": "Failed",
                "command_id": "",
                "instance_id": "",
                "stdout": "",
                "stderr": f"Instance config not found for {router_name}",
                "details": {},
            }
            fail_count += 1
            continue

        instance_id = configs[router_name]["instance_id"]
        region = configs[router_name]["region"]

        verify_cmd = build_verify_command(router_name)

        result = send_and_wait(
            instance_id=instance_id,
            region=region,
            commands=verify_cmd,
            timeout=SSM_TIMEOUT,
        )

        # Parse verification output into structured details
        details = parse_verify_output(result.get("stdout", ""), router_name)
        result["details"] = details

        results[router_name] = result

        if result["status"] == "Success":
            success_count += 1
        else:
            fail_count += 1

    return {
        "phase": "phase3",
        "results": results,
        "success_count": success_count,
        "fail_count": fail_count,
    }
