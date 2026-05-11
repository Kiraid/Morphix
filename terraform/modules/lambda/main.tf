variable "name_prefix"          {}
variable "bucket_name"          {}
variable "ddb_table"            {}
variable "ddb_table_arn"        {}
variable "sqs_queue_arn"        {}
variable "sqs_queue_url"        {}
variable "iot_endpoint"         {}
variable "presign_role_arn"     {}
variable "processor_role_arn"   {}
variable "ecr_image_uri"        {}
variable "aws_region"           {}
variable "tags"                 { type = map(string) }

# PRESIGN LAMBDA (Go binary, zip deployment)
data "archive_file" "presign" {
  type        = "zip"
  source_file = "${path.module}/../../../../backend/dist/presign/bootstrap"
  output_path = "${path.module}/dist/presign.zip"
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
      AWS_REGION = var.aws_region
    }
  }

  tags = var.tags
}

# PROCESSOR LAMBDA (Docker image from ECR)
resource "aws_lambda_function" "processor" {
  function_name = "${var.name_prefix}-processor"
  role          = var.processor_role_arn
  package_type  = "Image"
  image_uri     = var.ecr_image_uri
  timeout       = 300  
  memory_size   = 3008 

  environment {
    variables = {
      S3_BUCKET    = var.bucket_name
      DDB_TABLE    = var.ddb_table
      IOT_ENDPOINT = "https://${var.iot_endpoint}"
      AWS_REGION   = var.aws_region
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
  source_file = "${path.module}/../../../../backend/dist/iot-auth/bootstrap"
  output_path = "${path.module}/dist/iot-auth.zip"
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
      AWS_REGION   = var.aws_region
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
