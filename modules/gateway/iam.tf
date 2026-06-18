# IAM Roles for the Gateway Pod

# ──────────────────────────────────────────────────────────
# Task Execution Role (ECS pulls images + reads secrets)
# ──────────────────────────────────────────────────────────

resource "aws_iam_role" "gateway_task_execution" {
  name = "${local.pod_prefix}-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gateway_task_execution" {
  role       = aws_iam_role.gateway_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "gateway_execution_secrets" {
  name = "${local.pod_prefix}-execution-secrets"
  role = aws_iam_role.gateway_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = [
          local.pod_secret_arn,
          aws_secretsmanager_secret.registration.arn,
        ]
      }
    ]
  })
}

# ──────────────────────────────────────────────────────────
# Task Role (what the gateway container can do)
# ──────────────────────────────────────────────────────────

resource "aws_iam_role" "gateway_task" {
  name = "${local.pod_prefix}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# S3 payload access
resource "aws_iam_role_policy" "gateway_s3" {
  name = "${local.pod_prefix}-s3"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          local.pod_s3_bucket_arn,
          "${local.pod_s3_bucket_arn}/*"
        ]
      }
    ]
  })
}

# SQS access
resource "aws_iam_role_policy" "gateway_sqs" {
  name = "${local.pod_prefix}-sqs"
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
        Sid    = "ReceiveFromInbound"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.inbound.arn
      }
    ]
  })
}

# DynamoDB pod data table
resource "aws_iam_role_policy" "gateway_dynamodb" {
  name = "${local.pod_prefix}-dynamodb"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchWriteItem",
          "dynamodb:BatchGetItem"
        ]
        Resource = [
          "arn:aws:dynamodb:*:${local.account_id}:table/${local.pod_dynamodb_name}",
          "arn:aws:dynamodb:*:${local.account_id}:table/${local.pod_dynamodb_name}/index/*"
        ]
      }
    ]
  })
}

# Bedrock assume role (for tenant backend accounts)
resource "aws_iam_role_policy" "gateway_bedrock_assume" {
  name = "${local.pod_prefix}-bedrock-assume"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Resource "*" is required: the target roles live in separate tenant
        # backend accounts and are not enumerable here. The Condition scopes
        # this to ONLY roles tagged codevine=bedrock-invoke, so it cannot
        # assume arbitrary roles.
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:ResourceTag/${var.project_name}" = "bedrock-invoke"
          }
        }
      }
    ]
  })
}

# Secrets Manager read
resource "aws_iam_role_policy" "gateway_secrets_read" {
  name = "${local.pod_prefix}-secrets-read"
  role = aws_iam_role.gateway_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = local.pod_secret_arn
      }
    ]
  })
}

# ──────────────────────────────────────────────────────────
# Observability Role
#
# The control plane assumes this (cross-account) to consume the outbound
# SQS queue and read CloudWatch metrics/logs. Trust is scoped to the
# control plane account's ECS task roles.
# ──────────────────────────────────────────────────────────

resource "aws_iam_role" "observability" {
  name = "${local.pod_prefix}-observability"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.control_plane_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${var.control_plane_account_id}:role/${var.project_name}-*-ecs-task"
          }
        }
      }
    ]
  })

  tags = {
    (var.project_name) = "gateway-management"
  }
}

resource "aws_iam_role_policy" "observability_sqs" {
  name = "${local.pod_prefix}-observability-sqs"
  role = aws_iam_role.observability.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeOutbound"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
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
  name = "${local.pod_prefix}-observability-cw"
  role = aws_iam_role.observability.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetMetricData does not support resource-level permissions (AWS
        # limitation) — must be "*". It only reads metrics, no log content.
        Sid      = "Metrics"
        Effect   = "Allow"
        Action   = "cloudwatch:GetMetricData"
        Resource = "*"
      },
      {
        # Log reads scoped to codevine log groups (gateway + WAF) by prefix,
        # so new codevine log groups are covered without re-granting, while
        # the customer's other log groups stay out of reach.
        Sid    = "LogReads"
        Effect = "Allow"
        Action = [
          "logs:StartQuery",
          "logs:FilterLogEvents"
        ]
        Resource = [
          "arn:aws:logs:*:${local.account_id}:log-group:/ecs/${var.project_name}/*",
          "arn:aws:logs:*:${local.account_id}:log-group:aws-waf-logs-${var.project_name}-*",
        ]
      },
      {
        # GetQueryResults references a query by ID, not by log-group ARN, so
        # it does not support resource scoping (AWS limitation) — must be "*".
        # It can only return results for queries this role already started.
        Sid      = "LogQueryResults"
        Effect   = "Allow"
        Action   = "logs:GetQueryResults"
        Resource = "*"
      }
    ]
  })
}
