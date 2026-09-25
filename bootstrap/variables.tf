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

# GitHub embeds immutable numeric IDs in the OIDC subject claim:
#   repo:<org>@<org_id>/<repo>@<repo_id>:ref:refs/heads/main
# Pinning the IDs is what stops a deleted-and-recreated org or repository of
# the same name from inheriting this trust policy. Find them with:
#   curl -H "Authorization: Bearer $GITHUB_TOKEN" \
#     https://api.github.com/orgs/<org> | jq .id
#   curl -H "Authorization: Bearer $GITHUB_TOKEN" \
#     https://api.github.com/repos/<org>/<repo> | jq .id
variable "github_org_id" {
  description = "Numeric GitHub organisation ID, as it appears in the OIDC subject claim."
  type        = string
  default     = "333749275"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID, as it appears in the OIDC subject claim."
  type        = string
  default     = "1387485403"
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
