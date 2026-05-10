variable "name_prefix" {}
variable "tags"        { type = map(string) }

# IoT Core policy allowing frontend clients to subscribe/receive
resource "aws_iot_policy" "frontend" {
  name = "${var.name_prefix}-frontend-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iot:Connect"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Subscribe"]
        Resource = "arn:aws:iot:*:*:topicfilter/morphix/jobs/*"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Receive"]
        Resource = "arn:aws:iot:*:*:topic/morphix/jobs/*"
      }
    ]
  })
}

# Get the IoT endpoint (ATS)
data "aws_iot_endpoint" "main" {
  endpoint_type = "iot:Data-ATS"
}

output "endpoint"        { value = data.aws_iot_endpoint.main.endpoint_address }
output "policy_name"     { value = aws_iot_policy.frontend.name }
