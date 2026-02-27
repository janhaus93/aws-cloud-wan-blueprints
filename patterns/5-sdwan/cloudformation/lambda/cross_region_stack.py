"""
CloudFormation Custom Resource Lambda that deploys/updates/deletes a stack
in a remote region and returns its outputs.

Uses TemplateBody instead of TemplateURL to avoid cross-region S3 access
issues with CloudFormation service principal.
"""
import json
import boto3
import urllib.request
import re


def send_response(event, context, status, data=None, reason=None):
    body = json.dumps({
        "Status": status,
        "Reason": reason or f"See CloudWatch Log Stream: {context.log_stream_name}",
        "PhysicalResourceId": data.get("StackId", context.log_stream_name) if data else context.log_stream_name,
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "Data": data or {},
    }).encode("utf-8")
    req = urllib.request.Request(event["ResponseURL"], data=body, method="PUT")
    req.add_header("Content-Type", "")
    req.add_header("Content-Length", str(len(body)))
    urllib.request.urlopen(req)


def _parse_s3_url(url):
    """Parse S3 URL into bucket and key. Supports virtual-hosted and path style."""
    m = re.match(r"https://(.+?)\.s3[.\-].*?amazonaws\.com/(.+)", url)
    if m:
        return m.group(1), m.group(2)
    m = re.match(r"https://s3[.\-].*?amazonaws\.com/([^/]+)/(.+)", url)
    if m:
        return m.group(1), m.group(2)
    raise ValueError(f"Cannot parse S3 URL: {url}")


def _fetch_template_body(template_url):
    """Download template from S3 and return as string."""
    bucket, key = _parse_s3_url(template_url)
    s3 = boto3.client("s3")
    resp = s3.get_object(Bucket=bucket, Key=key)
    return resp["Body"].read().decode("utf-8")


def _get_failure_reason(cfn, stack_name):
    """Get the first CREATE_FAILED resource reason from stack events."""
    try:
        paginator = cfn.get_paginator("describe_stack_events")
        for page in paginator.paginate(StackName=stack_name):
            for event in page["StackEvents"]:
                if event["ResourceStatus"] == "CREATE_FAILED" and \
                   event.get("ResourceStatusReason") and \
                   "Resource creation cancelled" not in event["ResourceStatusReason"]:
                    return f"{event['LogicalResourceId']}: {event['ResourceStatusReason']}"
    except Exception:
        pass
    return "Unknown failure - check CloudWatch logs"


def handler(event, context):
    try:
        props = event["ResourceProperties"]
        region = props["Region"]
        template_url = props["TemplateURL"]
        stack_name = props["StackName"]
        params = props.get("Parameters", {})
        tags = props.get("Tags", [])
        request_type = event["RequestType"]

        cfn = boto3.client("cloudformation", region_name=region)
        cfn_params = [{"ParameterKey": k, "ParameterValue": str(v)} for k, v in params.items()]

        if request_type in ("Create", "Update"):
            template_body = _fetch_template_body(template_url)

            method = cfn.create_stack if request_type == "Create" else cfn.update_stack
            kwargs = dict(
                StackName=stack_name,
                TemplateBody=template_body,
                Parameters=cfn_params,
                Tags=tags,
                Capabilities=["CAPABILITY_NAMED_IAM"],
            )
            # On Create, disable rollback so we can inspect failures
            if request_type == "Create":
                kwargs["DisableRollback"] = True

            try:
                method(**kwargs)
            except cfn.exceptions.ClientError as e:
                if "No updates are to be performed" in str(e):
                    outputs = _get_outputs(cfn, stack_name)
                    send_response(event, context, "SUCCESS", outputs)
                    return
                raise

            waiter_name = "stack_create_complete" if request_type == "Create" else "stack_update_complete"
            waiter = cfn.get_waiter(waiter_name)
            try:
                waiter.wait(StackName=stack_name, WaiterConfig={"Delay": 30, "MaxAttempts": 120})
            except Exception as wait_err:
                # Get the actual failure reason from stack events
                reason = _get_failure_reason(cfn, stack_name)
                # Clean up the failed stack
                try:
                    cfn.delete_stack(StackName=stack_name)
                except Exception:
                    pass
                send_response(event, context, "FAILED", reason=reason[:256])
                return

            outputs = _get_outputs(cfn, stack_name)
            send_response(event, context, "SUCCESS", outputs)

        elif request_type == "Delete":
            try:
                cfn.delete_stack(StackName=stack_name)
                waiter = cfn.get_waiter("stack_delete_complete")
                waiter.wait(StackName=stack_name, WaiterConfig={"Delay": 30, "MaxAttempts": 120})
            except cfn.exceptions.ClientError as e:
                if "does not exist" not in str(e):
                    raise
            send_response(event, context, "SUCCESS")

    except Exception as e:
        print(f"Error: {e}")
        send_response(event, context, "FAILED", reason=str(e)[:256])


def _get_outputs(cfn, stack_name):
    resp = cfn.describe_stacks(StackName=stack_name)
    stack = resp["Stacks"][0]
    data = {"StackId": stack["StackId"]}
    for out in stack.get("Outputs", []):
        data[out["OutputKey"]] = out["OutputValue"]
    return data
