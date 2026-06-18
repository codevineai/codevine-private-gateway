variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "name" {
  description = "Name suffix for the WAF (e.g. 'alb', 'gateway-acme')"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB to associate the WAF with"
  type        = string
}

variable "count_mode" {
  description = "When true, all rules COUNT instead of BLOCK (use for initial rollout)"
  type        = bool
  default     = true
}

variable "rate_limit" {
  description = "Maximum requests per 5-minute window per source IP"
  type        = number
  default     = 2000
}

variable "common_rule_exclusions" {
  description = "List of CommonRuleSet rule names to exclude (set to COUNT instead of BLOCK)"
  type        = list(string)
  default = [
    "SizeRestrictions_BODY",   # Large API request bodies (LLM prompts)
    "CrossSiteScripting_BODY", # Code snippets in chat often trigger XSS rules
  ]
}

variable "enable_logging" {
  description = "Enable WAF request logging to CloudWatch"
  type        = bool
  default     = true
}
