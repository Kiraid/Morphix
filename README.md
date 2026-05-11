# Morphix — Serverless Image Converter

Convert images between many formats in the browser: no accounts, no watermarks, and objects are removed automatically after the configured retention window.

**Stack:** Go · AWS Lambda (zip + container) · API Gateway HTTP · S3 · CloudFront · SQS · IoT Core · DynamoDB · ECR · Terraform · FFmpeg · Docker

---

## Architecture

```
Browser (CloudFront)
    │
    │  POST /presign  →  API Gateway  →  Presign Lambda (Go, zip)
    │       ← request_id + presigned S3 PUT URLs
    │
    │  PUT files  →  S3 uploads/{request_id}/
    │
    │  MQTT over WSS  ←  IoT Core topic morphix/jobs/{request_id}
    │       (CONNECT uses client_id from POST /iot-auth signed URL)
    │
    │  S3 ObjectCreated → SQS (delay + DLQ) → Processor Lambda (Go + FFmpeg, container)
    │       → converted ZIP + DynamoDB + publish completion on IoT
    │
    │  Frontend receives job-done payload → presigned GET → download
    │
    S3 lifecycle deletes uploads + converted after retention_days
```

### AWS services

| Service | Role |
|--------|------|
| S3 + CloudFront (OAC) | Static UI, uploads, converted ZIPs; no public bucket browsing |
| API Gateway | `POST /presign`, `POST /iot-auth` |
| Lambda (provided.al2023) | Presign + IoT custom-authorizer style URL helper |
| Lambda (container / ECR) | FFmpeg conversion, parallel goroutines, ZIP, IoT publish |
| SQS | Buffer S3 notifications, retries, DLQ |
| IoT Core | Push job status to the browser over MQTT |
| DynamoDB | Job metadata + TTL cleanup |
| Terraform | Full IaC |

---

## Repo layout

```
morphix/
├── frontend/           # Static site (HTML/CSS/JS)
├── backend/
│   ├── cmd/presign/    # Presigned URLs + job row in DynamoDB
│   ├── cmd/iot-auth/   # SigV4-aligned presigned WSS URL for IoT
│   ├── cmd/processor/  # SQS consumer: convert, zip, notify
│   ├── Dockerfile      # Processor image (bootstrap at /var/runtime/bootstrap)
│   └── go.mod          # Go 1.26
├── terraform/          # Root module + modules (s3, cloudfront, lambda, …)
├── scripts/
│   └── ci-frontend-inject.sh   # Patch CONFIG in app.js from terraform output
└── Makefile            # Local build / tf / frontend helpers
```

---

## Prerequisites

- AWS CLI configured for the account that holds state and workloads
- Terraform `>= 1.7`
- Go **1.26** (see `backend/go.mod`)
- Docker (for the processor image)

---

## Local deploy (happy path)

```bash
make tf-init
make build-lambdas
make build-docker
make tf-apply          # creates ECR among other resources
make push-docker       # push :latest so Terraform can resolve digest
make tf-apply          # pick up new ECR image digest + any code changes
make frontend-deploy   # inject URLs from outputs, sync S3, invalidate CloudFront
```

Tear down: `make tf-destroy`

Logs: `make logs-presign`, `make logs-iot-auth`, `make logs-processor`

---

## How the important pieces work

**Presigned PUT** — The API never receives file bytes; the browser uploads straight to S3, avoiding API Gateway payload limits.

**SQS in front of the processor** — A short queue delay lets parallel PUTs land before conversion starts; failed invokes can retry before the DLQ.

**Parallel FFmpeg** — The processor downloads and converts with bounded concurrency so a single Lambda invocation can handle multi-file jobs without thrashing.

**IoT instead of polling** — The UI subscribes to `morphix/jobs/{request_id}` before uploading so it does not miss the completion message. `/iot-auth` returns a SigV4-signed WebSocket URL compatible with AWS IoT expectations.

**Immutable deploys for the container** — Terraform pins the processor Lambda to an **ECR image digest** (via `aws_ecr_image`), so pushing a new `:latest` and re-applying rolls the function reliably.

---

## CI/CD (GitHub Actions)

On push to `main` (filtered paths), `.github/workflows/deploy.yml`:

1. **Detect** which areas changed (`presign`, `iot-auth`, `processor`, `go` deps, `terraform`, `frontend`).
2. **infra-plan** — Build zip Lambdas into `backend/dist/…`; if processor or Go deps changed, build and push the Docker image to ECR; run `terraform plan` and upload the plan artifact; post a text summary to the job summary.
3. **infra-apply** — Runs only after **manual approval** on the GitHub Environment named `production` (configure reviewers under *Settings → Environments*). Applies the saved plan with `terraform apply tfplan`.
4. **deploy-frontend** — If `frontend/**` changed, runs independently: `terraform init` for outputs, `scripts/ci-frontend-inject.sh`, `aws s3 sync`, CloudFront invalidation.

Optional repo **variable** `MORPHIX_TERRAFORM_ENV` (`dev` / `staging` / `prod`). **Run workflow** from the Actions tab lets you set `terraform_environment`, optionally **sync frontend** without a commit under `frontend/`, and optionally **rebuild the processor image** on a manual run.

---

## Roadmap ideas

- Custom domain (Route 53 + ACM)
- Cognito for authenticated tiers and abuse controls
- CloudWatch dashboard + alarms
- WAF in front of CloudFront

---

*Faizan Akhtar · [GitHub](https://github.com/faizan-akhtar)*
