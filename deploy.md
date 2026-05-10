🎯 Step-by-Step Deployment
Step 1: Prepare Backend
bash
# Build all Lambda functions
cd backend
 
# ZIP lambdas
GOOS=linux GOARCH=amd64 go build -o dist/presign/bootstrap ./cmd/presign
GOOS=linux GOARCH=amd64 go build -o dist/iot-auth/bootstrap ./cmd/iot-auth
 
# Create ZIPs
cd dist/presign && zip -r presign.zip bootstrap && mv ../../presign.zip .
cd ../iot-auth && zip -r iot-auth.zip bootstrap && mv ../../iot-auth.zip .

Step 2: Deploy Infrastructure
bash
cd terraform
 
# Initial deployment (creates ECR, etc.)
terraform apply
 
# Get ECR repository URL
ECR_REPO=$(terraform output -raw ecr_repository_url)
 
# Build and push processor image
docker build -t morphix-processor ../backend
docker tag morphix-processor:latest $ECR_REPO:latest
 
# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REPO
 
# Push image
docker push $ECR_REPO:latest
 
# Final deployment with image
terraform apply -var="processor_image_tag=latest"
Step 3: Deploy Frontend
bash
# Option 1: Manual
aws s3 sync ../frontend/ s3://$(terraform output -raw s3_bucket_name)/ --delete
 
# Option 2: Add to Terraform (recommended)
# Add s3_object resources to modules/s3/main.tf
terraform apply
Step 4: Configure Frontend
bash
# Get outputs for frontend config
API_URL=$(terraform output -raw api_gateway_url)
IOT_ENDPOINT=$(terraform output -raw iot_endpoint)
 
# Inject into frontend (or use CloudFront)
sed -i "s|window.MORPHIX_API_BASE.*|window.MORPHIX_API_BASE = \"$API_URL\";|g" ../frontend/app.js
sed -i "s|window.MORPHIX_IOT_ENDPOINT.*|window.MORPHIX_IOT_ENDPOINT = \"wss://$IOT_ENDPOINT/mqtt\";|g" ../frontend/app.js
sed -i "s|window.MORPHIX_IOT_AUTH_URL.*|window.MORPHIX_IOT_AUTH_URL = \"$API_URL/iot-auth\";|g" ../frontend/app.js
 
# Re-upload frontend
aws s3 sync ../frontend/ s3://$(terraform output -raw s3_bucket_name)/ --delete
🔧 Terraform Variables
Create terraform/terraform.tfvars:

hcl
aws_region = "us-east-1"
environment = "dev"
file_retention_days = 1
✅ Final Verification
bash
# Test API
curl -X POST $(terraform output -raw api_gateway_url)/presign \
  -H "Content-Type: application/json" \
  -d '{"files":[{"name":"test.jpg","size":1000,"type":"image/jpeg"}],"target_format":"PNG"}'
 
# Test frontend
open https://$(terraform output -raw clou