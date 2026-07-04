# ECS — cluster, task security group, target group + host rule, task def, service.

locals {
  pod_service_name = "${local.name}-svc"
}

resource "aws_ecs_cluster" "gateway" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.tags, { Name = "${local.name}-cluster" })
}

# ── Task security group ──────────────────────────────────────────────────────

resource "aws_security_group" "gateway" {
  name        = "${local.name}-sg"
  description = "Security group for ${local.name} gateway tasks"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Allow traffic from the ALB"
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

  tags = merge(local.tags, { Name = "${local.name}-sg" })
}

# ── Target group + listener wiring ───────────────────────────────────────────

resource "aws_lb_target_group" "gateway" {
  name        = "${local.name}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
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

  tags = merge(local.tags, { Name = "${local.name}-tg" })
}

# Attach the (validated) gateway cert as an SNI cert on the HTTPS listener.
resource "aws_lb_listener_certificate" "gateway" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = local.gateway_cert_arn
}

# Route the wildcard gateway host(s) to the target group. Default host_header is
# the *.gateway.{domain} wildcard, so every {tenant}.gateway host on this pod
# matches; var.gateway_host_header overrides for a bespoke single-host setup.
resource "aws_lb_listener_rule" "gateway" {
  listener_arn = aws_lb_listener.https.arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }

  condition {
    host_header {
      values = [local.listener_host]
    }
  }
}

# ── Task definition ──────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "gateway" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.gateway_cpu
  memory                   = var.gateway_memory
  execution_role_arn       = aws_iam_role.gateway_task_execution.arn
  task_role_arn            = aws_iam_role.gateway_task.arn

  container_definitions = jsonencode([
    {
      name      = "gateway"
      image     = "${var.ecr_repo_url}:${var.gateway_image_tag}"
      essential = true

      portMappings = [
        { containerPort = 8080, protocol = "tcp" }
      ]

      environment = [
        { name = "GATEWAY_PORT", value = "8080" },
        { name = "LOG_DIR", value = "/var/log/gateway" },
        # APP_ENV is the cross-language deployment-env source of truth (shared with
        # the backend). A deployed gateway is always "production". No NODE_ENV — Go.
        { name = "APP_ENV", value = "production" },
        { name = "INFRA_VERSION", value = var.infra_version },
        { name = "INFRA_GIT_HASH", value = local.infra_git_hash },
        { name = "S3_PAYLOAD_BUCKET", value = local.pod_s3_bucket_name },
        { name = "SQS_OUTBOUND_QUEUE_URL", value = aws_sqs_queue.outbound.url },
        { name = "SQS_INBOUND_QUEUE_URL", value = aws_sqs_queue.inbound.url },
        { name = "AWS_REGION", value = local.region },
        { name = "AWS_ACCOUNT_ID", value = local.account_id },
        { name = "DYNAMODB_TABLE_NAME", value = local.pod_dynamodb_name },
        { name = "SOURCE_DATA_RETENTION_DAYS", value = tostring(var.source_data_retention_days) },
        { name = "OBSERVABILITY_ROLE_ARN", value = aws_iam_role.observability.arn },
        { name = "ECS_CLUSTER_NAME", value = aws_ecs_cluster.gateway.name },
        { name = "ECS_SERVICE_NAME", value = local.pod_service_name },
        { name = "ECR_REPO_URI", value = var.ecr_repo_url },
        { name = "ALB_DNS_NAME", value = aws_lb.gateway.dns_name },
        { name = "ALB_HOSTED_ZONE_ID", value = aws_lb.gateway.zone_id },
        { name = "DEPLOYMENT_ROLE_ARN", value = aws_iam_role.deployment.arn },
        { name = "ECR_PUSH_ROLE_ARN", value = var.ecr_push_role_arn },
        { name = "CONTROL_PLANE_URL", value = var.control_plane_url },
      ]

      secrets = [
        { name = "GATEWAY_POD_ID", valueFrom = "${local.pod_secret_arn}:GATEWAY_POD_ID::" },
        { name = "GATEWAY_HMAC_SECRET", valueFrom = "${local.pod_secret_arn}:GATEWAY_HMAC_SECRET::" },
        { name = "GATEWAY_REGISTRATION_SECRET", valueFrom = "${aws_secretsmanager_secret.registration.arn}:GATEWAY_REGISTRATION_SECRET::" },
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
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "gateway"
        }
      }
    }
  ])

  tags = merge(local.tags, { Name = "${local.name}-task" })
}

# ── Service ──────────────────────────────────────────────────────────────────

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
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.gateway.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "gateway"
    container_port   = 8080
  }

  tags = merge(local.tags, { Name = "${local.name}-svc" })

  lifecycle {
    # Terraform OWNS task_definition (an env/cpu/role change rolls the service —
    # safe because the image is a stable env tag, so TF never reverts a pinned
    # image). desired_count stays ignored (owned by autoscaling).
    ignore_changes = [desired_count]
  }
}
