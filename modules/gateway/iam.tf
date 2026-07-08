# IAM — per-pod roles.
#
#   - task execution role : ECS pulls the image + reads secrets
#   - task role           : what the gateway container may do (S3/SQS/DDB/Bedrock)
#   - deployment role     : control plane assumes it to roll ECS deployments
#   - observability role  : control plane assumes it to consume SQS + read metrics
#
# (The account-shared ECR push role lives in modules/account.)

# ── Task execution role ──────────────────────────────────────────────────────

resource "aws_iam_role" "gateway_task_execution" {
  name = "${local.name}-exec-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })

  tags = merge(local.tags, { Name = "${local.name}-exec-role" })
}

resource "aws_iam_role_policy_attachment" "gateway_task_execution" {
  role       = aws_iam_role.gateway_task_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "gateway_execution_secrets" {
  name = "${local.name}-exec-secrets"
  role = aws_iam_role.gateway_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [local.pod_secret_arn, aws_secretsmanager_secret.registration.arn]
    }]
  })
}

# ── Task role ────────────────────────────────────────────────────────────────

resource "aws_iam_role" "gateway_task" {
  name = "${local.name}-task-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })

  tags = merge(local.tags, { Name = "${local.name}-task-role" })
}

resource "aws_iam_role_policy" "gateway_s3" {
  name = "${local.name}-s3"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [local.pod_s3_bucket_arn, "${local.pod_s3_bucket_arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "gateway_sqs" {
  name = "${local.name}-sqs"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SendToOutbound"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.outbound.arn
      },
      {
        Sid      = "ReceiveFromInbound"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.inbound.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "gateway_dynamodb" {
  name = "${local.name}-dynamodb"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
        "dynamodb:Query", "dynamodb:Scan", "dynamodb:BatchWriteItem", "dynamodb:BatchGetItem"
      ]
      Resource = [
        aws_dynamodb_table.data.arn,
        "${aws_dynamodb_table.data.arn}/index/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "gateway_bedrock_assume" {
  name = "${local.name}-bedrock-assume"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # Resource "*" is required: the target roles live in separate tenant backend
      # accounts and are not enumerable here. The Condition scopes this to ONLY
      # roles tagged codevine=bedrock-invoke, so it cannot assume arbitrary roles.
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "*"
      Condition = {
        StringEquals = { "iam:ResourceTag/${var.project_name}" = "bedrock-invoke" }
      }
    }]
  })
}

# Bedrock invoke in the pod's own account. Unconditional: when a tenant has no
# AWS account registered with the control plane, analytics requests fall back
# to invoking Bedrock here with the task role. Requires Anthropic model access
# to be enabled in this account/region (an AWS console step; IAM alone is not
# sufficient).
resource "aws_iam_role_policy" "gateway_bedrock_invoke" {
  name = "${local.name}-bedrock-invoke"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = [
        "arn:${local.partition}:bedrock:*::foundation-model/*",
        "arn:${local.partition}:bedrock:*:${local.account_id}:inference-profile/*",
        "arn:${local.partition}:bedrock:*:${local.account_id}:application-inference-profile/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "gateway_secrets_read" {
  name = "${local.name}-secrets-read"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = local.pod_secret_arn
    }]
  })
}

# ── Deployment role (control plane assumes to roll ECS deployments) ───────────

resource "aws_iam_role" "deployment" {
  name = "${local.name}-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${var.control_plane_account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = "arn:${local.partition}:iam::${var.control_plane_account_id}:role/${var.project_name}-*-ecs-task"
        }
      }
    }]
  })

  tags = merge(local.tags, { Name = "${local.name}-deploy-role" })
}

resource "aws_iam_role_policy" "deployment" {
  name = "${local.name}-deploy-role"
  role = aws_iam_role.deployment.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped to THIS pod's own ECS cluster.
        Sid      = "ECSDeployServices"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource = "arn:${local.partition}:ecs:*:${local.account_id}:service/${local.name}-cluster/*"
      },
      {
        # Describe/RegisterTaskDefinition do not support resource-level permissions
        # in IAM (AWS limitation) — must be "*".
        Sid      = "ECSTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
        Resource = "*"
      },
      {
        Sid      = "PassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/${local.name}-*"
      }
    ]
  })
}

# ── Observability role (control plane assumes to consume SQS + read metrics) ──

resource "aws_iam_role" "observability" {
  name = "${local.name}-obs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${var.control_plane_account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = "arn:${local.partition}:iam::${var.control_plane_account_id}:role/${var.project_name}-*-ecs-task"
        }
      }
    }]
  })

  tags = merge(local.tags, { Name = "${local.name}-obs-role" })
}

resource "aws_iam_role_policy" "observability_sqs" {
  name = "${local.name}-obs-sqs"
  role = aws_iam_role.observability.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeOutbound"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = aws_sqs_queue.outbound.arn
      },
      {
        Sid      = "SendToInbound"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.inbound.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "observability_cloudwatch" {
  name = "${local.name}-obs-cw"
  role = aws_iam_role.observability.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetMetricData does not support resource-level permissions (AWS
        # limitation) — must be "*". Reads metrics only, no log content.
        Sid      = "Metrics"
        Effect   = "Allow"
        Action   = "cloudwatch:GetMetricData"
        Resource = "*"
      },
      {
        # Log reads scoped to THIS pod's own log groups (gateway + its WAF).
        Sid    = "LogReads"
        Effect = "Allow"
        Action = ["logs:StartQuery", "logs:FilterLogEvents"]
        Resource = [
          "arn:${local.partition}:logs:*:${local.account_id}:log-group:/ecs/${local.name}:*",
          "arn:${local.partition}:logs:*:${local.account_id}:log-group:aws-waf-logs-${local.name}:*",
        ]
      },
      {
        # GetQueryResults references a query by ID, not a log-group ARN, so it
        # cannot be resource-scoped (AWS limitation) — must be "*". Only returns
        # results for queries this role already started.
        Sid      = "LogQueryResults"
        Effect   = "Allow"
        Action   = "logs:GetQueryResults"
        Resource = "*"
      }
    ]
  })
}
