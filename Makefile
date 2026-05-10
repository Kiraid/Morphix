REGION   ?= us-east-1
ENV      ?= dev
ACCOUNT  := $(shell aws sts get-caller-identity --query Account --output text)
ECR_REPO := $(shell cd terraform && terraform output -raw ecr_repository_url 2>/dev/null || echo "")

.PHONY: all build-lambdas build-docker push-docker tf-init tf-plan tf-apply deploy frontend-deploy clean

## ── FULL DEPLOY ────────────────────────────────────────────────────
all: build-lambdas build-docker push-docker tf-apply frontend-deploy
	@echo "✅ Morphix deployed!"

## ── BUILD GO LAMBDAS ───────────────────────────────────────────────
build-lambdas:
	@echo "→ Building presign Lambda..."
	@mkdir -p backend/dist/presign backend/dist/status backend/dist/iot-auth
	cd backend && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build -ldflags="-s -w" -o dist/presign/bootstrap ./cmd/presign
	cd backend && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build -ldflags="-s -w" -o dist/status/bootstrap ./cmd/status
	cd backend && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
		go build -ldflags="-s -w" -o dist/iot-auth/bootstrap ./cmd/iot-auth
	@echo "✅ Lambda binaries built"

## ── BUILD + PUSH DOCKER IMAGE ──────────────────────────────────────
build-docker:
	@echo "→ Building processor Docker image..."
	cd backend && docker build -t morphix-processor:latest .
	@echo "✅ Docker image built"

push-docker: build-docker
	@echo "→ Pushing to ECR..."
	aws ecr get-login-password --region $(REGION) | \
		docker login --username AWS --password-stdin $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com
	docker tag morphix-processor:latest $(ECR_REPO):latest
	docker push $(ECR_REPO):latest
	@echo "✅ Image pushed to ECR"

## ── TERRAFORM ──────────────────────────────────────────────────────
tf-init:
	cd terraform && terraform init

tf-plan:
	cd terraform && terraform plan -var="environment=$(ENV)" -var="aws_region=$(REGION)"

tf-apply:
	cd terraform && terraform apply -auto-approve \
		-var="environment=$(ENV)" -var="aws_region=$(REGION)"

tf-destroy:
	cd terraform && terraform destroy \
		-var="environment=$(ENV)" -var="aws_region=$(REGION)"

## ── DEPLOY FRONTEND ────────────────────────────────────────────────
# Injects Terraform outputs into frontend config and uploads to S3
frontend-deploy:
	@echo "→ Reading Terraform outputs..."
	$(eval API_BASE    := $(shell cd terraform && terraform output -raw api_gateway_url))
	$(eval IOT_WS      := wss://$(shell cd terraform && terraform output -raw iot_endpoint)/mqtt)
	$(eval IOT_AUTH    := $(API_BASE)/iot-auth)
	$(eval BUCKET      := $(shell cd terraform && terraform output -raw s3_bucket_name))
	$(eval CF_ID       := $(shell cd terraform && terraform output -json | jq -r '.cloudfront_url.value'))

	@echo "→ Injecting config into frontend..."
	@cp frontend/app.js /tmp/app.js
	@sed -i \
		-e 's|window.MORPHIX_API_BASE.*||' \
		-e 's|"https://YOUR_API_GW_ID.*"|"$(API_BASE)"|' \
		frontend/app.js

	@echo "→ Uploading frontend to S3..."
	aws s3 sync frontend/ s3://$(BUCKET)/  \
		--exclude "*.DS_Store" \
		--cache-control "public, max-age=3600" \
		--region $(REGION)

	# HTML files: short cache
	aws s3 cp frontend/index.html s3://$(BUCKET)/index.html \
		--cache-control "public, max-age=60" \
		--region $(REGION)

	@echo "→ Invalidating CloudFront cache..."
	aws cloudfront create-invalidation \
		--distribution-id $(shell cd terraform && terraform output -raw cloudfront_distribution_id 2>/dev/null || echo "DIST_ID") \
		--paths "/*"

	@echo "✅ Frontend deployed!"
	@echo "🌍 URL: $(CF_ID)"

## ── UTILS ──────────────────────────────────────────────────────────
logs-presign:
	aws logs tail /aws/lambda/morphix-$(ENV)-presign --follow --region $(REGION)

logs-processor:
	aws logs tail /aws/lambda/morphix-$(ENV)-processor --follow --region $(REGION)

clean:
	rm -rf backend/dist terraform/.terraform terraform/terraform.tfstate*
