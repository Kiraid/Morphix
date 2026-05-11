variable "name_prefix"  {}
variable "bucket_name"  {}
variable "ddb_table"    {}
variable "iot_topic"    {}
variable "tags"         { type = map(string) }

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# PRESIGN LAMBDA ROLE
resource "aws_iam_role" "presign_lambda" {
  name = "${var.name_prefix}-presign-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "presign_lambda" {
  name = "${var.name_prefix}-presign-policy"
  role = aws_iam_role.presign_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.bucket_name}/uploads/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${var.ddb_table}"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:*"]
        Resource = "*"
      }
      # {
      #   Effect   = "Allow"
      #   Action   = ["iot:Connect"]
      #   Resource = "arn:aws:iot:${local.region}:${local.account_id}:client/morphix-*"
      # },
      # {
      #   Effect   = "Allow"
      #   Action   = ["iot:Subscribe"]
      #   Resource = "arn:aws:iot:${local.region}:${local.account_id}:topicfilter/morphix/jobs/*"
      # },
      # {
      #   Effect   = "Allow"
      #   Action   = ["iot:Publish"]
      #   Resource = "arn:aws:iot:${local.region}:${local.account_id}:topic/morphix/jobs/*"
      # },
      # {
      #   Effect   = "Allow"
      #   Action   = ["iot:Receive"]
      #   Resource = "arn:aws:iot:${local.region}:${local.account_id}:topic/morphix/jobs/*"
      # },
      # {
      #   Effect   = "Allow"
      #   Action   = ["iot:DescribeEndpoint"]
      #   Resource = "*"
      # }
    ]
  })
}

# PROCESSOR LAMBDA ROLE
resource "aws_iam_role" "processor_lambda" {
  name = "${var.name_prefix}-processor-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "processor_lambda" {
  name = "${var.name_prefix}-processor-policy"
  role = aws_iam_role.processor_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.bucket_name}",
          "arn:aws:s3:::${var.bucket_name}/uploads/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "arn:aws:s3:::${var.bucket_name}/converted/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = "arn:aws:sqs:${local.region}:${local.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${var.ddb_table}"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Publish"]
        Resource = "arn:aws:iot:${local.region}:${local.account_id}:topic/${var.iot_topic}"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "arn:aws:ecr:${local.region}:${local.account_id}:repository/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      }
    ]
  })
}

output "presign_lambda_role_arn"   { value = aws_iam_role.presign_lambda.arn }
output "processor_lambda_role_arn" { value = aws_iam_role.processor_lambda.arn }
