# WAF Module — Reusable WebACL with AWS Managed Rules
#
# Attaches to an ALB (REGIONAL scope). Includes:
#   - AWS Common Rule Set (SQLi, XSS, path traversal, etc.)
#   - IP Reputation List (known-bad IPs, botnets)
#   - Rate limiting (per source IP)
#
# All rules start in COUNT mode by default. Set count_mode = false
# to switch to BLOCK after validating no false positives.

resource "aws_wafv2_web_acl" "main" {
  name        = "${var.project_name}-${var.environment}-${var.name}-waf"
  description = "WAF for ${var.name} - ${var.environment}"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Rules — Common Rule Set (OWASP Top 10)
  rule {
    name     = "aws-managed-common"
    priority = 10

    override_action {
      dynamic "count" {
        for_each = var.count_mode ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = var.count_mode ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # Exclude rules that commonly false-positive on API traffic
        dynamic "rule_action_override" {
          for_each = var.common_rule_exclusions
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${var.environment}-${var.name}-common"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules — IP Reputation List
  rule {
    name     = "aws-managed-ip-reputation"
    priority = 20

    override_action {
      dynamic "count" {
        for_each = var.count_mode ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = var.count_mode ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${var.environment}-${var.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # Rate limiting — per source IP
  rule {
    name     = "rate-limit"
    priority = 30

    action {
      dynamic "count" {
        for_each = var.count_mode ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.count_mode ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${var.environment}-${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${var.environment}-${var.name}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-${var.name}-waf"
    Environment = var.environment
    Project     = var.project_name
  }
}

# Associate the WebACL with the ALB
resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# CloudWatch log group for WAF (optional)
resource "aws_cloudwatch_log_group" "waf" {
  count             = var.enable_logging ? 1 : 0
  name              = "aws-waf-logs-${var.project_name}-${var.environment}-${var.name}"
  retention_in_days = 30

  tags = {
    Name        = "${var.project_name}-${var.environment}-${var.name}-waf-logs"
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  count                   = var.enable_logging ? 1 : 0
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]
  resource_arn            = aws_wafv2_web_acl.main.arn
}
