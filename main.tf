# CodeVine Gateway — root module.
#
# Composes two concerns:
#   - modules/account : account-shared singletons (ECR repo + push role, audit).
#                       Applied ONCE per account (manage_account = true, default).
#   - modules/gateway : the per-pod gateway. Fully name-isolated by pod_name, so
#                       any number run in one account.
#
# First pod in an account: manage_account = true (creates the account bootstrap
# and consumes its outputs). Additional pods in the SAME account: set
# manage_account = false and pass ecr_repo_url + ecr_push_role_arn from the first
# deployment's outputs. DNS + per-tenant hostnames are handled by the control
# plane; cert validation is automatic via the in-apply callback. See README.

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}

module "account" {
  count  = var.manage_account ? 1 : 0
  source = "./modules/account"

  project_name             = var.project_name
  environment              = var.environment
  control_plane_account_id = var.control_plane_account_id
  manage_registry          = var.manage_registry

  enable_cloudtrail         = var.enable_cloudtrail
  enable_guardduty          = var.enable_guardduty
  cloudtrail_retention_days = var.cloudtrail_retention_days
}

locals {
  ecr_repo_url      = var.manage_account ? module.account[0].ecr_repo_url : var.ecr_repo_url
  ecr_push_role_arn = var.manage_account ? module.account[0].ecr_push_role_arn : var.ecr_push_role_arn
}

module "gateway" {
  source = "./modules/gateway"

  pod_name                 = var.pod_name
  customer                 = var.customer
  project_name             = var.project_name
  environment              = var.environment
  domain_name              = var.domain_name
  control_plane_account_id = var.control_plane_account_id
  control_plane_url        = var.control_plane_url
  registration_secret      = var.registration_secret

  ecr_repo_url      = local.ecr_repo_url
  ecr_push_role_arn = local.ecr_push_role_arn

  gateway_cert_arn       = var.gateway_cert_arn
  gateway_host_header    = var.gateway_host_header
  listener_rule_priority = var.listener_rule_priority

  gateway_image_tag          = var.gateway_image_tag
  gateway_cpu                = var.gateway_cpu
  gateway_memory             = var.gateway_memory
  desired_count              = var.desired_count
  min_count                  = var.min_count
  max_count                  = var.max_count
  enable_waf                 = var.enable_waf
  waf_count_mode             = var.waf_count_mode
  enable_deletion_protection = var.enable_deletion_protection
  cert_validation_timeout    = var.cert_validation_timeout
  infra_version              = var.infra_version
  source_data_retention_days = var.source_data_retention_days

  vpc_id               = var.vpc_id
  public_subnet_ids    = var.public_subnet_ids
  private_subnet_ids   = var.private_subnet_ids
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}
