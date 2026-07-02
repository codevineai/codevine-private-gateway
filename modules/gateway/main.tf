# Gateway Module — Self-contained customer gateway pod
#
# Provisions ALL infrastructure in the CUSTOMER's AWS account:
# VPC, ECS cluster, ECR, ALB, ACM cert, and the gateway workload
# (ECS service, SQS, DynamoDB, S3, IAM, autoscaling).
#
# Cross-account touchpoints (all OUTBOUND from the customer account):
#   - control_plane_url        — gateway heartbeat/registration target
#   - control_plane_account_id — trust principal for the deployment/ecr-push/
#                                observability roles the control plane assumes
#   - registration_secret      — shared secret for self-registration
#
# DNS is NOT managed here. The ACM certificate is created PENDING_VALIDATION
# and the DNS validation record (domain_validation_options, surfaced as a
# root output) is added to the codevine.ai zone by CodeVine out-of-band.
# The cert finishes validating asynchronously; HTTPS serves a valid cert
# within minutes of CodeVine adding the record.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Capture the git commit of the applied infra checkout. Degrades to "unknown"
# when not run inside a git checkout or when git is unavailable (e.g. a customer
# applying from a tarball or CI without git) — the `|| echo unknown` guard keeps
# the apply from failing in that case.
data "external" "git_hash" {
  program = ["sh", "-c", "printf '{\"hash\":\"%s\"}' \"$(git rev-parse --short HEAD 2>/dev/null || echo unknown)\""]
}

locals {
  infra_git_hash = try(data.external.git_hash.result.hash, "unknown")
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  aws_region = data.aws_region.current.name

  # ── Naming (parameterized for long-term stability) ──────────────────────
  # Physical resource names derive from a slug + two prefixes, each defaulting
  # to the original customer formula so existing deployments are byte-for-byte
  # unchanged (terraform plan == "No changes"). Owned/internal deployments can
  # override pod_slug / name_prefix to reproduce a different existing naming
  # scheme without touching this module.
  #
  #   pod_slug    -> the "dedicated-{customer}" token used in pod-scoped names
  #                  (DynamoDB, SQS, ECS service/task, S3 payload, secret, logs,
  #                   target group, task IAM roles)
  #   name_prefix -> the "{project}-{env}-{customer}" prefix used in
  #                  account/region-scoped names (ALB, ECS cluster, deployment role)
  pod_slug    = var.pod_slug != "" ? var.pod_slug : "dedicated-${var.customer}"
  name_prefix = var.name_prefix != "" ? var.name_prefix : "${var.project_name}-${var.environment}-${var.customer}"

  prefix       = local.name_prefix
  pod_prefix   = "${var.project_name}-${var.environment}-gw-${local.pod_slug}"

  # The repo the gateway task pulls from. Normally this module owns the replicated
  # repo (codevine/{env}/gateway). When manage_ecr_repo=false (an internal/owned
  # deployment that runs in the SAME account as the control plane, where that repo
  # already exists and is owned by the control plane's own Terraform), the module
  # creates NO ECR resources and pulls from the provided ecr_repo_url instead.
  gateway_repo_url = var.manage_ecr_repo ? aws_ecr_repository.gateway_replicated[0].repository_url : var.ecr_repo_url

  # TLS cert + listener host. Every pod serves the WILDCARD *.gateway.{domain}:
  # a gateway pod is multi-tenant (many {tenant}.gateway hosts route to one pod),
  # so a wildcard cert + wildcard listener is the only model. The module issues
  # its OWN *.gateway.{domain} ACM cert in the operator's account and validates it
  # via the control-plane callback (see aws_acm_certificate.gateway below). An
  # external cert ARN may still be provided (var.gateway_cert_arn) to skip cert
  # creation entirely (e.g. an owned pod reusing an already-issued wildcard ARN).
  wildcard_domain  = "*.gateway.${var.domain_name}"
  manage_cert      = var.gateway_cert_arn == ""
  gateway_cert_arn = var.gateway_cert_arn != "" ? var.gateway_cert_arn : aws_acm_certificate_validation.gateway[0].certificate_arn
  listener_host    = var.gateway_host_header != "" ? var.gateway_host_header : local.wildcard_domain

  # The registration secret the gateway uses to authenticate to the control plane
  # (register + the cert-validation callback). Provided value wins; otherwise the
  # generated one. MUST match what aws_secretsmanager_secret_version.registration
  # freezes (below) so the callback presents the value the control plane has on
  # record. Under the issue-first model the operator PROVIDES this (CodeVine minted
  # it), so var.registration_secret is set on the apply that runs the callback.
  effective_registration_secret = var.registration_secret != "" ? var.registration_secret : random_password.registration_secret.result

  # Tag applied to roles the control plane can assume
  management_tag_key   = var.project_name
  management_tag_value = "gateway-management"
}

