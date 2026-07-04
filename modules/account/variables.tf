# Account-bootstrap module — variables.
#
# Applied ONCE per AWS account. Owns the resources that are account- or
# registry-scoped singletons and therefore CANNOT be per-pod: the shared ECR
# repos + registry policy + cross-account push role, and the account audit
# baseline (CloudTrail + GuardDuty). Every gateway pod in the account consumes
# this module's outputs (ecr_repo_url, ecr_push_role_arn).

variable "project_name" {
  description = "Project name — used in the control-plane-coupled ECR repo path and push-role name. Leave default."
  type        = string
  default     = "codevine"
}

variable "environment" {
  description = "Environment segment for account-scoped names (cv-gw-{environment}-account-*)."
  type        = string
  default     = "prod"
}

variable "control_plane_account_id" {
  description = "CodeVine control plane AWS account ID — trust principal for the ECR push role + registry replication policy."
  type        = string
}

variable "manage_registry" {
  description = "Create the per-ACCOUNT ECR singletons: the registry replication policy (one per registry) + the fixed-name cross-account push role (codevine-gateway-ecr-push). TRUE for the first env in an account; FALSE for a SECOND env sharing the same account (e.g. stage sharing dev's account) — it reuses the first env's registry policy + push role and only creates its own per-env ECR repo. The registry policy already grants the whole project repository namespace, so it covers every env's repo."
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Create an account-level multi-region CloudTrail trail + S3 bucket. Set false if the account aggregates CloudTrail elsewhere."
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Create a standalone GuardDuty detector (one per account+region). Set false if a detector already exists / is managed elsewhere; import an existing one if needed."
  type        = bool
  default     = true
}

variable "cloudtrail_retention_days" {
  description = "Days to retain CloudTrail logs in S3 before expiry."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Additional tags applied to all account-bootstrap resources."
  type        = map(string)
  default     = {}
}
