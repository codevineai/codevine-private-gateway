# Root variables.
#
# Required: customer, control_plane_account_id, control_plane_url.
# These are provided by CodeVine during onboarding. registration_secret
# is also provided by CodeVine (treat as sensitive).

variable "aws_region" {
  description = "AWS region to deploy the gateway into"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for your account (the account the gateway runs in)"
  type        = string
}

variable "customer" {
  description = "Your customer identifier, assigned by CodeVine (lowercase, 2-21 chars). Becomes {customer}.gateway.codevine.ai."
  type        = string
}

variable "control_plane_account_id" {
  description = "CodeVine control plane AWS account ID (provided by CodeVine)"
  type        = string
}

variable "control_plane_url" {
  description = "CodeVine control plane base URL (provided by CodeVine, e.g. https://id.codevine.ai)"
  type        = string
  default     = "https://id.codevine.ai"
}

variable "registration_secret" {
  description = "Per-pod gateway registration secret. OPTIONAL — leave empty (default) to have Terraform GENERATE a strong random value into your Secrets Manager; read it back from `terraform output registration_secret_arn` and give it to CodeVine to create this pod's record. Or PROVIDE a value (TF_VAR_registration_secret / a gitignored *.auto.tfvars) that you handed to CodeVine; it is loaded on first apply and frozen (ignore_changes), so you may clear the var afterward. This is unique to this gateway, not a shared fleet secret."
  type        = string
  sensitive   = true
  default     = ""
}

# Networking

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones (must match the region)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (one per AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# Scaling

variable "gateway_image_tag" {
  description = "ECR image tag the gateway pins to (stable per-environment tag; default 'prod'). Image rollouts re-push this tag + restart the service; the task def only changes for non-image reasons. Override to 'dev'/'stage' for non-prod owned environments."
  type        = string
  default     = "prod"
}

variable "gateway_cpu" {
  description = "CPU units for the gateway task"
  type        = number
  default     = 512
}

variable "gateway_memory" {
  description = "Memory (MiB) for the gateway task"
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Desired number of gateway tasks"
  type        = number
  default     = 2
}

variable "min_count" {
  description = "Minimum number of gateway tasks"
  type        = number
  default     = 1
}

variable "max_count" {
  description = "Maximum number of gateway tasks"
  type        = number
  default     = 10
}

# WAF

variable "enable_waf" {
  description = "Enable WAF on the gateway ALB"
  type        = bool
  default     = false
}

variable "waf_count_mode" {
  description = "When true, WAF rules COUNT instead of BLOCK (initial rollout)"
  type        = bool
  default     = true
}

# Operational

variable "enable_deletion_protection" {
  description = "Enable ALB deletion protection. Set false only when you intend to tear the gateway down."
  type        = bool
  default     = true
}

variable "cert_validation_timeout" {
  description = "How long the FIRST apply waits for CodeVine to add the DNS validation record (format like '45m'). Only relevant on the first apply or a cert change."
  type        = string
  default     = "45m"
}

variable "infra_version" {
  description = "CodeVine-controlled infra version stamp (semver, default '1.6'). Surfaced to the gateway as INFRA_VERSION. Bumped by CodeVine, not customers. 1.1: ALB idle_timeout 300->600s. 1.2: optional hard data retention (source_data_retention_days). 1.3: naming parameterization + moved{} contract (no-op for existing deployments). 1.4: pod identity generated + owned in customer Secrets Manager (no override vars). 1.5: inject APP_ENV=production so the gateway's env helper reports the correct environment; per-pod registration secret now generated-or-provided + always written (count gate removed, de-indexed via moved{}) — no-op for existing deployments. 1.6: ECR cross-account replication — registry policy + replicated repo (codevine/{env}/gateway) the gateway pulls from; replaces the control-plane image copy. Requires terraform apply."
  type        = string
  default     = "1.6"
}

variable "source_data_retention_days" {
  description = "Hard retention (days) for raw chat source data in S3 + DynamoDB. 0 = retain forever (default). When >0, AWS auto-expires payloads/items, slides active-session TTLs, and caps log retention to match. NOTE: DynamoDB PITR retains up to 35 days independent of this; disable PITR for a strict <35-day guarantee. See modules/gateway/variables.tf for full semantics."
  type        = number
  default     = 0

  validation {
    condition     = var.source_data_retention_days >= 0
    error_message = "source_data_retention_days must be >= 0 (0 = retain forever)."
  }
}

# Audit — account-level CloudTrail + GuardDuty
#
# Defaults ON so the account keeps audit logging + threat detection after it
# leaves the CodeVine AWS Organization (the org trail and org-managed GuardDuty
# stop covering it on removal). Set false if you centralize these elsewhere.

variable "enable_cloudtrail" {
  description = "Create an account-level multi-region CloudTrail trail + S3 bucket"
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Create a standalone GuardDuty detector. See README re: importing an existing detector after org removal."
  type        = bool
  default     = true
}

variable "cloudtrail_retention_days" {
  description = "Days to retain CloudTrail logs in S3 before expiry"
  type        = number
  default     = 365
}
