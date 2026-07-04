# Secrets + pod identity.
#
# Two credentials (do not conflate):
#   - registration_secret: bootstrap credential the gateway uses to register and
#     to run the cert-validation callback. Generated-or-provided, frozen.
#   - pod identity (GATEWAY_POD_ID + GATEWAY_HMAC_SECRET): the pod's live-auth
#     identity. Generated once and frozen (ignore_changes) — the control plane
#     treats a pod's HMAC as immutable, so identity must be stable for the pod's
#     life. To migrate an existing pod, pre-create the credentials secret before
#     first apply and ignore_changes preserves it (these randoms become inert).

resource "random_id" "pod_id" {
  byte_length = 8
}

resource "random_password" "hmac_secret" {
  length           = 32
  special          = true
  override_special = "!$*()_+-[]{}:;.,~"
}

resource "random_password" "registration_secret" {
  length           = 48
  special          = true
  override_special = "!$*()_+-[]{}:;.,~"
}

locals {
  pod_id_value      = random_id.pod_id.hex
  hmac_secret_value = random_password.hmac_secret.result
  pod_secret_arn    = aws_secretsmanager_secret.pod.arn

  # Provided value wins, else the generated one. MUST match what the registration
  # secret version freezes so the callback presents the value the control plane has
  # on record. Under the issue-first model the operator PROVIDES this (CodeVine
  # minted it) on the apply that runs the callback.
  effective_registration_secret = var.registration_secret != "" ? var.registration_secret : random_password.registration_secret.result
}

# ── Registration secret ──────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "registration" {
  name        = "${local.name}-registration"
  description = "Gateway registration secret for control-plane bootstrap (register + cert-validation callback)."
  tags        = merge(local.tags, { Name = "${local.name}-registration" })
}

resource "aws_secretsmanager_secret_version" "registration" {
  secret_id     = aws_secretsmanager_secret.registration.id
  secret_string = jsonencode({ GATEWAY_REGISTRATION_SECRET = local.effective_registration_secret })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── Pod credentials (identity) ───────────────────────────────────────────────

resource "aws_secretsmanager_secret" "pod" {
  name        = "${local.name}-credentials"
  description = "Gateway pod identity (GATEWAY_POD_ID + GATEWAY_HMAC_SECRET) for ${local.name}."
  tags        = merge(local.tags, { Name = "${local.name}-credentials" })
}

resource "aws_secretsmanager_secret_version" "pod" {
  secret_id = aws_secretsmanager_secret.pod.id
  secret_string = jsonencode({
    GATEWAY_POD_ID      = local.pod_id_value
    GATEWAY_HMAC_SECRET = local.hmac_secret_value
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
