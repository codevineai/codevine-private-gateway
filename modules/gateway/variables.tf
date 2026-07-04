# Gateway pod module — variables.

# ── Identity / naming ────────────────────────────────────────────────────────

variable "pod_name" {
  description = "The SOLE per-pod identifier. Every physical name is cv-gw-{environment}-{pod_name}-{type}, so multiple pods coexist in one account. Lowercase alphanumeric + hyphens, 2-15 chars, starting with a letter (e.g. 'luminary', 'owned-1')."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.pod_name))
    error_message = "pod_name must be lowercase alphanumeric + hyphens, 2-15 chars, starting with a letter."
  }

  # Keeps the 32-char-capped names (ALB, target group) within limits without
  # truncation: cv-gw-{env}-{pod_name}-alb is 11 + len(env) + len(pod_name).
  validation {
    condition     = length(var.environment) + length(var.pod_name) <= 21
    error_message = "environment + pod_name must be <= 21 chars combined so the 32-char-capped ALB and target-group names never truncate."
  }
}

variable "customer" {
  description = "Customer/owner label for tagging + billing only (never in a physical name). Optional."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Project name — used only in cross-account IAM/Bedrock ARNs + tag conventions. Leave default."
  type        = string
  default     = "codevine"
}

variable "environment" {
  description = "Environment segment of every name (cv-gw-{environment}-{pod_name}). Keep short."
  type        = string
  default     = "prod"

  validation {
    condition     = length(var.environment) <= 8
    error_message = "environment must be <= 8 chars (e.g. prod/stage/dev)."
  }
}

variable "domain_name" {
  description = "Base domain for the wildcard cert (*.gateway.{domain_name})."
  type        = string
  default     = "codevine.ai"
}

variable "tags" {
  description = "Additional tags applied to all pod resources."
  type        = map(string)
  default     = {}
}

# ── Control-plane integration ────────────────────────────────────────────────

variable "control_plane_account_id" {
  description = "CodeVine control plane AWS account ID. Trust principal for the deployment + observability roles."
  type        = string
}

variable "control_plane_url" {
  description = "Control plane base URL for register / heartbeat / cert-validation callback."
  type        = string
}

variable "registration_secret" {
  description = "Per-pod bootstrap secret. Empty (default) = Terraform generates one; non-empty = that value is loaded and frozen. Unique to this pod."
  type        = string
  sensitive   = true
  default     = ""
}

# ── ECR (from the account module) ────────────────────────────────────────────

variable "ecr_repo_url" {
  description = "URL of the shared gateway ECR repo the task pulls from (modules/account output). Required — an empty value yields un-pullable tasks."
  type        = string

  validation {
    condition     = var.ecr_repo_url != ""
    error_message = "ecr_repo_url must be set (from the account module output, or provided for a same-env additional pod). An empty value produces CannotPullContainerError at runtime."
  }
}

variable "ecr_push_role_arn" {
  description = "ARN of the shared ECR push role (modules/account output). Reported on heartbeat; optional (empty ok)."
  type        = string
  default     = ""
}

# ── TLS / hostname ───────────────────────────────────────────────────────────

variable "gateway_cert_arn" {
  description = "Reuse an existing *.gateway.{domain} ACM cert by ARN instead of creating+validating one. Empty (default) = create + validate via the control-plane callback."
  type        = string
  default     = ""
}

variable "gateway_host_header" {
  description = "Override the ALB listener host_header match. Empty (default) = the *.gateway.{domain} wildcard."
  type        = string
  default     = ""
}

variable "listener_rule_priority" {
  description = "Priority for this pod's ALB listener rule (only matters if multiple pods share a listener)."
  type        = number
  default     = 10
}

# ── Networking (create-or-bring-your-own) ────────────────────────────────────

variable "vpc_id" {
  description = "Existing VPC ID to deploy into. Empty (default) = the module creates its own VPC. When set, public_subnet_ids + private_subnet_ids are required."
  type        = string
  default     = ""

  validation {
    condition     = var.vpc_id == "" || (length(var.public_subnet_ids) > 0 && length(var.private_subnet_ids) > 0)
    error_message = "When vpc_id is set, both public_subnet_ids and private_subnet_ids must be non-empty."
  }
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
  description = "VPC CIDR when the module creates its own VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs for the created subnets (must match the region)."
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
  description = "ECR image tag the task pins to (stable per-env tag; default 'prod'). Rollouts re-push the tag + restart."
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
  description = "Minimum gateway tasks (autoscaling floor)."
  type        = number
  default     = 1
}

variable "max_count" {
  description = "Maximum gateway tasks (autoscaling ceiling)."
  type        = number
  default     = 10
}

# ── WAF ──────────────────────────────────────────────────────────────────────

variable "enable_waf" {
  description = "Enable a WAF WebACL on the gateway ALB."
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
  description = "Deletion protection for the ALB and DynamoDB table. Set false only to allow teardown."
  type        = bool
  default     = true
}

variable "cert_validation_timeout" {
  description = "How long the first apply waits for ACM to validate the cert (format like '45m')."
  type        = string
  default     = "45m"
}

variable "infra_version" {
  description = "CodeVine-controlled infra version stamp (semver), surfaced to the gateway as INFRA_VERSION. 2.0: clean-baseline rewrite — account/pod module split, one consistent cv-gw-{env}-{pod_name} naming scheme, BYO network, http-provider cert callback."
  type        = string
  default     = "2.0"
}

variable "source_data_retention_days" {
  description = "Hard retention (days) for raw chat source data in S3 + DynamoDB. 0 = retain forever (default). When >0, AWS auto-expires payloads/items and caps log retention. NOTE: DynamoDB PITR retains up to 35 days independent of this."
  type        = number
  default     = 0

  validation {
    condition     = var.source_data_retention_days >= 0
    error_message = "source_data_retention_days must be >= 0 (0 = retain forever)."
  }
}
