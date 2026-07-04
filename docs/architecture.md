# CodeVine Gateway Terraform — Architecture (infra_version 2.0)

Clean-baseline rewrite. Two modules, one consistent naming scheme, BYO network,
pure-HCL cert callback. No pre-2.0 legacy is carried.

## Module layout

```
/                      root: composes account + gateway; provider; tfvars surface
  main.tf variables.tf outputs.tf versions.tf backend.tf
  imports.tf.example   templates for adopting existing stateful resources
modules/
  account/             applied ONCE per account (account/registry singletons)
    ecr.tf   - shared ECR repo + lifecycle + registry policy + cross-acct push role
    audit.tf - CloudTrail + GuardDuty
  gateway/             per-pod, fully name-isolated (many per account)
    main.tf        - data sources, core locals, tags
    network.tf     - VPC/subnets/NAT/routes (create-or-BYO)
    acm.tf         - wildcard cert + in-apply http callback + validation gate
    alb.tf         - ALB, SG, access-log bucket
    ecs.tf         - cluster, task SG, target group, task def, service
    autoscaling.tf - CPU + request target-tracking
    data.tf        - S3 payloads, DynamoDB, SQS
    secrets.tf     - registration secret + pod identity
    iam.tf         - exec/task/deployment/observability roles
    observability.tf - log group + upload metric filters
    waf.tf         - optional WAF (leaf module ../waf)
    moved.tf       - state-migration contract (no active moves at 2.0)
  waf/                 leaf module
```

**Why the split:** ECR repos (replication-path-coupled), the registry policy (one
per registry), the ECR push role (assumed by fixed name), and audit (CloudTrail /
GuardDuty are account+region singletons) are **account-scoped, not per-pod**.
Keeping them in the pod module forced `count`/`manage_ecr_repo` gating and naming
exceptions. `modules/account` owns them once; the pod module is 100% per-pod and
consumes `ecr_repo_url` + `ecr_push_role_arn` as inputs.

## Naming

Every physical resource: `cv-gw-{environment}-{pod_name}-{type}`. `cv-gw` carries
the gateway marker; `pod_name` is the sole per-pod token (validated so 32-char
ALB/target-group names never truncate); `customer` is a tag only. Account-shared
resources use `cv-gw-{env}-account-*` (audit) or the control-plane-coupled ECR
names (`codevine/{env}/gateway`, `codevine-gateway-ecr-push`).

## Deploy model — three coexistence cases

The account bootstrap has two scopes, gated independently, because they collide
differently: the **ECR repo** is per-ENVIRONMENT (`codevine/{env}/gateway`), while
the **registry policy + push role** and **audit** (CloudTrail/GuardDuty) are
per-ACCOUNT singletons.

- **First env in a fresh account:** `manage_account = true`, `manage_registry = true`,
  `enable_cloudtrail/guardduty = true` (all defaults). Creates the env repo + all
  singletons; the pod consumes the outputs.
- **Second ENVIRONMENT sharing one account** (e.g. stage in dev's account
  `366290348639`): `manage_account = true` (creates its own `codevine/stage/gateway`
  repo) + `manage_registry = false` + `enable_cloudtrail/guardduty = false` (reuse
  the first env's singletons — the registry policy already grants the whole project
  repo namespace, and there can be only one detector/registry policy per account).
- **Second POD in the same env + account:** `manage_account = false` +
  `ecr_repo_url` / `ecr_push_role_arn` from the first deployment's outputs.

Pods are fully name-isolated by `pod_name`, so any number coexist regardless.

## Onboarding auth (issue-first)

The cert-validation callback is Bearer-authed by the registration secret. Because
the control plane must already know that secret to validate the callback, a pod
that CREATES + validates its own cert (the default) **requires a CodeVine-minted
`registration_secret`** (issue-first). The self-generate path is only valid when a
pre-issued cert is supplied via `gateway_cert_arn` (no callback). The module
enforces this with a precondition.

## Cert callback

`data "http"` POSTs the ACM validation record to the control plane (Bearer-authed
by the registration secret); a `postcondition` fails apply on non-2xx. Pure HCL —
no shell/curl host dependency. Idempotent server-side; the validation gate polls
the cert to ISSUED.

## BYO network

Default builds its own VPC (2-AZ, single NAT). Set `vpc_id` + `public_subnet_ids`
+ `private_subnet_ids` to drop the pod into an existing VPC (shared/corporate/
backend network); all VPC/subnet/NAT/route resources are then skipped.

## Migration — reuse the existing S3 + DynamoDB via a one-time state move

Every env keeps its existing chat data by **moving the two data stores into the
new pod's state** — no copy, no recreate. The pod's compute/ALB/IAM/SQS/secrets
are new (cv-gw names); only the S3 payload bucket + DynamoDB table are adopted,
at their existing physical names.

- The module names those two resources via `s3_payload_bucket_name` /
  `dynamodb_table_name` (default = cv-gw scheme). Set them to the EXISTING names
  so the adoption plans as a no-op (a rename would force replace = data loss).
- Adopt them into this pod's state (`import`), then `terraform state rm` them from
  the old owned-1 stack so a later owned-1 teardown doesn't destroy them. Full
  runbook: `imports.tf.example`.

This is the same one-time operation for dev, stage, prod, and Luminary. Pre-2.0
deployments do not migrate via `moved` (other physical names changed) — but the
data never moves; the state pointer does.
