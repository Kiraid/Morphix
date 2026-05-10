# Morphix — Serverless Image Converter

> Convert images between 10+ formats instantly. No accounts, no watermarks. Files auto-deleted after 24 hours.

**Tech stack:** Go · AWS Lambda · S3 · CloudFront · SQS · IoT Core · DynamoDB · ECR · Terraform · FFmpeg · Docker

---

## Architecture

```
Browser (CloudFront URL)
    │
    │  1. POST /presign  →  [API Gateway]  →  [Presign Lambda (Go)]
    │     ← request_id + presigned S3 PUT URLs
    │
    │  2. PUT files directly → [S3: uploads/{request_id}/]
    │
    │  3. Subscribe WSS → [IoT Core MQTT topic: morphix/jobs/{request_id}]
    │
    │                    S3 ObjectCreated event
    │                         ↓
    │                      [SQS Queue]  (5s delay, DLQ after 3 retries)
    │                         ↓
    │              [Processor Lambda (Go + FFmpeg, Docker/ECR)]
    │                ├── Goroutine: download + convert image 1
    │                ├── Goroutine: download + convert image 2
    │                ├── ...parallel (semaphore: 4 concurrent)
    │                ├── Build ZIP
    │                ├── Upload to S3: converted/{request_id}/result.zip
    │                ├── Update DynamoDB: status=DONE, download_url=...
    │                └── Publish to IoT Core → topic: morphix/jobs/{request_id}
    │
    │  4. IoT MQTT message received → show download button
    │     ← presigned S3 GET URL (24h expiry)
    │
    [S3 Lifecycle Policy: delete uploads/ + converted/ after 24h]
```

### AWS Services Used

| Service | Purpose |
|---|---|
| S3 | File storage (uploads + converted), static site hosting |
| CloudFront + OAC | CDN, HTTPS, blocks direct S3 access |
| API Gateway | REST API for presign + status + IoT auth |
| Lambda (Go, zip) | Presign URL generation, status polling, IoT auth |
| Lambda (Go, Docker/ECR) | Image conversion with FFmpeg in goroutines |
| SQS | Decoupling S3 events from Lambda, buffering, retry/DLQ |
| IoT Core (MQTT) | Real-time push notification to browser |
| DynamoDB | Job state tracking with TTL auto-cleanup |
| ECR | Docker image registry for processor Lambda |
| CloudWatch | Lambda logs, metrics |
| Terraform | Full IaC for all resources |

---

## Project Structure

```
morphix/
├── frontend/
│   ├── index.html       # Static site
│   ├── style.css        # Full design system
│   └── app.js           # Upload flow, MQTT, presigned URLs
│
├── backend/
│   ├── cmd/
│   │   ├── presign/     # Lambda: generates presigned URLs, stores job in DDB
│   │   ├── processor/   # Lambda: FFmpeg conversion, ZIP, IoT notification
│   │   ├── status/      # Lambda: polling fallback (GET /status/{id})
│   │   └── iot-auth/    # Lambda: returns signed WSS URL for IoT Core
│   ├── Dockerfile       # Multi-stage: Go build + FFmpeg static binary
│   └── go.mod
│
└── terraform/
    ├── main.tf          # Root module — wires everything
    ├── variables.tf
    ├── outputs.tf
    └── modules/
        ├── s3/          # Bucket, lifecycle, CORS, OAC policy
        ├── cloudfront/  # Distribution, OAC, cache behaviors
        ├── lambda/      # All 4 Lambda functions
        ├── api-gateway/ # REST API with CORS
        ├── sqs/         # Queue + DLQ
        ├── iot/         # IoT policy + endpoint
        ├── dynamodb/    # Jobs table with TTL
        ├── ecr/         # Container registry
        └── iam/         # Least-privilege roles for each Lambda
```

---

## Quick Start

### Prerequisites
- AWS CLI configured (`aws configure`)
- Terraform >= 1.7
- Go >= 1.22
- Docker

### Deploy

```bash
# 1. Initialize Terraform
make tf-init

# 2. Build Lambda binaries + Docker image
make build-lambdas build-docker

# 3. Provision AWS infrastructure
make tf-apply

# 4. Push Docker image to ECR
make push-docker

# 5. Deploy frontend to S3
make frontend-deploy
```

### Tear down
```bash
make tf-destroy
```

### Tail logs
```bash
make logs-processor   # watch FFmpeg conversions live
make logs-presign     # watch presign Lambda
```

---

## Supported Formats

**Input:** JPG, PNG, WEBP, GIF, BMP, TIFF, AVIF, HEIC, HEIF  
**Output:** JPEG, PNG, WEBP, AVIF, BMP, TIFF, GIF

---

## Key Design Decisions

**Direct S3 upload via presigned URLs** — Files never pass through API Gateway (10MB body limit). Browser uploads directly to S3. Presigned URLs are generated only on Convert click, not page load, to keep the expiry window tight.

**SQS between S3 and Lambda** — A 5-second SQS `DelaySeconds` gives all parallel uploads time to land before the processor starts. `maxReceiveCount: 3` retries failed conversions before routing to the DLQ.

**File count check before processing** — The processor Lambda verifies that the number of objects in the S3 prefix matches the expected count from DynamoDB before starting conversion. If not all files have arrived yet, it returns an error and SQS retries.

**Goroutines for parallel conversion** — Each image is downloaded and converted concurrently with a semaphore limiting max 4 FFmpeg processes to avoid Lambda CPU thrashing.

**IoT Core MQTT for real-time notifications** — The processor publishes to `morphix/jobs/{request_id}`. The frontend subscribes before uploading, so it never misses the completion event. A polling fallback (`GET /status/{id}`) handles IoT connection failures.

**DynamoDB TTL** — Job records are auto-deleted 24 hours after creation. S3 lifecycle policies handle file cleanup independently.

---

## Phase 2 Roadmap

- [ ] Custom domain via Route 53 + ACM (adds `aws_route53_record`, `aws_acm_certificate`)
- [ ] Cognito user pool — accounts, rate limiting (5 files anon / 10 files logged in)
- [ ] CloudWatch dashboard — Lambda duration, S3 PUT count, error rate
- [ ] WAF on CloudFront — IP rate limiting, geo-blocking
- [ ] GitHub Actions CI/CD — auto-build and deploy on push to main

---

*Built by Faizan Akhtar · [GitHub](https://github.com/faizan-akhtar)*
