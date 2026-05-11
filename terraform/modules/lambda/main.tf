variable "name_prefix"          {}
variable "bucket_name"          {}
variable "ddb_table"            {}
variable "ddb_table_arn"        {}
variable "sqs_queue_arn"        {}
variable "sqs_queue_url"        {}
variable "iot_endpoint"         {}
variable "presign_role_arn"     {}
variable "processor_role_arn"   {}
variable "ecr_repository_url"   {}
variable "ecr_repository_name"  {}
variable "ecr_image_tag"        { default = "latest" }
variable "aws_region"           {}
variable "tags"                 { type = map(string) }

# PRESIGN LAMBDA (Go binary, zip deployment)
data "archive_file" "presign" {
  type        = "zip"
  source_file = "${path.module}/../../../backend/dist/presign/bootstrap"
  output_path = "${path.module}/../../../backend/dist/presign.zip"
}

resource "aws_lambda_function" "presign" {
  function_name    = "${var.name_prefix}-presign"
  filename         = data.archive_file.presign.output_path
  source_code_hash = data.archive_file.presign.output_base64sha256
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  role             = var.presign_role_arn
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      S3_BUCKET  = var.bucket_name
      DDB_TABLE  = var.ddb_table
    }
  }

  tags = var.tags
}

# PROCESSOR LAMBDA (Docker image from ECR)
data "aws_ecr_image" "processor" {
  repository_name = var.ecr_repository_name
  image_tag       = var.ecr_image_tag
}

resource "aws_lambda_function" "processor" {
  function_name = "${var.name_prefix}-processor"
  role          = var.processor_role_arn
  package_type  = "Image"
  # Pin to an immutable digest so Terraform detects new pushes,
  # even if you keep using the mutable :latest tag.
  image_uri     = "${var.ecr_repository_url}@${data.aws_ecr_image.processor.image_digest}"
  timeout       = 300  
  memory_size   = 3008 

  environment {
    variables = {
      S3_BUCKET    = var.bucket_name
      DDB_TABLE    = var.ddb_table
      IOT_ENDPOINT = "https://${var.iot_endpoint}"
    }
  }

  # Ephemeral storage for temp files 
  ephemeral_storage { size = 2048 } 

  tags = var.tags
}

# SQS → Processor trigger
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = var.sqs_queue_arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 1  

  function_response_types = ["ReportBatchItemFailures"]
}

# IOT AUTH LAMBDA 
data "archive_file" "iot_auth" {
  type        = "zip"
  source_file = "${path.module}/../../../backend/dist/iot-auth/bootstrap"
  output_path = "${path.module}/../../../backend/dist/iot-auth.zip"
}

resource "aws_lambda_function" "iot_auth" {
  function_name    = "${var.name_prefix}-iot-auth"
  filename         = data.archive_file.iot_auth.output_path
  source_code_hash = data.archive_file.iot_auth.output_base64sha256
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  role             = var.presign_role_arn
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      IOT_ENDPOINT = var.iot_endpoint
    }
  }

  tags = var.tags
}

# CLOUDWATCH LOG GROUPS 
resource "aws_cloudwatch_log_group" "presign" {
  name              = "/aws/lambda/${aws_lambda_function.presign.function_name}"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${aws_lambda_function.processor.function_name}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "iot_auth" {
  name              = "/aws/lambda/${aws_lambda_function.iot_auth.function_name}"
  retention_in_days = 7
  tags              = var.tags
}

# OUTPUTS 
output "presign_lambda_arn"      { value = aws_lambda_function.presign.arn }
output "presign_lambda_name"     { value = aws_lambda_function.presign.function_name }
output "processor_lambda_arn"    { value = aws_lambda_function.processor.arn }
output "iot_auth_lambda_arn"     { value = aws_lambda_function.iot_auth.arn }
output "iot_auth_lambda_name"    { value = aws_lambda_function.iot_auth.function_name }
