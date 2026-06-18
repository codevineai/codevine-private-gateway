# Audit Module — account-level CloudTrail + GuardDuty
#
# When CodeVine hands this account over, the account leaves the CodeVine AWS
# Organization. Org-level CloudTrail (org trail) and org-managed GuardDuty
# (member relationship) STOP covering the account on removal. This module
# stands up self-contained, account-local replacements so the gateway account
# keeps an audit trail and threat detection of its own — no dependency on any
# Organization.
#
# Neither service is management-account-only; both run fine in a standalone
# member account. Only the ORG-WIDE aggregation (org trail, delegated-admin
# GuardDuty) is management-account scoped, and that is intentionally not
# reproduced here.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  prefix     = "${var.project_name}-${var.environment}-${var.customer}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  base_tags = merge(var.tags, {
    Component = "audit"
  })
}

# ──────────────────────────────────────────────────────────
# CloudTrail — multi-region trail to a dedicated S3 bucket
# ──────────────────────────────────────────────────────────

resource "aws_s3_bucket" "trail" {
  count         = var.enable_cloudtrail ? 1 : 0
  bucket        = "${local.prefix}-cloudtrail-${local.account_id}"
  force_destroy = false

  tags = merge(local.base_tags, { Name = "${local.prefix}-cloudtrail" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = var.enable_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    expiration { days = var.cloudtrail_retention_days }
  }
}

# CloudTrail service must be allowed to write to the bucket
resource "aws_s3_bucket_policy" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:${local.partition}:cloudtrail:${data.aws_region.current.name}:${local.account_id}:trail/${local.prefix}-trail"
          }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail[0].arn}/AWSLogs/${local.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:${local.partition}:cloudtrail:${data.aws_region.current.name}:${local.account_id}:trail/${local.prefix}-trail"
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  count = var.enable_cloudtrail ? 1 : 0

  name           = "${local.prefix}-trail"
  s3_bucket_name = aws_s3_bucket.trail[0].id

  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  tags = merge(local.base_tags, { Name = "${local.prefix}-trail" })

  depends_on = [aws_s3_bucket_policy.trail]
}

# ──────────────────────────────────────────────────────────
# GuardDuty — standalone detector
#
# NOTE: an account can have only ONE detector per region. While this account
# is still a GuardDuty member of the CodeVine org, a detector already exists.
# On org removal that detector becomes standalone. To bring it under Terraform
# without a conflict, import it on the cutover apply:
#
#   terraform import 'module.audit.aws_guardduty_detector.main[0]' <detector-id>
#
# (or set enable_guardduty = false until after removal, then enable + import).
# ──────────────────────────────────────────────────────────

resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true

  tags = merge(local.base_tags, { Name = "${local.prefix}-guardduty" })
}