# ──────────────────────────────────────────────────────────
# VPC — 2-AZ, single NAT (cost-conscious for dedicated pods)
# ──────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.prefix}-public-${var.availability_zones[count.index]}" }
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.prefix}-private-${var.availability_zones[count.index]}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.prefix}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags       = { Name = "${local.prefix}-nat" }
  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-private-rt" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ──────────────────────────────────────────────────────────
# ECS Cluster — dedicated to this customer
# ──────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "gateway" {
  name = "${local.prefix}-gateway"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${local.prefix}-gateway-cluster" }
}

# ──────────────────────────────────────────────────────────
# ECR — customer-account repo, images pushed via ecr_push_role
# ──────────────────────────────────────────────────────────

resource "aws_ecr_repository" "gateway" {
  count                = var.manage_ecr_repo ? 1 : 0
  name                 = "${var.project_name}/gateway"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${local.prefix}-gateway-ecr" }
}

resource "aws_ecr_lifecycle_policy" "gateway" {
  count      = var.manage_ecr_repo ? 1 : 0
  repository = aws_ecr_repository.gateway[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 30 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 50 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 50
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Allow the control plane to push images to this ECR
resource "aws_ecr_repository_policy" "cross_account_push" {
  count      = var.manage_ecr_repo ? 1 : 0
  repository = aws_ecr_repository.gateway[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowControlPlanePush"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.control_plane_account_id}:root" }
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
      ]
    }]
  })
}

# ──────────────────────────────────────────────────────────
# Replicated gateway repo — destination of CodeVine's ECR cross-account
# replication. CodeVine's master ECR (control_plane_account_id) replicates the
# gateway image into THIS account at the SAME repo path it uses upstream
# (codevine/{env}/gateway) — ECR replication preserves the repository name, it
# cannot rename. The gateway task definition pulls from here (see service.tf),
# so AWS delivers blobs+manifest server-side (no app-level layer copy) and a
# new image is available in this account automatically. The :env tag is moved
# here per-pod by CodeVine's Promote action, never auto-propagated.
resource "aws_ecr_repository" "gateway_replicated" {
  count                = var.manage_ecr_repo ? 1 : 0
  name                 = "${var.project_name}/${var.environment}/gateway"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${local.prefix}-gateway-replicated-ecr" }
}

resource "aws_ecr_lifecycle_policy" "gateway_replicated" {
  count      = var.manage_ecr_repo ? 1 : 0
  repository = aws_ecr_repository.gateway_replicated[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 30 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 30 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 50 tagged images"
        selection    = { tagStatus = "tagged", tagPatternList = ["*"], countType = "imageCountMoreThan", countNumber = 50 }
        action       = { type = "expire" }
      }
    ]
  })
}

# Registry-level policy granting CodeVine's account permission to REPLICATE the
# gateway image into this account's registry (and create the destination repo on
# first replication). This is account-level (one policy per registry) and is what
# makes the control plane's dynamic replication config able to target this account.
resource "aws_ecr_registry_policy" "allow_control_plane_replication" {
  count = var.manage_ecr_repo ? 1 : 0
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowControlPlaneReplication"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.control_plane_account_id}:root" }
      Action = [
        "ecr:CreateRepository",
        "ecr:ReplicateImage",
      ]
      Resource = "arn:aws:ecr:*:${local.account_id}:repository/${var.project_name}/*"
    }]
  })
}

