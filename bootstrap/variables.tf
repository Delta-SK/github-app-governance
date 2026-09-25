variable "aws_region" {
  description = "Region hosting the Terraform state backend."
  type        = string
  default     = "eu-central-1"
}

variable "github_org" {
  description = "GitHub organisation owning the governance repository."
  type        = string
  default     = "Delta-SK"
}

variable "github_repo" {
  description = "Repository that is allowed to assume the CI role via OIDC."
  type        = string
  default     = "github-app-governance"
}

variable "state_bucket" {
  description = "S3 bucket for Terraform state. Must be globally unique."
  type        = string
  default     = "delta-sk-tfstate-751569314116"
}

variable "lock_table" {
  description = "DynamoDB table for state locking. Required because Terraform 1.9 predates S3 native locking (use_lockfile, 1.10+)."
  type        = string
  default     = "delta-sk-tfstate-lock"
}
