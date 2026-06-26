# Gateway Workload — ECS service, task, SQS, DynamoDB, S3 payload bucket,
# autoscaling, and the ALB target group / listener rule.
#
# Single-region dedicated pod: always "primary", so the account-level
# resources (S3 bucket, credentials secret, DynamoDB table) are created
# unconditionally here rather than gated on an is_primary flag.

locals {
  pod_s3_bucket_name = aws_s3_bucket.payload.id
  pod_s3_bucket_arn  = aws_s3_bucket.payload.arn
  pod_secret_arn     = aws_secretsmanager_secret.pod.arn
  pod_dynamodb_name  = aws_dynamodb_table.data.name
  pod_service_name   = "${local.pod_prefix}-service"

  # CloudWatch only accepts a fixed set of retention values. For hard control,
  # logs must NOT outlive the data-retention window, so we pick the largest
  # allowed value <= source_data_retention_days. When retention is disabled (0)
  # or the window is shorter than the smallest CW value (1 day), fall back to
  # the default 90-day operational retention.
  cw_retention_allowed = [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653]
  cw_retention_candidates = [
    for d in local.cw_retention_allowed : d
    if d <= var.source_data_retention_days
  ]
  log_retention_days = (
    var.source_data_retention_days > 0 && length(local.cw_retention_candidates) > 0
    ? local.cw_retention_candidates[length(local.cw_retention_candidates) - 1]
    : 90
  )
}

# ──────────────────────────────────────────────────────────
# Pod identity + HMAC secret
#
# Generated ONCE here and written to the pod credentials secret below, which
# the gateway reads at runtime (via the task def's `valueFrom`). The secret
# version is `ignore_changes = [secret_string]`, so identity is frozen on first
# create and NEVER regenerated on subsequent applies — even though these random
# resources always exist. This matters: the control plane treats a pod's HMAC
# as immutable (re-registration with a different HMAC is rejected), so identity
# must be stable for the life of the pod.
#
# There is no override variable: every deployment — fresh or migrated — owns its
# identity in its own Secrets Manager, generated here on first apply. To migrate
# an existing pod into this model, pre-create the credentials secret with the
# existing GATEWAY_POD_ID/GATEWAY_HMAC_SECRET before first apply; ignore_changes
# then preserves it and these random values become inert seed material.
# ──────────────────────────────────────────────────────────

resource "random_id" "pod_id" {
  byte_length = 8
}

resource "random_password" "hmac_secret" {
  length           = 32
  special          = true
  override_special = "!$*()_+-[]{}:;.,~"
}

locals {
  pod_id_value      = random_id.pod_id.hex
  hmac_secret_value = random_password.hmac_secret.result
}

# ──────────────────────────────────────────────────────────
# S3 Payload Bucket
# ──────────────────────────────────────────────────────────

resource "aws_s3_bucket" "payload" {
  bucket = "${var.project_name}-${var.environment}-gateway-${local.pod_slug}-${local.account_id}"

  tags = { Name = "${local.pod_prefix}-payload" }
}

