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
  description = "Gateway registration secret (provided by CodeVine). Set via TF_VAR_registration_secret or a *.auto.tfvars file you keep out of version control."
  type        = string
  sensitive   = true
  default     = ""
}

# Pod identity override — leave empty for new deployments. Only set when
# CodeVine instructs you to rebuild an existing pod in place (reuses the
# existing control-plane registration instead of creating a new one).

variable "pod_id" {
  description = "Override the generated pod ID. Empty = generate (normal). Set only for an in-place rebuild, per CodeVine instructions."
  type        = string
  default     = ""
}

variable "hmac_secret" {
  description = "Override the generated pod HMAC secret. Empty = generate (normal). Set together with pod_id for an in-place rebuild."
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
  description = "CodeVine-controlled infra version stamp (default 'v1'). Surfaced to the gateway as INFRA_VERSION. Bumped by CodeVine, not customers."
  type        = string
  default     = "v1"
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
