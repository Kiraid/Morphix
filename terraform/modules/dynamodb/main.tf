variable "name_prefix" {}
variable "tags"        { type = map(string) }

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST" 
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  # TTL: DynamoDB auto-deletes expired job record
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # Enable point-in-time recovery for prod
  point_in_time_recovery {
    enabled = true
  }

  tags = var.tags
}

output "table_name" { value = aws_dynamodb_table.jobs.name }
output "table_arn"  { value = aws_dynamodb_table.jobs.arn }
