# =============================================================================
# SD-WAN Orchestration - Lambda Functions and Step Functions
# Deploys Phase1-4 Lambda functions and the Step Functions state machine
# Orchestrates: Phase1 → Wait → Phase2 → Wait → Phase3 → Wait → Phase4
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {
  provider = aws.virginia
}

data "archive_file" "lambda_package" {
  type        = "zip"
  source_dir  = "${path.module}/${var.lambda_source_dir}"
  output_path = "${path.module}/.build/lambda.zip"

  excludes = [
    "__pycache__",
    "*.pyc",
  ]
}

# -----------------------------------------------------------------------------
# IAM Role for Lambda Execution
# -----------------------------------------------------------------------------

resource "aws_iam_role" "sdwan_lambda_execution_role" {
  provider = aws.virginia
  name     = "sdwan-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "sdwan-lambda-execution-role"
  }
}

resource "aws_iam_role_policy" "sdwan_lambda_policy" {
  provider = aws.virginia
  name     = "sdwan-lambda-policy"
  role     = aws_iam_role.sdwan_lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMSendCommand"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ssm:*:*:document/AWS-RunShellScript",
          aws_instance.nv_sdwan_sdwan_instance.arn,
          aws_instance.nv_branch1_sdwan_instance.arn,
          aws_instance.fra_sdwan_sdwan_instance.arn,
          aws_instance.fra_branch1_sdwan_instance.arn,
        ]
      },
      {
        Sid    = "SSMCommandInvocation"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceInformation",
        ]
        Resource = "*"
      },
      {
        Sid      = "SSMGetParameter"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/sdwan/*"
      },
      {
        Sid    = "SSMGetParametersByPath"
        Effect = "Allow"
        Action = "ssm:GetParametersByPath"
        Resource = [
          "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/sdwan",
          "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/sdwan/",
        ]
      },
      {
        Sid      = "SSMPutParameter"
        Effect   = "Allow"
        Action   = "ssm:PutParameter"
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/sdwan/*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Lambda Functions
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "sdwan_phase1" {
  provider         = aws.virginia
  function_name    = "sdwan-phase1"
  description      = "SD-WAN Phase 1 - Base setup: packages, LXD, VyOS container"
  role             = aws_iam_role.sdwan_lambda_execution_role.arn
  handler          = "phase1_handler.handler"
  runtime          = "python3.12"
  timeout          = 900
  memory_size      = 256
  filename         = data.archive_file.lambda_package.output_path
  source_code_hash = data.archive_file.lambda_package.output_base64sha256

  environment {
    variables = {
      SSM_PARAM_PREFIX = "/sdwan/"
    }
  }

  tags = {
    Name  = "sdwan-phase1"
    Phase = "1-base-setup"
  }
}

resource "aws_lambda_function" "sdwan_phase2" {
  provider         = aws.virginia
  function_name    = "sdwan-phase2"
  description      = "SD-WAN Phase 2 - VPN/BGP configuration"
  role             = aws_iam_role.sdwan_lambda_execution_role.arn
  handler          = "phase2_handler.handler"
  runtime          = "python3.12"
  timeout          = 600
  memory_size      = 256
  filename         = data.archive_file.lambda_package.output_path
  source_code_hash = data.archive_file.lambda_package.output_base64sha256

  environment {
    variables = {
      SSM_PARAM_PREFIX = "/sdwan/"
    }
  }

  tags = {
    Name  = "sdwan-phase2"
    Phase = "2-vpn-bgp-config"
  }
}

resource "aws_lambda_function" "sdwan_phase3" {
  provider         = aws.virginia
  function_name    = "sdwan-phase3"
  description      = "SD-WAN Phase 3 - Cloud WAN BGP configuration"
  role             = aws_iam_role.sdwan_lambda_execution_role.arn
  handler          = "phase3_handler.handler"
  runtime          = "python3.12"
  timeout          = 600
  memory_size      = 256
  filename         = data.archive_file.lambda_package.output_path
  source_code_hash = data.archive_file.lambda_package.output_base64sha256

  environment {
    variables = {
      SSM_PARAM_PREFIX = "/sdwan/"
    }
  }

  tags = {
    Name  = "sdwan-phase3"
    Phase = "3-cloudwan-bgp"
  }
}

resource "aws_lambda_function" "sdwan_phase4" {
  provider         = aws.virginia
  function_name    = "sdwan-phase4"
  description      = "SD-WAN Phase 4 - Verification: IPsec, BGP, Cloud WAN BGP, connectivity"
  role             = aws_iam_role.sdwan_lambda_execution_role.arn
  handler          = "phase4_handler.handler"
  runtime          = "python3.12"
  timeout          = 600
  memory_size      = 256
  filename         = data.archive_file.lambda_package.output_path
  source_code_hash = data.archive_file.lambda_package.output_base64sha256

  environment {
    variables = {
      SSM_PARAM_PREFIX = "/sdwan/"
    }
  }

  tags = {
    Name  = "sdwan-phase4"
    Phase = "4-verify"
  }
}

# -----------------------------------------------------------------------------
# IAM Role for Step Functions Execution
# -----------------------------------------------------------------------------

resource "aws_iam_role" "sdwan_stepfunctions_role" {
  provider = aws.virginia
  name     = "sdwan-stepfunctions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "sdwan-stepfunctions-role"
  }
}

resource "aws_iam_role_policy" "sdwan_stepfunctions_policy" {
  provider = aws.virginia
  name     = "sdwan-stepfunctions-policy"
  role     = aws_iam_role.sdwan_stepfunctions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeLambda"
        Effect = "Allow"
        Action = "lambda:InvokeFunction"
        Resource = [
          aws_lambda_function.sdwan_phase1.arn,
          aws_lambda_function.sdwan_phase2.arn,
          aws_lambda_function.sdwan_phase3.arn,
          aws_lambda_function.sdwan_phase4.arn,
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group for Step Functions
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "sdwan_stepfunctions" {
  provider          = aws.virginia
  name              = "/aws/vendedlogs/states/sdwan-orchestration"
  retention_in_days = 30

  tags = {
    Name = "sdwan-stepfunctions-logs"
  }
}

# -----------------------------------------------------------------------------
# Step Functions State Machine
# -----------------------------------------------------------------------------

resource "aws_sfn_state_machine" "sdwan_orchestration" {
  provider = aws.virginia
  name     = "sdwan-orchestration"
  role_arn = aws_iam_role.sdwan_stepfunctions_role.arn

  definition = jsonencode({
    Comment = "SD-WAN Configuration Orchestration"
    StartAt = "Phase1_BaseSetup"
    States = {
      Phase1_BaseSetup = {
        Type     = "Task"
        Resource = aws_lambda_function.sdwan_phase1.arn
        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"]
            IntervalSeconds = 30
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "FailureState"
            ResultPath  = "$.error"
          }
        ]
        ResultPath = "$.phase1_result"
        Next       = "Wait_After_Phase1"
      }

      Wait_After_Phase1 = {
        Type    = "Wait"
        Seconds = var.phase1_wait_seconds
        Next    = "Phase2_VpnBgpConfig"
      }

      Phase2_VpnBgpConfig = {
        Type     = "Task"
        Resource = aws_lambda_function.sdwan_phase2.arn
        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"]
            IntervalSeconds = 30
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "FailureState"
            ResultPath  = "$.error"
          }
        ]
        ResultPath = "$.phase2_result"
        Next       = "Wait_After_Phase2"
      }

      Wait_After_Phase2 = {
        Type    = "Wait"
        Seconds = var.phase2_wait_seconds
        Next    = "Phase3_CloudWanBgp"
      }

      Phase3_CloudWanBgp = {
        Type     = "Task"
        Resource = aws_lambda_function.sdwan_phase3.arn
        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"]
            IntervalSeconds = 30
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "FailureState"
            ResultPath  = "$.error"
          }
        ]
        ResultPath = "$.phase3_result"
        Next       = "Wait_After_Phase3"
      }

      Wait_After_Phase3 = {
        Type    = "Wait"
        Seconds = 30
        Next    = "Phase4_Verify"
      }

      Phase4_Verify = {
        Type     = "Task"
        Resource = aws_lambda_function.sdwan_phase4.arn
        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"]
            IntervalSeconds = 30
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "FailureState"
            ResultPath  = "$.error"
          }
        ]
        ResultPath = "$.phase4_result"
        Next       = "SuccessState"
      }

      SuccessState = {
        Type = "Succeed"
      }

      FailureState = {
        Type  = "Fail"
        Cause = "Phase execution failed"
        Error = "PhaseExecutionError"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sdwan_stepfunctions.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tags = {
    Name = "sdwan-orchestration"
  }
}
