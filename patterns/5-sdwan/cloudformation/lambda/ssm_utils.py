"""
Shared SSM utility module for Lambda functions.

Provides common functions for SSM parameter retrieval and command execution
used by all 3 phase Lambda handlers (phase1, phase2, phase3).
"""

import time
import boto3


# Instance-to-region mapping for the 4 SD-WAN instances
INSTANCE_REGIONS = {
    "nv-sdwan": "us-east-1",
    "nv-branch1": "us-east-1",
    "fra-sdwan": "eu-central-1",
    "fra-branch1": "eu-central-1",
}

# Default regions to scan for SSM parameters
DEFAULT_REGIONS = ["us-east-1", "eu-central-1"]

# Polling interval for SSM command completion (seconds)
POLL_INTERVAL = 15


def get_ssm_parameter_path(instance_name, param_type):
    """Return the SSM parameter path for a given instance and parameter type.

    Args:
        instance_name: One of nv-sdwan, nv-branch1, fra-sdwan, fra-branch1
        param_type: One of instance-id, outside-eip, outside-private-ip

    Returns:
        str: SSM parameter path like /sdwan/nv-sdwan/instance-id
    """
    return f"/sdwan/{instance_name}/{param_type}"


def get_region_for_instance(instance_name):
    """Return the AWS region for a given instance name.

    Args:
        instance_name: One of nv-sdwan, nv-branch1, fra-sdwan, fra-branch1

    Returns:
        str: AWS region (us-east-1 or eu-central-1)

    Raises:
        ValueError: If instance_name is not recognized
    """
    if instance_name not in INSTANCE_REGIONS:
        raise ValueError(
            f"Unknown instance name: {instance_name}. "
            f"Expected one of: {list(INSTANCE_REGIONS.keys())}"
        )
    return INSTANCE_REGIONS[instance_name]



def get_instance_configs(param_prefix="/sdwan/", regions=None):
    """Read SSM parameters by path prefix and return instance configurations.

    Creates regional boto3 SSM clients, calls GetParametersByPath in each
    region, and assembles a dict keyed by instance name.

    Args:
        param_prefix: SSM parameter path prefix (default: /sdwan/)
        regions: List of AWS regions to scan (default: us-east-1, eu-central-1)

    Returns:
        dict: Keyed by instance name, each value contains:
            - instance_id (str)
            - outside_eip (str)
            - outside_private_ip (str)
            - region (str)
    """
    if regions is None:
        regions = DEFAULT_REGIONS

    configs = {}

    for region in regions:
        client = boto3.client("ssm", region_name=region)

        # Paginate through all parameters under the prefix
        paginator = client.get_paginator("get_parameters_by_path")
        pages = paginator.paginate(
            Path=param_prefix,
            Recursive=True,
            WithDecryption=False,
        )

        for page in pages:
            for param in page.get("Parameters", []):
                name = param["Name"]
                value = param["Value"]

                # Parse path: /sdwan/{instance-name}/{param-type}
                parts = name.strip("/").split("/")
                if len(parts) != 3:
                    continue

                _, instance_name, param_type = parts

                if instance_name not in configs:
                    configs[instance_name] = {"region": region}

                # Map param-type to dict key
                key_map = {
                    "instance-id": "instance_id",
                    "outside-eip": "outside_eip",
                    "outside-private-ip": "outside_private_ip",
                    "cloudwan-peer-ip1": "cloudwan_peer_ip1",
                    "cloudwan-peer-ip2": "cloudwan_peer_ip2",
                    "cloudwan-asn": "cloudwan_asn",
                }
                if param_type in key_map:
                    configs[instance_name][key_map[param_type]] = value

    return configs


def send_and_wait(instance_id, region, commands, timeout=600):
    """Send an SSM RunShellScript command and poll until completion.

    Args:
        instance_id: EC2 instance ID to target
        region: AWS region of the instance
        commands: Shell command string or list of command strings
        timeout: Max seconds to wait for completion (default: 600)

    Returns:
        dict: Result with keys:
            - status: "Success", "Failed", or "TimedOut"
            - command_id: SSM command ID
            - instance_id: Target instance ID
            - stdout: Standard output content
            - stderr: Standard error content
    """
    client = boto3.client("ssm", region_name=region)

    # Normalize commands to a list
    if isinstance(commands, str):
        commands = [commands]

    # Send the command
    response = client.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": commands},
        TimeoutSeconds=timeout,
    )

    command_id = response["Command"]["CommandId"]

    result = {
        "status": "TimedOut",
        "command_id": command_id,
        "instance_id": instance_id,
        "stdout": "",
        "stderr": "",
    }

    # Poll for completion
    elapsed = 0
    while elapsed < timeout:
        time.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL

        try:
            invocation = client.get_command_invocation(
                CommandId=command_id,
                InstanceId=instance_id,
            )
        except client.exceptions.InvocationDoesNotExist:
            continue

        status = invocation.get("Status", "Pending")

        if status == "Success":
            result["status"] = "Success"
            result["stdout"] = invocation.get("StandardOutputContent", "")
            result["stderr"] = invocation.get("StandardErrorContent", "")
            return result

        if status in ("Failed", "Cancelled", "TimedOut"):
            result["status"] = "Failed"
            result["stdout"] = invocation.get("StandardOutputContent", "")
            result["stderr"] = invocation.get("StandardErrorContent", "")
            return result

        # InProgress, Pending, Delayed — keep polling

    # Timed out waiting
    result["status"] = "TimedOut"
    return result
