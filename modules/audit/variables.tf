# Audit module variables.

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

variable "customer" {
  description = "Customer identifier (used in resource names)"
  type        = string
}

variable "enable_cloudtrail" {
  description = "Create an account-level multi-region CloudTrail trail + S3 bucket. Set false if you aggregate CloudTrail elsewhere."
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Create a standalone GuardDuty detector. Set false if you manage GuardDuty elsewhere (or are importing an existing detector — see README)."
  type        = bool
  default     = true
}

variable "cloudtrail_retention_days" {
  description = "Days to retain CloudTrail logs in S3 before expiry"
  type        = number
  default     = 365
}

variable "tags" {
  description = "Additional tags to apply to audit resources"
  type        = map(string)
  default     = {}
}
