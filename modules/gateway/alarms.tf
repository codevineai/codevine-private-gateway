# Upload Processing Observability — Metric Filters
#
# Monitors the gateway's slog output for upload processing anomalies:
#   - JSONL structure changes (unknown record types, missing UUIDs)
#   - Parent chain resolution failures (no user ancestor, empty parentUUID)
#   - Streaming consolidation drift (unusual raw-to-consolidated ratio)
#   - Missing token usage data
#
# All filters match Go slog structured text output (key=value pairs).
# CloudWatch alarms on these metrics (with SNS notification) are left to
# the customer's own monitoring stack if desired.

locals {
  upload_metric_namespace = "${var.project_name}/${var.environment}/gateway-upload"
  upload_alarm_prefix     = "${local.pod_prefix}-upload"
}

# 1. Unknown JSONL record types — possible Claude Code format change
resource "aws_cloudwatch_log_metric_filter" "upload_unknown_types" {
  name           = "${local.upload_alarm_prefix}-unknown-types"
  log_group_name = aws_cloudwatch_log_group.gateway.name
  pattern        = "\"upload: unknown record types encountered\""

  metric_transformation {
    name          = "UnknownRecordTypes"
    namespace     = local.upload_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# 2. Records missing UUID — data integrity issue
resource "aws_cloudwatch_log_metric_filter" "upload_missing_uuid" {
  name           = "${local.upload_alarm_prefix}-missing-uuid"
  log_group_name = aws_cloudwatch_log_group.gateway.name
  pattern        = "\"upload: records missing UUID\""

  metric_transformation {
    name          = "RecordsMissingUUID"
    namespace     = local.upload_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# 3. Majority of assistants missing user ancestor — critical structure change
resource "aws_cloudwatch_log_metric_filter" "upload_majority_no_ancestor" {
  name           = "${local.upload_alarm_prefix}-majority-no-ancestor"
  log_group_name = aws_cloudwatch_log_group.gateway.name
  pattern        = "\"upload: majority of assistants missing user ancestor\""

  metric_transformation {
    name          = "MajorityNoAncestor"
    namespace     = local.upload_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# 4. Chunk processing anomalies (any: no ancestor, no parent UUID, no usage)
resource "aws_cloudwatch_log_metric_filter" "upload_chunk_anomalies" {
  name           = "${local.upload_alarm_prefix}-chunk-anomalies"
  log_group_name = aws_cloudwatch_log_group.gateway.name
  pattern        = "\"upload: chunk processing anomalies\""

  metric_transformation {
    name          = "ChunkProcessingAnomalies"
    namespace     = local.upload_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# 5. Unusual streaming consolidation ratio
resource "aws_cloudwatch_log_metric_filter" "upload_consolidation_drift" {
  name           = "${local.upload_alarm_prefix}-consolidation-drift"
  log_group_name = aws_cloudwatch_log_group.gateway.name
  pattern        = "\"upload: unusual streaming consolidation ratio\""

  metric_transformation {
    name          = "ConsolidationDrift"
    namespace     = local.upload_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# 6. Prior chunk loaded but empty — cross-chunk resolution data issue
resource "aws_cloudwatch_log_metric_filter" "upload_empty_prior_chunk" {
  name           = "${local.upload_alarm_prefix}-empty-prior-chunk"
  log_group_name = aws_cloudwatch_log_group.gateway.name
  pattern        = "\"upload: prior chunk loaded but contained 0 parseable records\""

  metric_transformation {
    name          = "EmptyPriorChunk"
    namespace     = local.upload_metric_namespace
    value         = "1"
    default_value = "0"
  }
}
