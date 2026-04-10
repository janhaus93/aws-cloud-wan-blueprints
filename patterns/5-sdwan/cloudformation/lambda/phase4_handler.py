"""
Phase 4 Lambda Handler — Verification via SSM Run Command.

Verifies IPsec tunnel status, BGP sessions, interfaces, and VTI connectivity
on all 4 SD-WAN Ubuntu instances via SSM.

Replicates the logic from phase3-verify.sh as an AWS Lambda function.
"""

import json
import os

import boto3

from ssm_utils import get_instance_configs, send_and_wait


# Configurable via environment variables
SSM_PARAM_PREFIX = os.environ.get("SSM_PARAM_PREFIX", "/sdwan/")
SSM_TIMEOUT = int(os.environ.get("SSM_TIMEOUT", "300"))

# SDWAN routers that peer with Cloud WAN (need Cloud WAN BGP verification)
SDWAN_ROUTERS = ["nv-sdwan", "fra-sdwan"]


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


def build_verify_command(router_name, configs=None):
    """Build an SSM command that runs VyOS show commands and ping tests.

    Executes inside the LXC router container via lxc exec:
    - show vpn ipsec sa
    - show ip bgp summary
    - show interfaces
    - show ip bgp neighbors (Cloud WAN peers, SDWAN routers only)
    - ping tests to VTI peer addresses

    Args:
        router_name: One of nv-sdwan, nv-branch1, fra-sdwan, fra-branch1
        configs: Optional dict from get_instance_configs() for Cloud WAN peer IPs

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

    cloudwan_bgp_cmd = ""
    if router_name in SDWAN_ROUTERS and configs and router_name in configs:
        peer_ip1 = configs[router_name].get("cloudwan_peer_ip1", "")
        peer_ip2 = configs[router_name].get("cloudwan_peer_ip2", "")
        peer_filter_parts = []
        if peer_ip1:
            peer_filter_parts.append(peer_ip1)
        if peer_ip2:
            peer_filter_parts.append(peer_ip2)
        if peer_filter_parts:
            for peer_ip in peer_filter_parts:
                cloudwan_bgp_cmd += f"""
echo "--- Cloud WAN BGP Neighbor {peer_ip} ---"
lxc exec router -- {VYOS_OP_WRAPPER} show ip bgp neighbors {peer_ip} || echo "CLOUDWAN_BGP_CHECK_FAILED"
"""

    return f"""#!/bin/bash
echo "=== Verifying {router_name} ==="

echo "--- IPsec SA Status ---"
lxc exec router -- {VYOS_OP_WRAPPER} show vpn ipsec sa || echo "IPSEC_CHECK_FAILED"

echo "--- BGP Summary ---"
lxc exec router -- {VYOS_OP_WRAPPER} show ip bgp summary || echo "BGP_CHECK_FAILED"

echo "--- Interfaces ---"
lxc exec router -- {VYOS_OP_WRAPPER} show interfaces || echo "INTERFACES_CHECK_FAILED"
{cloudwan_bgp_cmd}
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
        dict: Verification details with ipsec, bgp, interfaces, cloudwan_bgp,
              and ping results
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

    # Cloud WAN BGP status: only applicable to SDWAN routers
    if router_name in SDWAN_ROUTERS:
        cloudwan_bgp = "fail" if "CLOUDWAN_BGP_CHECK_FAILED" in stdout else "ok"
    else:
        cloudwan_bgp = "not_applicable"

    return {
        "ipsec": "fail" if "IPSEC_CHECK_FAILED" in stdout else "ok",
        "bgp": "fail" if "BGP_CHECK_FAILED" in stdout else "ok",
        "interfaces": "fail" if "INTERFACES_CHECK_FAILED" in stdout else "ok",
        "cloudwan_bgp": cloudwan_bgp,
        "ping": ping_results,
    }


def persist_results_to_ssm(result):
    """Write a human-readable verification report to SSM Parameter Store.

    Formats the verification results as a text summary and persists it to
    /sdwan/verification-results for easy retrieval via AWS CLI or console.

    On failure, logs the error and returns without raising — the phase
    should not fail due to a persistence issue.

    Args:
        result: The full verification result dict (phase, results,
                success_count, fail_count)
    """
    try:
        report = _format_report(result)
        client = boto3.client("ssm")
        client.put_parameter(
            Name="/sdwan/verification-results",
            Value=report,
            Type="String",
            Overwrite=True,
        )
    except Exception as e:
        print(f"Failed to persist verification results to SSM: {e}")


def _format_report(result):
    """Format verification results as a human-readable text report.

    Args:
        result: The full verification result dict

    Returns:
        str: Formatted text report
    """
    def icon(val):
        if val == "ok":
            return "pass"
        elif val == "not_applicable":
            return "n/a"
        return "FAIL"

    lines = [
        "SD-WAN Verification Report",
        "=" * 50,
        "",
    ]

    for router_name, router_result in result.get("results", {}).items():
        details = router_result.get("details", {})
        status = router_result.get("status", "Unknown")

        if status != "Success":
            lines.append(f"  {router_name:<14} FAIL - SSM command failed")
            continue

        ping_parts = []
        for ip, val in details.get("ping", {}).items():
            ping_parts.append(f"Ping({ip})={icon(val)}")

        checks = (
            f"IPsec={icon(details.get('ipsec', 'fail'))}  "
            f"BGP={icon(details.get('bgp', 'fail'))}  "
            f"CloudWAN-BGP={icon(details.get('cloudwan_bgp', 'fail'))}  "
            + "  ".join(ping_parts)
        )

        lines.append(f"  {router_name:<14} {checks}")

    lines.append("")
    total = result.get("success_count", 0) + result.get("fail_count", 0)
    lines.append(
        f"Result: {result.get('success_count', 0)}/{total} routers passed"
    )

    return "\n".join(lines)


def handler(event, context):
    """Lambda handler for Phase 4 verification.

    Reads instance configs from SSM Parameter Store, runs VyOS show commands
    and ping tests on each router via SSM, and returns structured results.

    Args:
        event: Lambda event (passed from Step Functions, may contain prior phase results)
        context: Lambda context object

    Returns:
        dict: Structured result with per-instance verification status:
            - phase: "phase4"
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

        verify_cmd = build_verify_command(router_name, configs=configs)

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

    final_result = {
        "phase": "phase4",
        "results": results,
        "success_count": success_count,
        "fail_count": fail_count,
    }

    persist_results_to_ssm(final_result)

    return final_result
