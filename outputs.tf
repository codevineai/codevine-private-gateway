# Root outputs.

output "registration_secret_arn" {
  description = "Secrets Manager ARN of the pod registration secret. On the GENERATE path, read the value and hand it to CodeVine to create the pod record."
  value       = module.gateway.registration_secret_arn
}

output "alb_dns_name" {
  description = "Pod ALB DNS name. Self-reported to the control plane via heartbeat — informational here."
  value       = module.gateway.alb_dns_name
}

output "alb_zone_id" {
  description = "Pod ALB hosted zone ID."
  value       = module.gateway.alb_zone_id
}

output "cert_validation_records" {
  description = "ACM validation record(s) — added automatically to the {domain} zone via the control-plane callback during apply. Informational."
  value       = module.gateway.domain_validation_options
}

output "ecr_repo_url" {
  description = "Shared gateway ECR repo URL. Pass as ecr_repo_url to ADDITIONAL pods in this account (manage_account = false)."
  value       = local.ecr_repo_url
}

output "ecr_push_role_arn" {
  description = "Shared ECR push role ARN. Pass to additional pods (manage_account = false)."
  value       = local.ecr_push_role_arn
}

output "deployment_role_arn" {
  description = "Cross-account deployment role ARN."
  value       = module.gateway.deployment_role_arn
}

output "observability_role_arn" {
  description = "Cross-account observability role ARN."
  value       = module.gateway.observability_role_arn
}

output "s3_bucket_name" {
  description = "Gateway S3 payload bucket (import reference)."
  value       = module.gateway.s3_bucket_name
}

output "dynamodb_table_name" {
  description = "Gateway DynamoDB table (import reference)."
  value       = module.gateway.dynamodb_table_name
}

output "cloudtrail_bucket" {
  description = "S3 bucket holding this account's CloudTrail logs (null if account not managed here or CloudTrail disabled)."
  value       = var.manage_account ? module.account[0].cloudtrail_bucket : null
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID (null if account not managed here or GuardDuty disabled)."
  value       = var.manage_account ? module.account[0].guardduty_detector_id : null
}
