terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  backend "s3" {
    bucket       = "morphix-dev-terraform-state"
    key          = "morphix/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "morphix-${var.environment}"
  bucket_name = "morphix-${var.environment}-${random_id.suffix.hex}"
  tags = {
    Project     = "morphix"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── MODULES 

module "ecr" {
  source      = "./modules/ecr"
  name_prefix = local.name_prefix
  tags        = local.tags
}

module "iam" {
  source      = "./modules/iam"
  name_prefix = local.name_prefix
  bucket_name = local.bucket_name
  ddb_table   = module.dynamodb.table_name
  iot_topic   = "morphix/jobs/*"
  tags        = local.tags
}

module "s3" {
  source         = "./modules/s3"
  bucket_name    = local.bucket_name
  name_prefix    = local.name_prefix
  cf_arn         = module.cloudfront.oac_arn
  retention_days = var.file_retention_days
  tags           = local.tags
}

module "cloudfront" {
  source        = "./modules/cloudfront"
  name_prefix   = local.name_prefix
  bucket_name   = local.bucket_name
  bucket_domain = module.s3.bucket_regional_domain
  tags          = local.tags
}

module "dynamodb" {
  source      = "./modules/dynamodb"
  name_prefix = local.name_prefix
  tags        = local.tags
}

module "sqs" {
  source      = "./modules/sqs"
  name_prefix = local.name_prefix
  tags        = local.tags
}

module "lambda" {
  source              = "./modules/lambda"
  name_prefix         = local.name_prefix
  bucket_name         = local.bucket_name
  ddb_table           = module.dynamodb.table_name
  ddb_table_arn       = module.dynamodb.table_arn
  sqs_queue_arn       = module.sqs.queue_arn
  sqs_queue_url       = module.sqs.queue_url
  iot_endpoint        = module.iot.endpoint
  presign_role_arn    = module.iam.presign_lambda_role_arn
  processor_role_arn  = module.iam.processor_lambda_role_arn
  ecr_repository_url  = module.ecr.repository_url
  ecr_repository_name = module.ecr.repository_name
  ecr_image_tag       = "latest"
  aws_region          = var.aws_region
  tags                = local.tags
}

module "api_gateway" {
  source               = "./modules/api-gateway"
  name_prefix          = local.name_prefix
  presign_lambda_arn   = module.lambda.presign_lambda_arn
  presign_lambda_name  = module.lambda.presign_lambda_name
  iot_auth_lambda_arn  = module.lambda.iot_auth_lambda_arn
  iot_auth_lambda_name = module.lambda.iot_auth_lambda_name
  aws_region           = var.aws_region
  tags                 = local.tags
}

module "iot" {
  source      = "./modules/iot"
  name_prefix = local.name_prefix
  tags        = local.tags
}

#  S3 → SQS EVENT NOTIFICATION
resource "aws_s3_bucket_notification" "upload_notification" {
  bucket = module.s3.bucket_id

  queue {
    queue_arn     = module.sqs.queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
  }

  depends_on = [module.sqs]
}

# BUDGETS ALARM
resource "aws_budgets_budget" "monthly_limit" {
  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = "5"
  limit_unit   = "USD"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = "80"
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["faizan.akhtar3130@gmail.com"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = "100"
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = ["faizan.akhtar3130@gmail.com"]
  }
}