resource "aws_s3_bucket_versioning" "payload" {
  bucket = aws_s3_bucket.payload.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "payload" {
  bucket = aws_s3_bucket.payload.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }

  # Hard data-retention expunge. Only present when source_data_retention_days > 0
  # (0 = retain forever; existing customers see no change). Expires the CURRENT
  # object AND noncurrent versions at the same age — the bucket is versioned
  # (above), so without the noncurrent rule old versions would survive the
  # retention window and break the "hard control" promise. Pairs with the
  # DynamoDB TTL the gateway stamps from the same SOURCE_DATA_RETENTION_DAYS value.
  dynamic "rule" {
    for_each = var.source_data_retention_days > 0 ? [1] : []
    content {
      id     = "source-data-retention"
      status = "Enabled"

      filter {}

      expiration {
        days = var.source_data_retention_days
      }

      noncurrent_version_expiration {
        noncurrent_days = var.source_data_retention_days
      }
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "payload" {
  bucket = aws_s3_bucket.payload.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "payload" {
  bucket = aws_s3_bucket.payload.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ──────────────────────────────────────────────────────────
# Pod Credentials Secret
# ──────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "pod" {
  name        = "${var.project_name}/${var.environment}/gateway/${local.pod_slug}/credentials"
  description = "Gateway pod credentials for ${local.pod_slug}"
}

resource "aws_secretsmanager_secret_version" "pod" {
  secret_id = aws_secretsmanager_secret.pod.id

  secret_string = jsonencode({
    GATEWAY_POD_ID      = local.pod_id_value
    GATEWAY_HMAC_SECRET = local.hmac_secret_value
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ──────────────────────────────────────────────────────────
# DynamoDB Data Table (shared by all tenants on this pod)
# ──────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "data" {
  name                        = "${local.pod_prefix}-data"
  billing_mode                = "PAY_PER_REQUEST"
  deletion_protection_enabled = true
  hash_key                    = "PK"
  range_key                   = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "GSI2_PK"
    type = "S"
  }

  attribute {
    name = "GSI2_SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI2"
    hash_key        = "GSI2_PK"
    range_key       = "GSI2_SK"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ExpiresAt"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = "${local.pod_prefix}-data" }
}

# ──────────────────────────────────────────────────────────
# SQS Queues
# ──────────────────────────────────────────────────────────

resource "aws_sqs_queue" "outbound_dlq" {
  name                      = "${local.pod_prefix}-outbound-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = { Name = "${local.pod_prefix}-outbound-dlq" }
}

resource "aws_sqs_queue" "outbound" {
  name                       = "${local.pod_prefix}-outbound"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.outbound_dlq.arn
    maxReceiveCount     = 5
  })

  tags = { Name = "${local.pod_prefix}-outbound" }
}

resource "aws_sqs_queue" "inbound_dlq" {
  name                      = "${local.pod_prefix}-inbound-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = { Name = "${local.pod_prefix}-inbound-dlq" }
}

resource "aws_sqs_queue" "inbound" {
  name                       = "${local.pod_prefix}-inbound"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.inbound_dlq.arn
    maxReceiveCount     = 5
  })

  tags = { Name = "${local.pod_prefix}-inbound" }
}

# ──────────────────────────────────────────────────────────
# CloudWatch Log Group
# ──────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/ecs/${var.project_name}/${var.environment}/gateway/${local.pod_slug}"
  retention_in_days = local.log_retention_days

  tags = { Name = "${local.pod_prefix}-logs" }
}

# ──────────────────────────────────────────────────────────
# Security Group for Gateway Tasks
# ──────────────────────────────────────────────────────────

resource "aws_security_group" "gateway" {
  name        = "${local.pod_prefix}-tasks-sg"
  description = "Security group for gateway pod tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow traffic from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.pod_prefix}-tasks-sg" }
}

# ──────────────────────────────────────────────────────────
# ALB Target Group + Listener Rule
# ──────────────────────────────────────────────────────────

resource "aws_lb_target_group" "gateway" {
  name        = substr("${local.pod_prefix}-tg", 0, 32)
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = { Name = "${local.pod_prefix}-tg" }
}

# Attach the gateway cert as an additional SNI cert on the HTTPS listener.
# Uses the validated cert ARN so it waits on the validation gate (see main.tf).
resource "aws_lb_listener_certificate" "gateway" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate_validation.gateway.certificate_arn
}

# Route the gateway FQDN to the gateway target group
resource "aws_lb_listener_rule" "gateway" {
  listener_arn = aws_lb_listener.https.arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }

  condition {
    host_header {
      values = [local.gateway_fqdn]
    }
  }
}

