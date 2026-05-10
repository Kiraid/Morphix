output "cloudfront_url" {
  description = "CloudFront distribution URL (your public site URL)"
  value       = "https://${module.cloudfront.domain_name}"
}

output "api_gateway_url" {
  description = "API Gateway base URL"
  value       = module.api_gateway.api_url
}

output "iot_endpoint" {
  description = "IoT Core ATS endpoint"
  value       = module.iot.endpoint
}

output "s3_bucket_name" {
  description = "S3 bucket name"
  value       = local.bucket_name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the processor Lambda image"
  value       = module.ecr.repository_url
}

output "dynamodb_table_name" {
  description = "DynamoDB jobs table name"
  value       = module.dynamodb.table_name
}

# Config snippet to paste into frontend app.js or inject via CI/CD
output "frontend_config" {
  description = "Config values to inject into the frontend"
  value = {
    API_BASE     = module.api_gateway.api_url
    IOT_ENDPOINT = "wss://${module.iot.endpoint}/mqtt"
    IOT_AUTH_URL = "${module.api_gateway.api_url}/iot-auth"
  }
}
