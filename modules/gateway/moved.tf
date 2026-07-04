# Gateway pod module — State Migration Contract (`moved` blocks)
#
# This module runs in the operator's own AWS account against state CodeVine cannot
# reach. Whenever a future change alters a resource's Terraform ADDRESS (renaming a
# block label, moving into/out of a submodule, adding/removing count/for_each, or
# changing a for_each key), add a matching `moved {}` block here IN THE SAME change
# so the operator's next apply silently re-homes state instead of destroy+create.
#
# `moved` covers ADDRESS changes only. Changing a stateful resource's PHYSICAL name
# (a bucket/table/secret name) forces recreate and is NOT `moved`-able — names
# derive from var.pod_name (local.name); never edit a literal.
#
# A `moved` block is permanent — keep it forever so operators who skip intermediate
# versions still migrate cleanly.
#
# Example:
#   # infra_version 2.1 — split the ALB into a submodule
#   moved {
#     from = aws_lb.gateway
#     to   = module.alb.aws_lb.this
#   }
#
# ── ACTIVE MOVES ─────────────────────────────────────────────────────────────
#
# None. infra_version 2.0 is the clean-baseline rewrite (account/pod split, new
# cv-gw-{env}-{pod_name} naming). Pre-2.0 deployments do not migrate via `moved`
# (physical names changed); they are rebuilt, or their stateful resources are
# adopted with `import` (see imports.tf.example). Add 2.x+ address-change moves
# below, newest last.
