# Observability — log group + upload-processing metric filters.
#
# Filters watch the gateway's Go slog output for upload-processing anomalies
# (JSONL format drift, parent-chain failures, consolidation drift). Alarms on
# these metrics are left to the operator's monitoring stack.

locals {
  # CloudWatch accepts only a fixed set of retention values. Logs must not outlive
  # the data-retention window, so pick the largest allowed value <= the window;
  # fall back to 90 days when retention is disabled (0).
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

  upload_metric_namespace = "${var.project_name}/${var.environment}/gateway-upload"
  upload_alarm_prefix     = "${local.name}-upload"

  # Metric-filter definitions: key -> { pattern, metric }.
  upload_filters = {
    unknown_types = {
      pattern = "\"upload: unknown record types encountered\""
      metric  = "UnknownRecordTypes"
    }
    missing_uuid = {
      pattern = "\"upload: records missing UUID\""
      metric  = "RecordsMissingUUID"
    }
    majority_no_ancestor = {
      pattern = "\"upload: majority of assistants missing user ancestor\""
      metric  = "MajorityNoAncestor"
    }
    chunk_anomalies = {
      pattern = "\"upload: chunk processing anomalies\""
      metric  = "ChunkProcessingAnomalies"
    }
    consolidation_drift = {
      pattern = "\"upload: unusual streaming consolidation ratio\""
      metric  = "ConsolidationDrift"
    }
    empty_prior_chunk = {
      pattern = "\"upload: prior chunk loaded but contained 0 parseable records\""
      metric  = "EmptyPriorChunk"
    }
  }
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/ecs/${local.name}"
  retention_in_days = local.log_retention_days

  tags = merge(local.tags, { Name = "${local.name}-logs" })
}

resource "aws_cloudwatch_log_metric_filter" "upload" {
  for_each = local.upload_filters

  name           = "${local.upload_alarm_prefix}-${replace(each.key, "_", "-")}"
  log_group_name = aws_cloudwatch_log_group.gateway.name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.value.metric
    namespace     = local.upload_metric_namespace
    value         = "1"
    default_value = "0"
  }
}
