variable "name_prefix" {}
variable "tags"        { type = map(string) }

# Dead Letter Queue 
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-processor-dlq"
  message_retention_seconds = 86400 * 3 
  tags                      = var.tags
}

resource "aws_sqs_queue" "main" {
  name                       = "${var.name_prefix}-processor-queue"
  visibility_timeout_seconds = 300  
  message_retention_seconds  = 3600 
  delay_seconds              = 5    

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3 
  })

  tags = var.tags
}

# Allow S3 to send messages to SQS
resource "aws_sqs_queue_policy" "s3_to_sqs" {
  queue_url = aws_sqs_queue.main.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3SendMessage"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.main.arn
      Condition = {
        ArnLike = { "aws:SourceArn" = "arn:aws:s3:::*" }
      }
    }]
  })
}

output "queue_arn" { value = aws_sqs_queue.main.arn }
output "queue_url" { value = aws_sqs_queue.main.url }
output "dlq_arn"   { value = aws_sqs_queue.dlq.arn }
