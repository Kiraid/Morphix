variable "name_prefix" {}
variable "tags"        { type = map(string) }

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST" # on-demand — perfect for variable load
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  # TTL: DynamoDB auto-deletes expired job records (set by Lambda to now+24h)
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
