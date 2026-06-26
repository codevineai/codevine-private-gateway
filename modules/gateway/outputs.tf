# Gateway Module — Outputs

# ──────────────────────────────────────────────────────────
# DNS validation — SEND THESE TO CODEVINE
#
# CodeVine adds this CNAME to the codevine.ai zone to validate the ACM
# certificate. Until then the cert is PENDING_VALIDATION and HTTPS will
# not serve a trusted cert.
# ──────────────────────────────────────────────────────────

output "domain_validation_options" {
  description = "ACM DNS validation records to send to CodeVine (name + value per domain)"
  value = [
    for dvo in aws_acm_certificate.gateway.domain_validation_options : {
      domain           = dvo.domain_name
      validation_name  = dvo.resource_record_name
      validation_type  = dvo.resource_record_type
      validation_value = dvo.resource_record_value
    }
  ]
}

# ──────────────────────────────────────────────────────────
# Gateway endpoint
# ──────────────────────────────────────────────────────────

output "gateway_fqdn" {
  description = "Gateway FQDN for this customer"
  value       = local.gateway_fqdn
}

output "alb_dns_name" {
  description = "Dedicated ALB DNS name (CodeVine points the gateway A-record here)"
  value       = aws_lb.gateway.dns_name
}

output "alb_zone_id" {
  description = "Dedicated ALB hosted zone ID"
  value       = aws_lb.gateway.zone_id
}

# ──────────────────────────────────────────────────────────
# Infrastructure references
# ──────────────────────────────────────────────────────────

output "vpc_id" {
  description = "Customer VPC ID"
  value       = aws_vpc.main.id
}

output "ecs_cluster_name" {
  description = "Customer ECS cluster name"
  value       = aws_ecs_cluster.gateway.name
}

output "ecr_repository_url" {
  description = "Customer ECR repository URL (CodeVine pushes the gateway image here)"
  value       = aws_ecr_repository.gateway.repository_url
}

output "gateway_service_name" {
  description = "Gateway ECS service name"
  value       = aws_ecs_service.gateway.name
}

# ──────────────────────────────────────────────────────────
# Cross-account role ARNs (CodeVine assumes these)
# ──────────────────────────────────────────────────────────

output "deployment_role_arn" {
  description = "IAM role ARN for CodeVine to deploy ECS updates"
  value       = aws_iam_role.deployment.arn
}

output "ecr_push_role_arn" {
  description = "IAM role ARN for CodeVine to push images"
  value       = aws_iam_role.ecr_push.arn
}

output "observability_role_arn" {
  description = "IAM role ARN for CodeVine to consume SQS + read metrics"
  value       = aws_iam_role.observability.arn
}

# ──────────────────────────────────────────────────────────
# Gateway data stores
# ──────────────────────────────────────────────────────────

output "s3_bucket_name" {
  description = "Gateway S3 payload bucket"
  value       = local.pod_s3_bucket_name
}

output "dynamodb_table_name" {
  description = "Gateway DynamoDB table name"
  value       = local.pod_dynamodb_name
}

output "sqs_outbound_queue_url" {
  description = "Gateway outbound SQS queue URL"
  value       = aws_sqs_queue.outbound.url
}

output "sqs_inbound_queue_url" {
  description = "Gateway inbound SQS queue URL"
  value       = aws_sqs_queue.inbound.url
}

output "registration_secret_arn" {
  description = "Secrets Manager ARN of the gateway registration secret (CodeVine reads the value here to create this pod's record)"
  value       = aws_secretsmanager_secret.registration.arn
}
