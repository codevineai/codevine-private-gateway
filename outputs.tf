# Root outputs.
#
# After `terraform apply`, run `terraform output dns_validation_for_codevine`
# and send the result to CodeVine to complete certificate validation and
# DNS setup.

output "dns_validation_for_codevine" {
  description = "SEND TO CODEVINE: ACM DNS validation record(s) to add to the codevine.ai zone"
  value       = module.gateway.domain_validation_options
}

output "alb_dns_name" {
  description = "SEND TO CODEVINE: ALB DNS name to point {customer}.gateway.codevine.ai at"
  value       = module.gateway.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID"
  value       = module.gateway.alb_zone_id
}

output "gateway_fqdn" {
  description = "Gateway FQDN"
  value       = module.gateway.gateway_fqdn
}

output "ecr_repository_url" {
  description = "ECR repository URL (CodeVine pushes the gateway image here)"
  value       = module.gateway.ecr_repository_url
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