# ──────────────────────────────────────────────────────────
# ACM Certificate for *.gateway.{domain} (wildcard)
#
# DNS-validated. The validation record must live in the {domain} zone, which
# CodeVine controls — the operator (customer OR CodeVine) has no access to write
# it directly. So during `terraform apply` the module CALLS BACK to the control
# plane, authenticated by the registration_secret as a bearer credential, asking
# it to add the ACM validation CNAME to the zone (see data.external below). ACM
# then validates asynchronously.
#
# Why a wildcard: a gateway pod is multi-tenant — many {tenant}.gateway hosts
# route to one pod — so one cert must cover them all. ACM DNS-validation tokens
# are unique per cert per account, so each pod's record is distinct and they do
# not collide even though every pod uses the same *.gateway.{domain} name.
#
# aws_acm_certificate_validation GATES the apply: on the FIRST apply it blocks
# until the cert reaches ISSUED (i.e. until the callback record has propagated
# and ACM validated). This makes the listener's dependency on a *validated* cert
# explicit and avoids the ALB "UnsupportedCertificate" error. On every SUBSEQUENT
# apply the cert is already ISSUED, so it is a no-op and the apply is single-phase.
# ──────────────────────────────────────────────────────────

resource "aws_acm_certificate" "gateway" {
  count             = local.manage_cert ? 1 : 0
  domain_name       = local.wildcard_domain
  validation_method = "DNS"

  tags = { Name = "${local.prefix}-gateway-cert" }
  lifecycle { create_before_destroy = true }
}

# Cert-validation callback. During apply, POST the ACM validation record(s) to
# the control plane (which owns the {domain} zone), authenticated by the
# registration_secret sent as a bearer credential over TLS. The control plane
# UPSERTs the CNAME so ACM can validate + auto-renew. Idempotent server-side, so
# re-applies are harmless. Uses the same sh+curl pattern as data.external.git_hash.
#
# Inputs are passed via `query` (stringified by Terraform). jq is NOT assumed;
# the script reads the JSON from stdin with a tiny sed/grep-free parser via the
# shell's here-doc. curl + sh are the only host deps (present on any CI/dev box).
data "external" "cert_validation_callback" {
  count = local.manage_cert ? 1 : 0

  program = ["sh", "${path.module}/scripts/cert-validation-callback.sh"]

  query = {
    control_plane_url   = var.control_plane_url
    registration_secret = local.effective_registration_secret
    # The ACM validation record for the wildcard cert. domain_validation_options
    # is a set; the wildcard cert has exactly one entry.
    record_name  = one(aws_acm_certificate.gateway[0].domain_validation_options).resource_record_name
    record_value = one(aws_acm_certificate.gateway[0].domain_validation_options).resource_record_value
    region       = local.aws_region
  }
}

# Validation gate. No validation_record_fqdns: the record is created by the
# control plane via the callback above, so this just polls the cert ARN until
# ISSUED. depends_on the callback so the record is posted BEFORE we start polling.
# Configurable timeout so a stuck first apply fails cleanly instead of hanging.
resource "aws_acm_certificate_validation" "gateway" {
  count           = local.manage_cert ? 1 : 0
  certificate_arn = aws_acm_certificate.gateway[0].arn

  depends_on = [data.external.cert_validation_callback]

  timeouts {
    create = var.cert_validation_timeout
  }
}

# ──────────────────────────────────────────────────────────
# ALB — dedicated per customer
# ──────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb-sg"
  description = "Security group for ${var.customer} gateway ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from anywhere (redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-alb-sg" }
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = "${local.prefix}-alb-logs-${local.account_id}"
  tags   = { Name = "${local.prefix}-alb-logs" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
}

locals {
  elb_account_ids = {
    us-east-1      = "127311923021"
    us-east-2      = "033677994240"
    us-west-1      = "027434742980"
    us-west-2      = "797873946194"
    eu-west-1      = "156460612806"
    eu-central-1   = "054676820928"
    ap-southeast-1 = "114774131450"
    ap-northeast-1 = "582318560864"
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.elb_account_ids[local.aws_region]}:root" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/*"
    }]
  })
}

