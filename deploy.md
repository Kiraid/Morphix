# Deploying Morphix

This document matches the **Makefile**, **Terraform** layout, and **GitHub Actions** workflow in the repo. There is no separate “status” API: the browser uses **MQTT on IoT Core** for job completion.

---

## 1. One-time prerequisites

- AWS account and CLI credentials (`aws sts get-caller-identity`).
- An S3 bucket and DynamoDB table for **remote Terraform state** already match `terraform/main.tf` `backend "s3"` (or change that block to your bucket/key before the first `terraform init`).
- **GitHub Actions** (optional): repository secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. Create an environment **`production`** with required reviewers so `infra-apply` waits for manual approval after a plan.

---

## 2. Lambda zip binaries (presign + iot-auth)

Terraform’s `archive_file` data sources read fixed paths under the repo:

- `backend/dist/presign/bootstrap`
- `backend/dist/iot-auth/bootstrap`

Generate them locally:

```bash
make build-lambdas
```

Or the equivalent `go build` commands from the Makefile / workflow.

---

## 3. Processor container (ECR)

The processor runs as a **Lambda container** image built from `backend/Dockerfile` (bootstrap at `/var/runtime/bootstrap`).

After the first `terraform apply` (or whenever ECR exists):

```bash
make push-docker
```

That tags and pushes to `terraform output -raw ecr_repository_url` with tag `:latest`. Terraform resolves the **image digest** so the next `terraform apply` updates the Lambda when the image changes.

---

## 4. Terraform

Variables live in `terraform/variables.tf` (`environment`, `aws_region`, `file_retention_days`). Optional `terraform/terraform.tfvars`:

```hcl
aws_region          = "us-east-1"
environment         = "dev"
file_retention_days = 1
```

Commands:

```bash
make tf-init
make tf-plan    # or: cd terraform && terraform plan -var="environment=dev" …
make tf-apply     # auto-approve; use with care outside dev
```

---

## 5. Frontend (S3 + CloudFront)

`frontend/app.js` contains placeholder `window.MORPHIX_*` values. **`make frontend-deploy`** and **`scripts/ci-frontend-inject.sh`** rewrite them from Terraform outputs (`api_gateway_url`, `iot_endpoint`), then sync to the site bucket and invalidate CloudFront (see Makefile for cache headers and paths).

Manual equivalent:

```bash
cd terraform && terraform init -input=false
cd .. && bash scripts/ci-frontend-inject.sh
# then aws s3 sync … and cloudfront create-invalidation using outputs:
#   terraform output -raw s3_bucket_name
#   terraform output -raw cloudfront_id
```

---

## 6. GitHub Actions flow

File: `.github/workflows/deploy.yml`.

| Change under | What runs |
|--------------|-----------|
| `backend/cmd/presign/**`, `iot-auth/**`, `processor/**`, `go.mod` / `go.sum`, `terraform/**` | `infra-plan` (build zips; build/push image when processor or Go deps change; `terraform plan`; artifact). Then **`infra-apply`** after approval on environment **`production`**. |
| `frontend/**` | `deploy-frontend` in parallel (no dependency on Terraform apply): init for outputs → inject script → `s3 sync` → invalidation. |

Push to `main` is limited by `on.push.paths` in the workflow file. **Actions → Deploy Morphix → Run workflow** always runs **infra-plan** (and then **infra-apply** after approval) even when no paths changed—useful for re-applying without a dummy commit. Manual inputs:

| Input | Purpose |
|--------|---------|
| `terraform_environment` | Passed to Terraform as `var.environment`. |
| `sync_frontend` | When true, runs the frontend job (inject + S3 + invalidation) even if `frontend/**` did not change. |
| `rebuild_processor_image` | When true on a manual run, builds and pushes the processor Docker image before `terraform plan`. |

---

## 7. Smoke checks

```bash
API="$(terraform -chdir=terraform output -raw api_gateway_url)"
curl -sS -X POST "${API}/presign" \
  -H "Content-Type: application/json" \
  -d '{"files":[{"name":"test.jpg","size":1000,"type":"image/jpeg"}],"target_format":"PNG"}'
```

Open `terraform output -raw cloudfront_url` in a browser and run a small conversion.
