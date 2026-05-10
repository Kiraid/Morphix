variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "file_retention_days" {
  description = "Days to retain uploaded and converted files in S3"
  type        = number
  default     = 1

  validation {
    condition     = var.file_retention_days >= 1 && var.file_retention_days <= 30
    error_message = "Retention must be between 1 and 30 days."
  }
}
