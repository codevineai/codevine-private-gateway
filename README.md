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

CodeVine pushes new gateway images and rolls deployments via the cross-account
roles. You generally won't need to re-run Terraform except to change sizing
(`desired_count`, `gateway_cpu`, …) or networking.

## Teardown

ALB deletion protection is on by default. To destroy:

```bash
terraform apply -var=enable_deletion_protection=false   # disable protection first
terraform destroy
```

Notify CodeVine before teardown so they can remove the DNS records on their
side.
