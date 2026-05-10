terraform {
  required_version = ">= 1.7.0"

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

  # Uncomment to use S3 backend (recommended for real deployments)
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "morphix/terraform.tfstate"
  #   region = "us-east-1"
  # }
}
variable "aws_region" {
  
}
variable "environment" {
  
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
  source        = "./modules/s3"
  bucket_name   = local.bucket_name
  name_prefix   = local.name_prefix
  cf_arn        = module.cloudfront.oac_arn
  retention_days = var.file_retention_days
  tags          = local.tags
}

module "cloudfront" {
  source      = "./modules/cloudfront"
  name_prefix = local.name_prefix
  bucket_name = local.bucket_name
  bucket_domain = module.s3.bucket_regional_domain
  tags        = local.tags
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
  ecr_image_uri       = module.ecr.processor_image_uri
  aws_region          = var.aws_region
  tags                = local.tags
}

module "api_gateway" {
  source              = "./modules/api-gateway"
  name_prefix         = local.name_prefix
  presign_lambda_arn  = module.lambda.presign_lambda_arn
  presign_lambda_name = module.lambda.presign_lambda_name
  iot_auth_lambda_arn = module.lambda.iot_auth_lambda_arn
  iot_auth_lambda_name = module.lambda.iot_auth_lambda_name
  aws_region          = var.aws_region
  tags                = local.tags
}

module "iot" {
  source      = "./modules/iot"
  name_prefix = local.name_prefix
  tags        = local.tags
}

# ── S3 → SQS EVENT NOTIFICATION
resource "aws_s3_bucket_notification" "upload_notification" {
  bucket = module.s3.bucket_id

  queue {
    queue_arn     = module.sqs.queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
  }

  depends_on = [module.sqs]
}
