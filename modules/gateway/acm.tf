# TLS — wildcard *.gateway.{domain} cert, DNS-validated via the control plane.
#
# A pod is multi-tenant (many {tenant}.gateway hosts route to one pod), so a
# wildcard cert is the only workable model. The validation record must live in the
# {domain} zone, which the control plane owns — the operator cannot write it. So
# during apply the module POSTs the ACM validation record to the control plane
# (Bearer-authed by the registration secret); it UPSERTs the CNAME and ACM then
# validates asynchronously. An external cert ARN (var.gateway_cert_arn) skips all
# of this. ACM validation tokens are unique per cert per account, so pods never
# collide even though every pod requests the same wildcard name.

locals {
  wildcard_domain  = "*.gateway.${var.domain_name}"
  manage_cert      = var.gateway_cert_arn == ""
  gateway_cert_arn = var.gateway_cert_arn != "" ? var.gateway_cert_arn : aws_acm_certificate_validation.gateway[0].certificate_arn
  listener_host    = var.gateway_host_header != "" ? var.gateway_host_header : local.wildcard_domain
}

resource "aws_acm_certificate" "gateway" {
  count             = local.manage_cert ? 1 : 0
  domain_name       = local.wildcard_domain
  validation_method = "DNS"

  tags = merge(local.tags, { Name = "${local.name}-cert" })
  lifecycle { create_before_destroy = true }
}

# In-apply cert-validation callback. POSTs the ACM validation record(s) to the
# control plane, Bearer-authed by the registration secret over TLS. Idempotent
# server-side (UPSERT), so re-applies are harmless. Pure HCL via the http provider
# — no shell/curl host dependency. Deferred to apply on first create (the record
# is unknown until the cert exists). The postcondition fails the apply on non-2xx.
#
# Gated on var.registration_secret: the callback fires ONLY when the operator
# supplies the secret (first apply / deliberate re-validation). A data source
# re-executes on EVERY plan, and steady-state plans of a live pod must not
# depend on the bootstrap secret or the control plane — the validation CNAME is
# durable (kept for the pod's life for ACM auto-renewal), so once the cert is
# ISSUED there is nothing to submit.
data "http" "cert_validation_callback" {
  count  = local.manage_cert && var.registration_secret != "" ? 1 : 0
  url    = "${trimsuffix(var.control_plane_url, "/")}/api/internal/gateway/pods/cert-validation"
  method = "POST"

  request_headers = {
    Authorization = "Bearer ${var.registration_secret}"
    Content-Type  = "application/json"
  }

  request_body = jsonencode({
    validation_records = [
      for dvo in aws_acm_certificate.gateway[0].domain_validation_options : {
        region = local.region
        name   = dvo.resource_record_name
        type   = "CNAME"
        value  = dvo.resource_record_value
      }
    ]
  })

  lifecycle {
    postcondition {
      condition     = contains([200, 201, 204], self.status_code)
      error_message = "cert-validation callback failed: HTTP ${self.status_code} from the control plane."
    }
  }
}

# Validation gate. No validation_record_fqdns — the record is created by the
# control plane via the callback above, so this just polls the cert to ISSUED.
# Blocks the FIRST apply until the record propagates; a no-op on later applies.
resource "aws_acm_certificate_validation" "gateway" {
  count           = local.manage_cert ? 1 : 0
  certificate_arn = aws_acm_certificate.gateway[0].arn

  depends_on = [data.http.cert_validation_callback]

  timeouts {
    create = var.cert_validation_timeout
  }

  lifecycle {
    # Fail fast (instead of polling to timeout) when a NOT-yet-issued cert has
    # no way to get its validation record: the callback above was skipped
    # because no registration_secret was supplied. Evaluated at apply, after
    # the cert exists — an already-ISSUED cert passes without the secret.
    precondition {
      condition     = var.registration_secret != "" || aws_acm_certificate.gateway[0].status == "ISSUED"
      error_message = "Cert is not ISSUED and no registration_secret was provided, so the validation record cannot be submitted to the control plane. Re-run with TF_VAR_registration_secret set (CodeVine-minted, issue-first onboarding), or supply a pre-issued cert via var.gateway_cert_arn."
    }
  }
}
