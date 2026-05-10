variable "bucket_name"    {}
variable "name_prefix"    {}
variable "cf_arn"         {}
variable "retention_days" { type = number }
variable "tags"           { type = map(string) }

resource "aws_s3_bucket" "main" {
  bucket        = var.bucket_name
  force_destroy = true
  tags          = var.tags
}

# Block all public access CloudFront uses OAC
resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning disabled — we don't need it for ephemeral files
resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration { status = "Disabled" }
}

# ── LIFECYCLE: auto-delete uploads and converted files ────────────────
resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    id     = "delete-uploads"
    status = "Enabled"
    filter { prefix = "uploads/" }
    expiration { days = var.retention_days }
  }

  rule {
    id     = "delete-converted"
    status = "Enabled"
    filter { prefix = "converted/" }
    expiration { days = var.retention_days }
  }
}

# ── CORS: allow presigned PUT uploads from the CloudFront domain ──────
resource "aws_s3_bucket_cors_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET", "HEAD"]
    # In production, restrict to your CloudFront domain
    allowed_origins = ["*"]
    max_age_seconds = 3600
  }
}

# ── BUCKET POLICY: allow CloudFront OAC + Lambda role ─────────────────
resource "aws_s3_bucket_policy" "main" {
  bucket = aws_s3_bucket.main.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudFront OAC can GET frontend assets
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.main.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = var.cf_arn
          }
        }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.main]
}

# Upload frontend files
resource "aws_s3_object" "index_html" {
  bucket = aws_s3_bucket.main.id
  key    = "index.html"
  source = "${path.module}/../../frontend/index.html"
  content_type = "text/html"
}
 
resource "aws_s3_object" "app_js" {
  bucket = aws_s3_bucket.main.id
  key    = "app.js"
  source = "${path.module}/../../frontend/app.js"
  content_type = "application/javascript"
}
 
resource "aws_s3_object" "style_css" {
  bucket = aws_s3_bucket.main.id
  key    = "style.css"
  source = "${path.module}/../../frontend/style.css"
  content_type = "text/css"
}

output "bucket_id"               { value = aws_s3_bucket.main.id }
output "bucket_arn"              { value = aws_s3_bucket.main.arn }
output "bucket_regional_domain"  { value = aws_s3_bucket.main.bucket_regional_domain_name }
