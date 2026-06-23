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
  description = "Shared secret for gateway self-registration with the control plane. Leave empty to set the secret value manually in Secrets Manager after apply."
  type        = string
  sensitive   = true
  default     = ""
}

# Pod identity — leave empty to generate (normal for new pods). Set BOTH to
# reuse an existing pod's identity during an in-place rebuild (Strategy A).

variable "pod_id" {
  description = "Override the generated pod ID (GATEWAY_POD_ID). Empty = generate. Set to reuse an existing registered pod's identity."
  type        = string
  default     = ""
}

variable "hmac_secret" {
  description = "Override the generated pod HMAC secret (GATEWAY_HMAC_SECRET). Empty = generate. Must be set together with pod_id when reusing an existing identity."
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
  description = "CodeVine-controlled infra version stamp (semver), surfaced to the gateway as INFRA_VERSION (and onto the heartbeat). Bumped deliberately by CodeVine; not a customer-facing knob. 1.1: ALB idle_timeout 300->600s so the gateway's 300s stream-inactivity timer fires first."
  type        = string
  default     = "1.1"
}
