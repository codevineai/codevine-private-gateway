# Gateway pod module — a single, fully name-isolated gateway pod.
#
# Provisions everything a pod needs in the operator's AWS account: network
# (or BYO VPC), ALB + wildcard ACM cert, ECS service, DynamoDB, S3, SQS, IAM,
# autoscaling, observability. It creates NO account-shared singletons — the ECR
# repo + push role live in modules/account and are passed in (ecr_repo_url,
# ecr_push_role_arn), so any number of pods coexist in one account.
#
# Cross-account touchpoints are all OUTBOUND from this account to the control
# plane (register / heartbeat / cert-validation callback), authenticated by the
# per-pod registration secret. The control plane reaches in only via the
# deployment / observability roles this module creates.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# Git commit of the applied checkout, stamped onto the running gateway. Degrades
# to "unknown" outside a git checkout (tarball / CI) — the guard keeps apply green.
data "external" "git_hash" {
  program = ["sh", "-c", "printf '{\"hash\":\"%s\"}' \"$(git rev-parse --short HEAD 2>/dev/null || echo unknown)\""]
}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  region         = data.aws_region.current.name
  partition      = data.aws_partition.current.partition
  infra_git_hash = try(data.external.git_hash.result.hash, "unknown")

  # ── Naming ───────────────────────────────────────────────────────────────
  # ONE scheme for EVERY physical resource: cv-gw-{environment}-{pod_name}-{type}.
  # `cv-gw` carries the gateway marker; `pod_name` is the sole per-pod token, so N
  # pods coexist in one account. `customer` is a tag only. Length is validated so
  # the 32-char-capped names (ALB, target group) never truncate.
  name = "cv-gw-${var.environment}-${var.pod_name}"

  # Common tags merged onto every resource (on top of provider default_tags).
  tags = merge(var.tags, {
    ManagedBy = "codevine"
    Component = "gateway-pod"
    PodName   = var.pod_name
    Customer  = var.customer
  })
}
