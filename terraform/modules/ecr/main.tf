variable "name_prefix" {}
variable "tags"        { type = map(string) }

resource "aws_ecr_repository" "processor" {
  name                 = "${var.name_prefix}-processor"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = var.tags

  image_scanning_configuration {
    scan_on_push = true # Security scanning on every push
  }
}

# Keep only the last 5 images to save storage costs
resource "aws_ecr_lifecycle_policy" "processor" {
  repository = aws_ecr_repository.processor.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_url"       { value = aws_ecr_repository.processor.repository_url }
output "processor_image_uri"  { value = "${aws_ecr_repository.processor.repository_url}:latest" }
