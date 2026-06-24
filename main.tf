# CodeVine Dedicated Gateway — root module
#
# Runs entirely in YOUR (the customer's) AWS account. Provisions a
# self-contained gateway pod: VPC, ECS cluster, ECR, ALB, ACM cert, and
# the gateway workload (ECS service, SQS, DynamoDB, S3, IAM, autoscaling).
#
# DNS for {customer}.gateway.codevine.ai is managed by CodeVine. After
# apply, send the `domain_validation_options` output to CodeVine so they
# can validate the TLS certificate and point the gateway hostname at your
# ALB. See README.md.

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "codevine"
      ManagedBy = "Terraform"
      Component = "dedicated-gateway"
      Customer  = var.customer
    }
  }
}

module "gateway" {
  source = "./modules/gateway"

  customer                 = var.customer
  control_plane_account_id = var.control_plane_account_id
  control_plane_url        = var.control_plane_url
  registration_secret      = var.registration_secret

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

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

# Account-level audit logging + threat detection. Defaults ON so the account
# retains CloudTrail + GuardDuty after it leaves the CodeVine AWS Organization
# (org-level coverage stops on removal). See modules/audit and README.
module "audit" {
  source = "./modules/audit"

  customer = var.customer

  enable_cloudtrail         = var.enable_cloudtrail
  enable_guardduty          = var.enable_guardduty
  cloudtrail_retention_days = var.cloudtrail_retention_days
}
