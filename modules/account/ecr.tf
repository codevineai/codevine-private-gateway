# Shared gateway ECR — one repo per account, the destination of CodeVine's ECR
# cross-account replication. The repo NAME is control-plane-coupled: ECR
# replication preserves the repository path (codevine/{env}/gateway) — it cannot
# rename — so this is intentionally NOT pod-scoped. Every pod in the account pulls
# this same image (each pod's ECS task def references the output repository_url).

resource "aws_ecr_repository" "gateway" {
  name                 = "${var.project_name}/${var.environment}/gateway"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, { Name = "${local.prefix}-ecr" })
}

resource "aws_ecr_lifecycle_policy" "gateway" {
  repository = aws_ecr_repository.gateway.name

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

# Registry-level policy (one per registry) granting CodeVine's account permission
# to REPLICATE the gateway image into this account and create the destination repo
# on first replication. Account singleton → created only when manage_registry=true
# (the first env in the account); its repository/${project}/* scope covers every
# env's repo, so a second env sharing the account reuses this one.
resource "aws_ecr_registry_policy" "replication" {
  count = var.manage_registry ? 1 : 0
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowControlPlaneReplication"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${var.control_plane_account_id}:root" }
      Action    = ["ecr:CreateRepository", "ecr:ReplicateImage"]
      Resource  = "arn:${local.partition}:ecr:*:${local.account_id}:repository/${var.project_name}/*"
    }]
  })
}

# Cross-account push role — the control plane assumes this (by fixed name) for
# Promote/retag operations against the shared repo. Trust is scoped to the control
# plane account's ECS task roles.
resource "aws_iam_role" "ecr_push" {
  count = var.manage_registry ? 1 : 0
  name  = "${var.project_name}-gateway-ecr-push"

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

  tags = merge(local.tags, { Name = "${var.project_name}-gateway-ecr-push" })
}

resource "aws_iam_role_policy" "ecr_push" {
  count = var.manage_registry ? 1 : 0
  name  = "${var.project_name}-gateway-ecr-push"
  role  = aws_iam_role.ecr_push[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken is account-level and does not support resource
        # scoping (AWS requirement) — must be "*".
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
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
        Resource = "arn:${local.partition}:ecr:*:${local.account_id}:repository/${var.project_name}/*"
      }
    ]
  })
}
