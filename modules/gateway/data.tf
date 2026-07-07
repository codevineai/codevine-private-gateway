# Data stores — S3 payload bucket, DynamoDB table, SQS queues. All per-pod.

locals {
  # Data-store names default to the cv-gw scheme, but can be OVERRIDDEN to an
  # existing physical name so a migration IMPORTS the existing bucket/table in
  # place (a rename would force replace = data loss). This is how every env
  # reuses its existing owned-1 S3 + DynamoDB instead of copying data — set the
  # overrides to the legacy names and add the import blocks (imports.tf.example).
  s3_bucket_name      = var.s3_payload_bucket_name != "" ? var.s3_payload_bucket_name : "${local.name}-payloads-${local.account_id}"
  dynamodb_table_name = var.dynamodb_table_name != "" ? var.dynamodb_table_name : "${local.name}-data"

  pod_s3_bucket_name = aws_s3_bucket.payload.id
  pod_s3_bucket_arn  = aws_s3_bucket.payload.arn
  pod_dynamodb_name  = aws_dynamodb_table.data.name
}

# ── S3 payload bucket ────────────────────────────────────────────────────────

resource "aws_s3_bucket" "payload" {
  bucket = local.s3_bucket_name
  tags   = merge(local.tags, { Name = "${local.name}-payloads" })
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

  # Hard data-retention expunge, only when source_data_retention_days > 0. Expires
  # the CURRENT object AND noncurrent versions at the same age (the bucket is
  # versioned, so both are required for a true hard delete). Pairs with the
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
  bucket                  = aws_s3_bucket.payload.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── DynamoDB data table (shared by all tenants on this pod) ───────────────────

resource "aws_dynamodb_table" "data" {
  name                        = local.dynamodb_table_name
  billing_mode                = "PAY_PER_REQUEST"
  deletion_protection_enabled = var.enable_deletion_protection
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

  # PITR keeps up to 35 days of continuous backups INDEPENDENT of the TTL above.
  # For a strict "gone after N<35 days" guarantee, disable this.
  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.tags, { Name = "${local.name}-data" })
}

# ── SQS queues ───────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "outbound_dlq" {
  name                      = "${local.name}-sqs-out-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = merge(local.tags, { Name = "${local.name}-sqs-out-dlq" })
}

resource "aws_sqs_queue" "outbound" {
  name                       = "${local.name}-sqs-out"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.outbound_dlq.arn
    maxReceiveCount     = 5
  })

  tags = merge(local.tags, { Name = "${local.name}-sqs-out" })
}

resource "aws_sqs_queue" "inbound_dlq" {
  name                      = "${local.name}-sqs-in-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = merge(local.tags, { Name = "${local.name}-sqs-in-dlq" })
}

resource "aws_sqs_queue" "inbound" {
  name                       = "${local.name}-sqs-in"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.inbound_dlq.arn
    maxReceiveCount     = 5
  })

  tags = merge(local.tags, { Name = "${local.name}-sqs-in" })
}
