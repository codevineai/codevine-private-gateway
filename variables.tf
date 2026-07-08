# Root variables. Required: pod_name, aws_profile, control_plane_account_id.
# Provided by CodeVine at onboarding.

# ── Your account ─────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for the account the gateway runs in."
  type        = string
}

# ── Identity ─────────────────────────────────────────────────────────────────

variable "pod_name" {
  description = "The pod's unique name, assigned by CodeVine (lowercase, 2-15 chars). Sole token in every resource name (cv-gw-{environment}-{pod_name}-*). Does NOT affect DNS."
  type        = string
}

variable "customer" {
  description = "Customer/owner label for tags + billing only (never in a name). Optional."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Project name (cross-account ARNs + ECR path). Leave default."
  type        = string
  default     = "codevine"
}

variable "environment" {
  description = "Environment segment of resource names. Keep short (prod/stage/dev)."
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "Base domain for the wildcard cert (*.gateway.{domain_name})."
  type        = string
  default     = "codevine.ai"
}

variable "control_plane_account_id" {
  description = "CodeVine control plane AWS account ID (provided by CodeVine)."
  type        = string
}

variable "control_plane_url" {
  description = "CodeVine control plane base URL (provided by CodeVine)."
  type        = string
  default     = "https://id.codevine.ai"
}

variable "registration_secret" {
  description = "Per-pod bootstrap secret. Empty (default) = Terraform generates one (read it from `terraform output` and give it to CodeVine); or provide the value CodeVine minted. Frozen on first apply."
  type        = string
  sensitive   = true
  default     = ""
}

# ── Account bootstrap (shared ECR + audit) ───────────────────────────────────

variable "manage_account" {
  description = "Run the account-bootstrap module (per-env ECR repo, and — when manage_registry/enable_* are true — the account singletons). TRUE for the first pod of an ENVIRONMENT in an account. FALSE for ADDITIONAL pods in the same env+account — then set ecr_repo_url + ecr_push_role_arn from the first deployment."
  type        = bool
  default     = true
}

variable "manage_registry" {
  description = "Create the per-ACCOUNT ECR singletons (registry replication policy + fixed-name push role). TRUE for the FIRST environment in an account. FALSE for a SECOND environment sharing the account (e.g. stage sharing dev's account 366290348639) — it still creates its own per-env ECR repo but reuses the account's registry policy + push role. Only consulted when manage_account=true."
  type        = bool
  default     = true
}

variable "ecr_repo_url" {
  description = "Shared gateway ECR repo URL. Ignored when manage_account=true (taken from the account module); REQUIRED when manage_account=false."
  type        = string
  default     = ""
}

variable "ecr_push_role_arn" {
  description = "Shared ECR push role ARN. Ignored when manage_account=true; optional when manage_account=false."
  type        = string
  default     = ""
}

variable "enable_cloudtrail" {
  description = "Create an account-level multi-region CloudTrail (account module). Only used when manage_account=true."
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Create a standalone GuardDuty detector (account module). Only used when manage_account=true. See README re: importing an existing detector."
  type        = bool
  default     = true
}

variable "cloudtrail_retention_days" {
  description = "Days to retain CloudTrail logs in S3."
  type        = number
  default     = 365
}

# ── TLS / hostname ───────────────────────────────────────────────────────────

variable "gateway_cert_arn" {
  description = "Reuse an existing *.gateway.{domain} ACM cert by ARN. Empty (default) = create + validate one."
  type        = string
  default     = ""
}

# Reuse existing data stores via import (preserves chat data with no copy).
# Set to the legacy physical names; empty = the cv-gw defaults. See imports.tf.example.
variable "s3_payload_bucket_name" {
  description = "Override the S3 payload bucket name to reuse an existing bucket via import. Empty = cv-gw default."
  type        = string
  default     = ""
}

variable "dynamodb_table_name" {
  description = "Override the DynamoDB data table name to reuse an existing table via import. Empty = cv-gw default."
  type        = string
  default     = ""
}

variable "gateway_host_header" {
  description = "Override the ALB listener host_header match. Empty = the wildcard."
  type        = string
  default     = ""
}

variable "listener_rule_priority" {
  description = "ALB listener-rule priority (only matters when pods share a listener)."
  type        = number
  default     = 10
}

# ── Networking (create-or-bring-your-own) ────────────────────────────────────

variable "vpc_id" {
  description = "Existing VPC ID. Empty (default) = create a new VPC. When set, both subnet lists are required."
  type        = string
  default     = ""
}

variable "public_subnet_ids" {
  description = "Existing public subnet IDs (ALB) when vpc_id is set."
  type        = list(string)
  default     = []
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs (ECS tasks) when vpc_id is set."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "VPC CIDR when creating a new VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs (must match the region)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (one per AZ), used only when creating a VPC."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (one per AZ), used only when creating a VPC."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# ── Sizing / scaling ─────────────────────────────────────────────────────────

variable "gateway_image_tag" {
  description = "ECR image tag the gateway pins to (stable per-env tag; default 'prod')."
  type        = string
  default     = "prod"
}

variable "gateway_cpu" {
  description = "CPU units for the gateway task."
  type        = number
  default     = 512
}

variable "gateway_memory" {
  description = "Memory (MiB) for the gateway task."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Desired number of gateway tasks."
  type        = number
  default     = 2
}

variable "min_count" {
  description = "Minimum gateway tasks."
  type        = number
  default     = 1
}

variable "max_count" {
  description = "Maximum gateway tasks."
  type        = number
  default     = 10
}

# ── WAF ──────────────────────────────────────────────────────────────────────

variable "enable_waf" {
  description = "Enable a WAF on the gateway ALB."
  type        = bool
  default     = false
}

variable "waf_count_mode" {
  description = "When true, WAF rules COUNT instead of BLOCK (initial rollout)."
  type        = bool
  default     = true
}

# ── Operational ──────────────────────────────────────────────────────────────

variable "enable_deletion_protection" {
  description = "Deletion protection for the ALB + DynamoDB table. Set false only for teardown."
  type        = bool
  default     = true
}

variable "cert_validation_timeout" {
  description = "How long the first apply waits for ACM validation (e.g. '45m')."
  type        = string
  default     = "45m"
}

variable "infra_version" {
  description = "CodeVine-controlled infra version stamp. 2.1: task-role Bedrock invoke in the pod account (pod-local analytics fallback). 2.0: clean-baseline rewrite (account/pod split, cv-gw naming, BYO network, http cert callback)."
  type        = string
  default     = "2.1"
}

variable "source_data_retention_days" {
  description = "Hard retention (days) for raw chat source data. 0 = retain forever (default). See modules/gateway for semantics."
  type        = number
  default     = 0
}
