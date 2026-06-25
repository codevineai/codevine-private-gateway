# Gateway Module — Variables
#
# `customer`, `control_plane_account_id`, `control_plane_url`, and
# `registration_secret` are the customer-specific inputs. Everything
# else has sensible defaults.

variable "customer" {
  description = "Customer identifier (lowercase, alphanumeric + hyphens). Used in resource names and DNS."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.customer))
    error_message = "customer must be lowercase alphanumeric + hyphens, 2-21 chars, starting with a letter"
  }
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "codevine"
}

# Naming overrides — leave empty for normal customer deployments (names derive
# from `customer` exactly as before). Set these only for internal/owned
# deployments that must reproduce a pre-existing naming scheme so Terraform
# adopts existing resources instead of recreating them.

variable "pod_slug" {
  description = "Pod-scoped name token. Empty = 'dedicated-{customer}' (default). Drives DynamoDB, SQS, ECS service/task, S3 payload, credentials secret, log group, target group, and task IAM role names."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Account/region-scoped name prefix. Empty = '{project}-{env}-{customer}' (default). Drives the ALB, ECS cluster, and deployment role names."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "Base domain name (e.g. codevine.ai)"
  type        = string
  default     = "codevine.ai"
}

# Cross-account integration (all OUTBOUND from the customer account)

variable "control_plane_account_id" {
  description = "AWS account ID of the CodeVine control plane. Trust principal for the deployment, ECR-push, and observability roles."
  type        = string
}

variable "control_plane_url" {
  description = "Control plane base URL for gateway heartbeat/registration (e.g. https://id.codevine.ai)"
  type        = string
}

variable "registration_secret" {
  description = "Per-pod secret for gateway self-registration with the control plane. OPTIONAL: empty (default) → Terraform generates a strong random value into Secrets Manager; non-empty → that value is loaded and then frozen (ignore_changes). Unique to this gateway, not a shared fleet secret."
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
  description = "Availability zones for subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# Scaling

variable "gateway_cpu" {
  description = "CPU units for gateway task"
  type        = number
  default     = 512
}

variable "gateway_memory" {
  description = "Memory (MiB) for gateway task"
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

variable "listener_rule_priority" {
  description = "Priority for the ALB listener rule"
  type        = number
  default     = 10
}

# WAF

variable "enable_waf" {
  description = "Enable WAF WebACL on the gateway ALB"
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
  description = "Enable ALB deletion protection. Set false to allow teardown."
  type        = bool
  default     = true
}

variable "cert_validation_timeout" {
  description = "How long the first apply waits for ACM to validate the cert (i.e. for CodeVine to add the DNS record). Format like '45m'."
  type        = string
  default     = "45m"
}

variable "infra_version" {
  description = "CodeVine-controlled infra version stamp (semver), surfaced to the gateway as INFRA_VERSION (and onto the heartbeat). Bumped deliberately by CodeVine; not a customer-facing knob. 1.1: ALB idle_timeout 300->600s so the gateway's 300s stream-inactivity timer fires first. 1.2: optional hard data retention (source_data_retention_days). 1.3: naming parameterization (pod_slug/name_prefix) + moved{} migration contract — internal hardening, no-op for existing deployments. 1.4: pod identity always generated + owned in the customer's Secrets Manager (removed pod_id/hmac_secret override vars); identity frozen via ignore_changes. 1.5: inject APP_ENV=production container env var so the gateway's internal/env helper reports the correct environment; per-pod registration secret generated-or-provided and always written (removed the count gate; de-indexed registration[0]→registration via moved{} so the existing value is preserved, not recreated) — internal hardening, no-op for existing deployments."
  type        = string
  default     = "1.5"
}

variable "source_data_retention_days" {
  description = <<-EOT
    Hard retention period (in days) for raw chat SOURCE data — the request/response
    payloads in S3 and the items in DynamoDB. This is a customer-controlled, AWS-enforced
    "hard delete" lever, independent of any soft retention applied to derived metadata.

    0 (default) = retain forever; no expiration is configured and existing pods are
    unaffected. When > 0:
      - DynamoDB: the gateway stamps an ExpiresAt TTL on each item (REQ#/UPLOAD#/CHUNK#),
        and slides the SESSION# record's TTL forward on every new request so active
        sessions never expire mid-life. AWS reaps expired items.
      - S3: the payload bucket expires both current objects AND noncurrent versions at
        this age (the bucket is versioned, so both are required for a true hard delete).
      - CloudWatch logs: gateway log retention is capped to the largest allowed value
        <= this period, so logs do not outlive the data window.

    CAVEAT — DynamoDB Point-In-Time Recovery (PITR) is enabled on the data table and
    retains up to 35 days of continuous backups INDEPENDENT of this TTL. For a strict
    "data is gone after N days everywhere" guarantee with N < 35, also disable PITR on
    the table (point_in_time_recovery in service.tf). It is left enabled by default as
    an operational safety net.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.source_data_retention_days >= 0
    error_message = "source_data_retention_days must be >= 0 (0 = retain forever)."
  }
}
