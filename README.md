# CodeVine Dedicated Gateway

Terraform to run a **dedicated CodeVine gateway pod** entirely inside your own
AWS account. Your chat prompt and response data never leaves your account — the
gateway stores it in DynamoDB and S3 that you own.

## What this provisions (all in your account)

- VPC (2 AZs, single NAT), public + private subnets
- ECS Fargate cluster + autoscaling gateway service
- ECR repository (CodeVine pushes the gateway image here)
- Application Load Balancer + TLS certificate (ACM)
- DynamoDB table + S3 payload bucket (your chat data)
- SQS queues (inbound/outbound) for the observability channel
- IAM roles CodeVine assumes for deploys, image push, and observability
- Account-level CloudTrail (+ log bucket) and a GuardDuty detector
  (defaults on — see [Audit logging & threat detection](#audit-logging--threat-detection))

The only outbound dependencies on CodeVine are: the control-plane URL (the
gateway heartbeats/registers there), the control-plane account ID (trust
principal for the cross-account roles), and a registration secret.

## Prerequisites

- Terraform >= 1.5
- An AWS CLI profile with admin in the account you're deploying into
- An S3 bucket + DynamoDB table **in your account** for Terraform remote state
- The following values from CodeVine onboarding:
  - `customer` (your assigned identifier, e.g. `acme`)
  - `control_plane_account_id`
  - `control_plane_url`
  - `registration_secret` (sensitive)

## Setup

> The committed `.terraform.lock.hcl` pins exact provider versions — keep it.
> Your `backend.hcl`, `terraform.tfvars`, and `*.tfstate` are gitignored and
> must never be committed (they hold account-specific and secret values).

1. **Configure remote state.** Create `backend.hcl`:

   ```hcl
   bucket         = "mycompany-codevine-gateway-tfstate"
   key            = "gateway/terraform.tfstate"
   region         = "us-east-1"
   dynamodb_table = "mycompany-codevine-gateway-tflocks"
   encrypt        = true
   ```

2. **Configure variables.** Copy and edit:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # edit terraform.tfvars
   export TF_VAR_registration_secret='<secret from CodeVine>'
   ```

3. **Init:**

   ```bash
   terraform init -backend-config=backend.hcl
   ```

### First apply is two-phase (one time only)

The TLS certificate for `{customer}.gateway.codevine.ai` is DNS-validated, and
that DNS lives in **CodeVine's** zone — not yours. So the **first** apply pauses
partway through, waiting for CodeVine to add the validation record. This is
expected and happens only once.

1. **Start the apply.** It provisions most resources, then **blocks** on
   certificate validation (up to `cert_validation_timeout`, default 45m):

   ```bash
   terraform apply
   # ... creating ... then waits at:
   # module.gateway.aws_acm_certificate_validation.gateway: Still creating...
   ```

2. **In a second terminal, grab the hand-off values and send them to CodeVine:**

   ```bash
   terraform output -json dns_validation_for_codevine
   terraform output -raw alb_dns_name
   ```

   CodeVine adds the ACM validation CNAME and points
   `{customer}.gateway.codevine.ai` at your ALB.

3. **The blocked apply unblocks automatically** once the certificate reaches
   `ISSUED` (usually a few minutes after CodeVine adds the record) and finishes.

Your gateway is then live at `https://{customer}.gateway.codevine.ai`.

> If the apply hits the validation timeout before CodeVine adds the record, it
> errors out cleanly — just re-run `terraform apply` once the record is in place
> and it resumes.

### Every subsequent apply is single-phase

After the certificate is issued once, validation is a no-op. Changing sizing
(`desired_count`, `gateway_cpu`, …) or networking is a normal single `terraform
apply` with no waiting and no CodeVine involvement. (The two-phase flow only
recurs if the certificate is ever replaced — e.g. a domain change — which does
not happen for a fixed `{customer}.gateway.codevine.ai` hostname.)

> You do **not** need any access to CodeVine's AWS account, and CodeVine does
> not need standing credentials into yours — they only assume the scoped IAM
> roles this Terraform creates (deploy, image push, observability).

## Updating

There are two kinds of update, handled differently:

- **Application (gateway image) updates** — CodeVine pushes new gateway images
  and rolls deployments via the cross-account roles. These need **no action from
  you**; nothing to re-apply.
- **Infrastructure updates** — changes shipped in new Terraform (ALB settings,
  timeouts, networking, IAM). The control plane **cannot** apply these for you —
  they take effect only when you re-run `terraform apply` against the updated
  module. CodeVine signals an infra update by bumping `infra_version` (surfaced
  to the running gateway as `INFRA_VERSION`); pull the latest module and
  `terraform apply` when it changes. See the [Changelog](#changelog) for what
  each version contains.

Aside from those, you generally won't need to re-run Terraform except to change
sizing (`desired_count`, `gateway_cpu`, …).

## Data retention

By default the gateway **retains your chat source data forever** — the
request/response payloads in S3 and the items in DynamoDB are never auto-deleted.
If your data-governance policy requires a fixed retention window, set
`source_data_retention_days` to enable **hard, AWS-enforced deletion**:

```hcl
source_data_retention_days = 90   # 0 = retain forever (default)
```

When set to a value > 0, a single `terraform apply` makes AWS expire the data
across every store, with no application involvement:

- **DynamoDB** — the gateway stamps a TTL (`ExpiresAt`) on each record; AWS
  deletes expired items automatically. An **active session's** record has its TTL
  **slid forward on every new request**, so a conversation you're still using is
  never deleted mid-life — the clock starts from its *last* activity, not its
  first.
- **S3 payloads** — both current objects and prior (noncurrent) versions expire
  at the same age. (The bucket is versioned, so expiring only the current version
  would leave old copies behind — both are removed for a true delete.)
- **Gateway logs** — CloudWatch log retention is capped so logs never outlive the
  data window (rounded down to the nearest CloudWatch-supported value).

This lever controls **raw source data only**. Derived analytics metadata that
CodeVine keeps (counts, costs, titles — never your prompt/response content, per
the data-bastion model) has its own lifecycle and is unaffected.

> **Caveat — DynamoDB Point-In-Time Recovery (PITR).** The data table has PITR
> enabled as an operational safety net, which retains up to **35 days** of
> continuous backups *independently* of the TTL above. If you need a strict
> guarantee that data is unrecoverable after fewer than 35 days, also disable
> PITR (`point_in_time_recovery` in `modules/gateway/service.tf`). It is left on
> by default because most retention policies (≥ 35 days) are unaffected by it.

Lowering or raising the value later is a normal `terraform apply`; AWS applies
the new lifecycle going forward. Setting it back to `0` stops new expirations
(items already past their stamped TTL may still be reaped by AWS).

## Audit logging & threat detection

This Terraform provisions, **on by default**, an account-level audit baseline so
the account is self-sufficient once it is independent of any AWS Organization:

- **CloudTrail** — a multi-region trail with log-file validation, writing to a
  dedicated, encrypted, private S3 bucket in your account
  (`{customer}-...-cloudtrail-{account_id}`, logs expire after
  `cloudtrail_retention_days`, default 365).
- **GuardDuty** — a standalone detector for the account.

Disable either if you centralize it elsewhere (e.g. via your own AWS
Organization):

```hcl
enable_cloudtrail = false
enable_guardduty  = false
```

Outputs `cloudtrail_bucket` and `guardduty_detector_id` report what was created.

### GuardDuty: importing a pre-existing detector

AWS allows only **one** GuardDuty detector per account per region. If the
account already has a detector — common when it was previously a member of a
parent organization's GuardDuty — a plain `terraform apply` with
`enable_guardduty = true` will **fail with a conflict**.

Two ways to handle it:

1. **Import the existing detector** (keeps its history):

   ```bash
   # find the detector id
   aws guardduty list-detectors --region us-east-1
   terraform import 'module.audit.aws_guardduty_detector.main[0]' <detector-id>
   terraform apply
   ```

2. **Defer until the detector is yours alone.** Apply with
   `enable_guardduty = false` first; once the account has left any parent
   organization (so no conflicting detector remains), set it back to `true` and
   either import (option 1) or let Terraform create a fresh one.

CloudTrail has no such constraint — the account does not start with its own
trail, so it is always created cleanly.

## Teardown

ALB deletion protection is on by default. To destroy:

```bash
terraform apply -var=enable_deletion_protection=false   # disable protection first
terraform destroy
```

Notify CodeVine before teardown so they can remove the DNS records on their
side.

> The CloudTrail log bucket is created with `force_destroy = false` so audit
> logs are not deleted by accident. If you intend to discard the logs too, empty
> the bucket (or temporarily set `force_destroy = true` on it) before
> `terraform destroy`. If you imported a pre-existing GuardDuty detector,
> `terraform destroy` will disable it — `terraform state rm` it first if you want
> the detector to survive teardown.

## Changelog

Tracks the `infra_version` stamp (semver). A bump *usually* means the Terraform
changed in a way that requires a customer `terraform apply` to take effect — see
[Updating](#updating). Entries that need no apply say so explicitly. Newest first.

### 1.4

- **Internal hardening — no customer action required.** Pod identity
  (`GATEWAY_POD_ID` / `GATEWAY_HMAC_SECRET`) is now always generated on first
  apply and **owned entirely in your account's Secrets Manager** — there are no
  longer any identity override inputs. Identity is frozen on creation
  (`ignore_changes`) and never regenerated, matching the control plane's
  write-once HMAC. No-op for existing deployments (identity already present in
  Secrets Manager is preserved untouched).

### 1.3

- **Internal hardening — no customer action required.** Naming is now
  parameterized (`pod_slug` / `name_prefix`, both defaulting to the existing
  scheme) so resource names can evolve without recreating data, and a `moved {}`
  migration contract (`modules/gateway/moved.tf`) lets future structural changes
  re-home Terraform state automatically on the next apply instead of forcing a
  manual `state mv`. This version is a **no-op for existing deployments** —
  `terraform plan` shows no changes attributable to it.

### 1.2

- **Optional hard data retention** via `source_data_retention_days` (default
  `0` = retain forever, so existing deployments are unchanged). When set, AWS
  auto-expires raw chat source data: DynamoDB items (with active-session TTLs
  sliding forward on use), S3 payloads (current **and** noncurrent versions), and
  gateway log retention capped to match. Apply this version if you need a fixed,
  AWS-enforced retention window. See [Data retention](#data-retention) — note the
  DynamoDB PITR (35-day backup) caveat.

### 1.1

- **ALB `idle_timeout` 300s → 600s.** The gateway aborts a stalled upstream
  stream after 300s of inactivity; the ALB idle timeout must sit strictly above
  that so the gateway's own timer fires first, producing a clean error (and
  partial token capture) instead of an opaque ALB 504. Apply this version to
  stop long, actively-streaming responses from being cut at the 5-minute mark.

### 1.0

- Initial dedicated gateway: VPC, ECS cluster, ECR, ALB, ACM cert, gateway pod
  (ECS service, SQS, DynamoDB, S3, IAM, autoscaling), and the account audit
  baseline (CloudTrail + GuardDuty).
