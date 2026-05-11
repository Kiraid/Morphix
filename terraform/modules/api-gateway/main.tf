variable "name_prefix"            {}
variable "presign_lambda_arn"     {}
variable "presign_lambda_name"    {}
variable "iot_auth_lambda_arn"    {}
variable "iot_auth_lambda_name"   {}
variable "aws_region"             {}
variable "tags"                   { type = map(string) }

# HTTP API 
resource "aws_apigatewayv2_api" "main" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "Morphix API"
  tags          = var.tags
  
}

# CORS CONFIGURATION 
resource "aws_apigatewayv2_cors_configuration" "main" {
  api_id = aws_apigatewayv2_api.main.id

  allow_origins {
    allowed_origins = ["*"]
  }
  
  allow_methods {
    allowed_methods = ["GET", "POST", "OPTIONS", "HEAD"]
  }
  
  allow_headers {
    allowed_headers = ["Content-Type", "Authorization", "X-Amz-Date", "X-Amz-Security-Token", "X-Amz-User-Agent"]
  }
}

# PRESIGN INTEGRATION 
resource "aws_apigatewayv2_integration" "presign" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "AWS_PROXY"
  integration_uri  = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${var.presign_lambda_arn}/invocations"
  timeout_milliseconds = 30000
}

resource "aws_apigatewayv2_route" "presign" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /presign"
  target    = "integrations/${aws_apigatewayv2_integration.presign.id}"
}

# IOT AUTH INTEGRATION 
resource "aws_apigatewayv2_integration" "iot_auth" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "AWS_PROXY"
  integration_uri  = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${var.iot_auth_lambda_arn}/invocations"
  timeout_milliseconds = 10000
}

resource "aws_apigatewayv2_route" "iot_auth" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /iot-auth"
  target    = "integrations/${aws_apigatewayv2_integration.iot_auth.id}"
}

# DEFAULT ROUTE (404) 
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.default.id}"
}

resource "aws_apigatewayv2_integration" "default" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "MOCK"
  timeout_milliseconds = 5000
}

# STAGE 
resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.main.id
  name       = "prod"
  auto_deploy = true
  tags       = var.tags
  default_route_settings {
    throttling_burst_limit = 5
    throttling_rate_limit = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format         = jsonencode({
      requestId      = "$context.requestId"
      ip            = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}

# LAMBDA PERMISSIONS 
resource "aws_lambda_permission" "presign_api" {
  statement_id  = "AllowAPIGW-POST-presign"
  action        = "lambda:InvokeFunction"
  function_name = var.presign_lambda_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*/*"
}

resource "aws_lambda_permission" "iot_auth_api" {
  statement_id  = "AllowAPIGW-GET-iot-auth"
  action        = "lambda:InvokeFunction"
  function_name = var.iot_auth_lambda_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*/*"
}

# CLOUDWATCH LOGS 
resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${var.name_prefix}"
  retention_in_days = 7
  tags              = var.tags
}

# OUTPUTS 
output "api_url" {
  value = "${aws_apigatewayv2_stage.prod.invoke_url}"
}
