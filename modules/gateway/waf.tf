# Optional WAF on the gateway ALB (leaf module).

module "waf" {
  count  = var.enable_waf ? 1 : 0
  source = "../waf"

  name       = local.name
  alb_arn    = aws_lb.gateway.arn
  count_mode = var.waf_count_mode
  tags       = local.tags
}
