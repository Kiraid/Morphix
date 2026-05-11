# Morphix — local build & deploy helpers
# Requires: AWS CLI, Terraform (>= 1.7), Go (see backend/go.mod), Docker (for processor image)

REGION  ?= us-east-1
ENV     ?= dev
ACCOUNT := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
ECR_URI := $(shell cd terraform && terraform output -raw ecr_repository_url 2>/dev/null || echo "")

.PHONY: help all build-lambdas build-docker push-docker tf-init tf-plan tf-apply tf-destroy frontend-deploy clean

## ── HELP ───────────────────────────────────────────────────────────
help:
	@echo "Morphix — useful targets"
	@echo ""
	@echo "  make build-lambdas     Build presign + iot-auth Lambda binaries (Linux) into backend/dist/"
	@echo "  make build-docker      Build the processor Docker image (FFmpeg + Go)"
	@echo "  make push-docker       Push processor image to ECR (needs terraform outputs + Docker login)"
	@echo "  make tf-init           terraform init (remote state)"
	@echo "  make tf-plan           terraform plan (ENV=$(ENV), REGION=$(REGION))"
	@echo "  make tf-apply          terraform apply (auto-approve; use in dev only)"
	@echo "  make frontend-deploy   Inject API URLs from Terraform outputs, sync frontend/ to S3, invalidate CloudFront"
	@echo "  make all               build-lambdas → build-docker → push-docker → tf-apply → frontend-deploy"
	@echo "  make clean             Remove local build artifacts and Terraform state dirs (destructive)"
	@echo ""
	@echo "Environment: ENV=$(ENV)  REGION=$(REGION)"

## ── FULL STACK (local / scripted deploy) ───────────────────────────
all: build-lambdas build-docker push-docker tf-apply frontend-deploy
	@echo "Morphix deploy sequence finished."

## ── GO LAMBDAS (zip packaging is done by Terraform archive_file) ───
build-lambdas:
	@echo "Building presign + iot-auth Lambda binaries for Linux…"
	@mkdir -p backend/dist/presign backend/dist/iot-auth
	cd backend && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build -ldflags="-s -w" -o dist/presign/bootstrap ./cmd/presign
	cd backend && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build -ldflags="-s -w" -o dist/iot-auth/bootstrap ./cmd/iot-auth
	@echo "Done. Terraform will zip these when you run terraform apply/plan."

## ── PROCESSOR (Docker / ECR) ───────────────────────────────────────
build-docker:
	@echo "Building processor image…"
	cd backend && docker build -t morphix-processor:latest .
	@echo "Image tagged morphix-processor:latest"

push-docker: build-docker
	@if [ -z "$(ECR_URI)" ]; then echo "Error: ECR URI not found. Run terraform apply first (outputs ecr_repository_url)."; exit 1; fi
	@if [ -z "$(ACCOUNT)" ]; then echo "Error: AWS CLI not configured (aws sts get-caller-identity)."; exit 1; fi
	@echo "Logging in to ECR and pushing $(ECR_URI):latest …"
	aws ecr get-login-password --region $(REGION) | \
		docker login --username AWS --password-stdin $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com
	docker tag morphix-processor:latest $(ECR_URI):latest
	docker push $(ECR_URI):latest
	@echo "Push complete."

## ── TERRAFORM ───────────────────────────────────────────────────────
tf-init:
	cd terraform && terraform init

tf-plan:
	cd terraform && terraform plan \
		-var="environment=$(ENV)" -var="aws_region=$(REGION)"

tf-apply:
	cd terraform && terraform apply -auto-approve \
		-var="environment=$(ENV)" -var="aws_region=$(REGION)"

tf-destroy:
	cd terraform && terraform destroy \
		-var="environment=$(ENV)" -var="aws_region=$(REGION)"

## ── FRONTEND (S3 + CloudFront) ───────────────────────────────────────
# Reads live API + IoT endpoints from Terraform outputs and rewrites CONFIG in app.js before sync.
frontend-deploy:
	@echo "Reading Terraform outputs…"
	$(eval BUCKET  := $(shell cd terraform && terraform output -raw s3_bucket_name))
	$(eval CF_ID   := $(shell cd terraform && terraform output -raw cloudfront_id))
	$(eval CF_URL  := $(shell cd terraform && terraform output -raw cloudfront_url))
	@echo "Patching frontend/app.js CONFIG (API + IoT)…"
	@bash scripts/ci-frontend-inject.sh
	@echo "Syncing frontend/ → s3://$(BUCKET)/ …"
	aws s3 sync frontend/ s3://$(BUCKET)/ \
		--exclude "*.DS_Store" \
		--cache-control "public, max-age=3600" \
		--region $(REGION)
	aws s3 cp frontend/index.html s3://$(BUCKET)/index.html \
		--cache-control "public, max-age=60" \
		--region $(REGION)
	@echo "Invalidating CloudFront $(CF_ID)…"
	aws cloudfront create-invalidation \
		--distribution-id $(CF_ID) \
		--paths "/index.html" "/app.js" "/style.css" "/*" \
		--region $(REGION)
	@echo "Frontend deployed: $(CF_URL)"

## ── LOGS ─────────────────────────────────────────────────────────────
logs-presign:
	aws logs tail /aws/lambda/morphix-$(ENV)-presign --follow --region $(REGION)

logs-processor:
	aws logs tail /aws/lambda/morphix-$(ENV)-processor --follow --region $(REGION)

logs-iot-auth:
	aws logs tail /aws/lambda/morphix-$(ENV)-iot-auth --follow --region $(REGION)

## ── CLEAN ───────────────────────────────────────────────────────────
clean:
	rm -rf backend/dist terraform/.terraform terraform/terraform.tfstate*