resource "aws_lb" "gateway" {
  name               = substr("${local.prefix}-gw-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection       = var.enable_deletion_protection
  enable_http2                     = true
  enable_cross_zone_load_balancing = true
  # 10 minutes. Idle (no-bytes) timeout — resets while a response streams, so it
  # does not clip healthy streams. Kept strictly ABOVE the gateway binary's 300s
  # stream-inactivity timeout so the gateway's own timer fires first on a genuine
  # stall, yielding a clean error + partial-token capture rather than an opaque
  # ALB 504. Must move in lockstep with the shared ALB (codevine repo
  # modules/alb) since both front the same gateway binary.
  idle_timeout = 600

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = { Name = "${local.prefix}-gw-alb" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Depends on the validation gate so the listener is created only once the
# cert is ISSUED (avoids the ALB "UnsupportedCertificate" error).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.gateway_cert_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# ──────────────────────────────────────────────────────────
# WAF (optional)
# ──────────────────────────────────────────────────────────

module "waf" {
  count  = var.enable_waf ? 1 : 0
  source = "../waf"

  project_name = var.project_name
  environment  = var.environment
  name         = "gateway-${var.customer}"
  alb_arn      = aws_lb.gateway.arn
  count_mode   = var.waf_count_mode
}

# ──────────────────────────────────────────────────────────
# Cross-account IAM — roles the control plane can assume
# ──────────────────────────────────────────────────────────

# Deployment role — control plane assumes this to push ECS deployments
resource "aws_iam_role" "deployment" {
  name = "${local.prefix}-deployment"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.control_plane_account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = "arn:aws:iam::${var.control_plane_account_id}:role/${var.project_name}-*-ecs-task"
        }
      }
    }]
  })

  tags = {
    Name                       = "${local.prefix}-deployment"
    (local.management_tag_key) = local.management_tag_value
  }
}

resource "aws_iam_role_policy" "deployment" {
  name = "${local.prefix}-deployment"
  role = aws_iam_role.deployment.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped to codevine-* ECS services in this account so new gateway
        # services can be created/updated without re-granting, while the
        # customer's non-CodeVine services stay out of reach.
        Sid    = "ECSDeployServices"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
        ]
        Resource = "arn:aws:ecs:*:${local.account_id}:service/${var.project_name}-*"
      },
      {
        # DescribeTaskDefinition / RegisterTaskDefinition do not support
        # resource-level permissions in IAM (AWS limitation) — must be "*".
        Sid    = "ECSTaskDefinitions"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${local.account_id}:role/${local.prefix}-*"
      }
    ]
  })
}

# ECR push role — control plane assumes this to push images
resource "aws_iam_role" "ecr_push" {
  name = "${var.project_name}-gateway-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.control_plane_account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = "arn:aws:iam::${var.control_plane_account_id}:role/${var.project_name}-*-ecs-task"
        }
      }
    }]
  })

  tags = {
    Name                       = "${var.project_name}-gateway-ecr-push"
    (local.management_tag_key) = local.management_tag_value
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "${var.project_name}-gateway-ecr-push"
  role = aws_iam_role.ecr_push.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken is an account-level action and does not
        # support resource scoping (AWS requirement) — must be "*".
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # Repo-level push/pull scoped to codevine/* repositories so new
        # codevine/* ECRs can be created and pushed to without re-granting,
        # while the customer's other repos stay out of reach.
        Sid    = "EcrPushPull"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:*:${local.account_id}:repository/${var.project_name}/*"
      }
    ]
  })
}

# ──────────────────────────────────────────────────────────
# Registration secret — generated-or-provided, owned in the customer account.
#
# The gateway reads this to self-register with the control plane. With CodeVine's
# per-pod registration model, this secret is unique to THIS gateway (it is NOT a
# shared fleet secret), so — like the pod identity above — the customer's own
# Terraform can generate it:
#
#   - Generate (default): leave var.registration_secret empty and TF writes a
#     strong random value here. Read it back (terraform output, or from Secrets
#     Manager) and give it to CodeVine so the pod record can be created with it.
#   - Provide: set var.registration_secret to a value CodeVine gave you (or one
#     you generated and handed to CodeVine); TF loads THAT on first apply. You may
#     then clear the var — ignore_changes keeps the value, so it lives only here.
#
# Either way the value is frozen on first create (ignore_changes), so it is never
# rewritten on later applies — matching how the control plane treats it.
# ──────────────────────────────────────────────────────────

resource "random_password" "registration_secret" {
  length           = 48
  special          = true
  override_special = "!$*()_+-[]{}:;.,~"
}

resource "aws_secretsmanager_secret" "registration" {
  name        = "${var.project_name}/${var.environment}/gateway/registration"
  description = "Gateway registration secret for control plane heartbeat"
}

resource "aws_secretsmanager_secret_version" "registration" {
  secret_id = aws_secretsmanager_secret.registration.id

  secret_string = jsonencode({
    GATEWAY_REGISTRATION_SECRET = local.effective_registration_secret
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
