# Audit module outputs.

output "cloudtrail_arn" {
  description = "ARN of the account CloudTrail trail (null if disabled)"
  value       = var.enable_cloudtrail ? aws_cloudtrail.main[0].arn : null
}

output "cloudtrail_bucket" {
  description = "S3 bucket holding CloudTrail logs (null if disabled)"
  value       = var.enable_cloudtrail ? aws_s3_bucket.trail[0].id : null
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID (null if disabled)"
  value       = var.enable_guardduty ? aws_guardduty_detector.main[0].id : null
}
