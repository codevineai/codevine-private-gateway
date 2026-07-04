# Gateway pod module — outputs.

output "domain_validation_options" {
  description = "ACM DNS validation records, added automatically via the control-plane callback during apply. Informational. Empty when an external cert is provided."
  value = [
    for dvo in(length(aws_acm_certificate.gateway) > 0 ? aws_acm_certificate.gateway[0].domain_validation_options : []) : {
      domain           = dvo.domain_name
      validation_name  = dvo.resource_record_name
      validation_type  = dvo.resource_record_type
      validation_value = dvo.resource_record_value
    }
  ]
}

output "alb_dns_name" {
  description = "Pod ALB DNS name (the control plane points the gateway A-record here)."
  value       = aws_lb.gateway.dns_name
}

output "alb_zone_id" {
  description = "Pod ALB hosted zone ID."
  value       = aws_lb.gateway.zone_id
}

output "vpc_id" {
  description = "VPC the pod runs in (created or provided)."
  value       = local.vpc_id
}

output "ecs_cluster_name" {
  description = "Pod ECS cluster name."
  value       = aws_ecs_cluster.gateway.name
}

output "gateway_service_name" {
  description = "Pod ECS service name."
  value       = aws_ecs_service.gateway.name
}

output "deployment_role_arn" {
  description = "IAM role ARN the control plane assumes to deploy ECS updates."
  value       = aws_iam_role.deployment.arn
}

output "observability_role_arn" {
  description = "IAM role ARN the control plane assumes to consume SQS + read metrics."
  value       = aws_iam_role.observability.arn
}

output "s3_bucket_name" {
  description = "Gateway S3 payload bucket."
  value       = local.pod_s3_bucket_name
}

output "dynamodb_table_name" {
  description = "Gateway DynamoDB table name."
  value       = local.pod_dynamodb_name
}

output "sqs_outbound_queue_url" {
  description = "Gateway outbound SQS queue URL."
  value       = aws_sqs_queue.outbound.url
}

output "sqs_inbound_queue_url" {
  description = "Gateway inbound SQS queue URL."
  value       = aws_sqs_queue.inbound.url
}

output "registration_secret_arn" {
  description = "Secrets Manager ARN of the registration secret (control plane reads it to create this pod's record)."
  value       = aws_secretsmanager_secret.registration.arn
}
