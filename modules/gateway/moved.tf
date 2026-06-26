# Gateway Module — State Migration Contract (`moved` blocks)
#
# ─── WHY THIS FILE EXISTS ───────────────────────────────────────────────────
#
# This module is THIRD-PARTY-MANAGED infrastructure: it runs in the customer's
# own AWS account, against the customer's own Terraform state, which CodeVine
# cannot reach. We ship structural changes to this module over time (renames,
# refactors, splitting a resource into a module). Without help, ANY change to a
# resource's Terraform ADDRESS — e.g. renaming `aws_lb.gateway` or nesting
# resources into a submodule — would make the customer's next `terraform apply`
# try to DESTROY the old address and CREATE the new one. For data stores
# (DynamoDB, S3) that means data loss; for the ALB it means a new endpoint.
#
# `moved {}` blocks are Terraform's built-in remedy. A `moved` block tells
# Terraform "the thing previously tracked at address X is now at address Y" and
# it silently re-homes the state entry on the next plan/apply — NO destroy, NO
# recreate, NO manual `terraform state mv`, NO action required from the
# customer. This is the ONLY safe way to evolve the structure of infra we do
# not operate.
#
# ─── THE CONTRACT (read before any structural change) ───────────────────────
#
# Whenever you change a resource's ADDRESS in this module, you MUST add a
# matching `moved` block here in the SAME change. "Address" means any of:
#   - renaming a resource block label        (aws_lb.gateway -> aws_lb.alb)
#   - moving a resource into/out of a submodule
#   - adding/removing count/for_each on an existing resource
#       (aws_dynamodb_table.data -> aws_dynamodb_table.data[0], or to a
#        for_each key — both are address changes and both need a `moved`)
#   - changing a for_each KEY
#
# Renaming the PHYSICAL resource (e.g. a DynamoDB table `name`) is a DIFFERENT,
# unsafe operation that `moved` does NOT cover — physical names of stateful
# resources are immutable and changing them forces recreate. Keep physical
# names stable; vary them only through `var.pod_slug` / `var.name_prefix`
# (see main.tf locals), never by editing a literal.
#
# A `moved` block is permanent: keep it forever so customers who skipped
# intermediate versions still migrate cleanly when they eventually upgrade.
# `moved` blocks are no-ops once every deployment has passed through them, but
# we cannot know that for self-managed customers — so they stay.
#
# ─── VERIFY EVERY CHANGE ─────────────────────────────────────────────────────
#
# After adding a `moved` block, the plan must show the resource being MOVED
# (a "# ... has moved to ..." note), NOT destroyed+created. Validate against a
# real prior-version state before shipping.
#
# ─── ACTIVE MOVES ────────────────────────────────────────────────────────────
#
# None yet. The v1.x naming refactor (introducing var.pod_slug / var.name_prefix)
# changed only the VALUES interpolated into physical names, not any Terraform
# address, so it needs no `moved` block — it is a verified no-op for existing
# deployments.
#
# Add new entries below in this form, newest last, each tagged with the
# infra_version that introduced it:
#
#   # infra_version 1.3 — renamed the ALB resource for clarity
#   moved {
#     from = aws_lb.gateway
#     to   = aws_lb.alb
#   }

# infra_version 1.4 — pod identity is now generated unconditionally (no
# pod_id/hmac_secret override vars). The random_* resources were previously
# count-gated (random_id.pod_id[0]); de-index them so any deployment that had
# generated identity via the count path adopts the un-indexed address instead
# of destroying+recreating it. (A deployment that used the override path had no
# random_* in state at all, so for it these are simply created fresh — inert
# because the credentials secret is ignore_changes.)
moved {
  from = random_id.pod_id[0]
  to   = random_id.pod_id
}

moved {
  from = random_password.hmac_secret[0]
  to   = random_password.hmac_secret
}

# infra_version 1.5 — the registration secret is now generated-or-provided and
# always written (the count gate is gone), matching the pod-identity model. A
# deployment that wrote the version via the old count path tracked it at
# aws_secretsmanager_secret_version.registration[0]; de-index it so the existing
# (ignore_changes-frozen) value is re-homed to the un-indexed address instead of
# being destroyed+recreated. Verified intent: plan must show MOVED, not destroy.
moved {
  from = aws_secretsmanager_secret_version.registration[0]
  to   = aws_secretsmanager_secret_version.registration
}

# ECR repo gating (no infra_version bump — pure no-op refactor) — the ECR repo
# resources are now count-gated on var.manage_ecr_repo (default true) so an
# internal/owned same-account deployment can set it false and own NO ECR (the
# control plane owns the repo there). For every existing customer (manage_ecr_repo
# defaults true) the resources move to index [0]; de-index-FORWARD them so the
# existing repos + policies are re-homed, NOT destroyed+recreated. Verified intent:
# plan must show MOVED, not destroy, and no task-def change (INFRA_VERSION unchanged).
moved {
  from = aws_ecr_repository.gateway
  to   = aws_ecr_repository.gateway[0]
}

moved {
  from = aws_ecr_lifecycle_policy.gateway
  to   = aws_ecr_lifecycle_policy.gateway[0]
}

moved {
  from = aws_ecr_repository_policy.cross_account_push
  to   = aws_ecr_repository_policy.cross_account_push[0]
}

moved {
  from = aws_ecr_repository.gateway_replicated
  to   = aws_ecr_repository.gateway_replicated[0]
}

moved {
  from = aws_ecr_lifecycle_policy.gateway_replicated
  to   = aws_ecr_lifecycle_policy.gateway_replicated[0]
}

moved {
  from = aws_ecr_registry_policy.allow_control_plane_replication
  to   = aws_ecr_registry_policy.allow_control_plane_replication[0]
}
