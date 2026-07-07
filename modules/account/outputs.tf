# Account-bootstrap module — outputs consumed by each gateway pod.

output "ecr_repo_url" {
  description = "URL of the shared gateway ECR repo the pods pull from (codevine/{env}/gateway)."
  value       = aws_ecr_repository.gateway.repository_url
}

output "ecr_push_role_arn" {
  description = "ARN of the shared cross-account ECR push role (control plane assumes it for Promote/retag). Pods report this on heartbeat. When manage_registry=false (a second env reusing the account's push role) the ARN is constructed from its fixed name."
  value       = var.manage_registry ? aws_iam_role.ecr_push[0].arn : "arn:${local.partition}:iam::${local.account_id}:role/${var.project_name}-gateway-ecr-push"
}

output "cloudtrail_bucket" {
  description = "S3 bucket holding the account CloudTrail logs (null if disabled)."
  value       = var.enable_cloudtrail ? aws_s3_bucket.trail[0].id : null
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID (null if disabled)."
  value       = var.enable_guardduty ? aws_guardduty_detector.main[0].id : null
}
