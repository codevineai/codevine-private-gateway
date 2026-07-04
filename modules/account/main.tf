# Account-bootstrap module — data sources, locals, tags.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  partition  = data.aws_partition.current.partition

  # Account-scoped name prefix (one bootstrap per account+env).
  prefix = "cv-gw-${var.environment}-account"

  tags = merge(var.tags, {
    ManagedBy = "codevine"
    Component = "gateway-account"
  })
}