# ──────────────────────────────────────────────────────────
# ECS Task Definition
# ──────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "gateway" {
  family                   = local.pod_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.gateway_cpu
  memory                   = var.gateway_memory
  execution_role_arn       = aws_iam_role.gateway_task_execution.arn
  task_role_arn            = aws_iam_role.gateway_task.arn

  container_definitions = jsonencode([
    {
      name = "gateway"
      # Pull from the REPLICATED repo (codevine/{env}/gateway) that CodeVine's ECR
      # replication delivers into this account — NOT the legacy codevine/gateway.
      # AWS copies blobs+manifest server-side; the :env tag is moved here per-pod
      # by CodeVine's Promote action.
      image     = "${aws_ecr_repository.gateway_replicated.repository_url}:${var.gateway_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 8080
          protocol      = "tcp"
        }
      ]

      environment = concat([
        { name = "GATEWAY_PORT", value = "8080" },
        { name = "LOG_DIR", value = "/var/log/gateway" },
        # Deployment environment, read by the gateway's internal/env package
        # (APP_ENV is the cross-language source of truth shared with the backend).
        # A customer-deployed gateway is always a real deployment → "production".
        # No NODE_ENV: this is a Go service, NODE_ENV would be meaningless here.
        { name = "APP_ENV", value = "production" },
        { name = "INFRA_VERSION", value = var.infra_version },
        { name = "INFRA_GIT_HASH", value = local.infra_git_hash },
        { name = "S3_PAYLOAD_BUCKET", value = local.pod_s3_bucket_name },
        { name = "SQS_OUTBOUND_QUEUE_URL", value = aws_sqs_queue.outbound.url },
        { name = "SQS_INBOUND_QUEUE_URL", value = aws_sqs_queue.inbound.url },
        { name = "AWS_REGION", value = local.aws_region },
        { name = "AWS_ACCOUNT_ID", value = local.account_id },
        { name = "DYNAMODB_TABLE_NAME", value = local.pod_dynamodb_name },
        # Hard data-retention. 0 = retain forever; >0 makes the gateway stamp the
        # DynamoDB ExpiresAt TTL (reaped by the table's ttl{} block below) and
        # slide the session record forward on each request. Mirrors the S3
        # lifecycle expiration so both halves of a record expire together.
        { name = "SOURCE_DATA_RETENTION_DAYS", value = tostring(var.source_data_retention_days) },
        { name = "OBSERVABILITY_ROLE_ARN", value = aws_iam_role.observability.arn },
        { name = "ECS_CLUSTER_NAME", value = aws_ecs_cluster.gateway.name },
        { name = "ECS_SERVICE_NAME", value = local.pod_service_name },
        { name = "ECR_REPO_URI", value = aws_ecr_repository.gateway_replicated.repository_url },
        { name = "ALB_DNS_NAME", value = aws_lb.gateway.dns_name },
        { name = "ALB_HOSTED_ZONE_ID", value = aws_lb.gateway.zone_id },
        { name = "DEPLOYMENT_ROLE_ARN", value = aws_iam_role.deployment.arn },
        { name = "ECR_PUSH_ROLE_ARN", value = aws_iam_role.ecr_push.arn },
        { name = "CONTROL_PLANE_URL", value = var.control_plane_url },
      ])

      secrets = [
        {
          name      = "GATEWAY_POD_ID"
          valueFrom = "${local.pod_secret_arn}:GATEWAY_POD_ID::"
        },
        {
          name      = "GATEWAY_HMAC_SECRET"
          valueFrom = "${local.pod_secret_arn}:GATEWAY_HMAC_SECRET::"
        },
        {
          name      = "GATEWAY_REGISTRATION_SECRET"
          valueFrom = "${aws_secretsmanager_secret.registration.arn}:GATEWAY_REGISTRATION_SECRET::"
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gateway.name
          "awslogs-region"        = local.aws_region
          "awslogs-stream-prefix" = "gateway"
        }
      }
    }
  ])

  tags = { Name = "${local.pod_prefix}-task" }
}

# ──────────────────────────────────────────────────────────
# ECS Service
# ──────────────────────────────────────────────────────────

resource "aws_ecs_service" "gateway" {
  name            = local.pod_service_name
  cluster         = aws_ecs_cluster.gateway.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 120

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.gateway.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "gateway"
    container_port   = 8080
  }

  tags = { Name = "${local.pod_prefix}-service" }

  lifecycle {
    # Terraform OWNS task_definition: an apply that changes the task def (env
    # vars, cpu/mem, roles — e.g. APP_ENV/INFRA_VERSION) rolls the running
    # service onto the new revision. This is safe because the image is a STABLE
    # env tag (var.gateway_image_tag, e.g. ':prod'), so TF and the deploy
    # mechanisms agree on the image — TF never reverts a pinned tag. Image
    # rollouts are still driven outside TF: CI (owned) and the control-plane
    # deploy (customers) re-push the env tag and force-new-deployment.
    # desired_count stays ignored (owned by autoscaling).
    ignore_changes = [desired_count]
  }
}

# ──────────────────────────────────────────────────────────
# Auto Scaling
# ──────────────────────────────────────────────────────────

resource "aws_appautoscaling_target" "gateway" {
  max_capacity       = var.max_count
  min_capacity       = var.min_count
  resource_id        = "service/${aws_ecs_cluster.gateway.name}/${aws_ecs_service.gateway.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "gateway_cpu" {
  name               = "${local.pod_prefix}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.gateway.resource_id
  scalable_dimension = aws_appautoscaling_target.gateway.scalable_dimension
  service_namespace  = aws_appautoscaling_target.gateway.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "gateway_requests" {
  name               = "${local.pod_prefix}-request-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.gateway.resource_id
  scalable_dimension = aws_appautoscaling_target.gateway.scalable_dimension
  service_namespace  = aws_appautoscaling_target.gateway.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.gateway.arn_suffix}/${aws_lb_target_group.gateway.arn_suffix}"
    }
    target_value       = 1000.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
