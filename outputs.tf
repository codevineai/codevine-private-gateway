# Root outputs.
#
# Certificate validation is automatic: during `terraform apply` the module posts
# its ACM validation record to the CodeVine control plane (authenticated by the
# registration_secret), which adds it to the codevine.ai zone. No manual step.

output "cert_validation_records" {
  description = "ACM DNS validation record(s) — added automatically to the codevine.ai zone via the control-plane callback during apply. Informational/debugging only."
  value       = module.gateway.domain_validation_options
}

output "alb_dns_name" {
  description = "This pod's ALB DNS name. The gateway self-reports it to the control plane via heartbeat (used for per-tenant DNS routing) — informational here, no manual step."
  value       = module.gateway.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID"
  value       = module.gateway.alb_zone_id
}

output "ecr_repository_url" {
  description = "ECR repository URL (CodeVine pushes the gateway image here)"
  value       = module.gateway.ecr_repository_url
}

output "registration_secret_arn" {
  description = "Secrets Manager ARN of this pod's registration secret. Only relevant on the GENERATE path (registration_secret left empty): read the value and hand it to CodeVine to create the pod record. On the issue-first path (CodeVine minted the secret and you pasted it in) this is unused."
  value       = module.gateway.registration_secret_arn
}

output "deployment_role_arn" {
  description = "Cross-account deployment role ARN"
  value       = module.gateway.deployment_role_arn
}

output "ecr_push_role_arn" {
  description = "Cross-account ECR push role ARN"
  value       = module.gateway.ecr_push_role_arn
}

output "observability_role_arn" {
  description = "Cross-account observability role ARN"
  value       = module.gateway.observability_role_arn
}

output "cloudtrail_bucket" {
  description = "S3 bucket holding this account's CloudTrail logs (null if disabled)"
  value       = module.audit.cloudtrail_bucket
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID for this account (null if disabled)"
  value       = module.audit.guardduty_detector_id
}
