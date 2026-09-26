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

variable "platform_team_members" {
  description = <<-EOT
    The platform-engineering team, username => team role: the code owners of
    this repository and the reviewers of code plans. At least two, so that no
    change — and no release of the credential to pull request code — rests on
    its author alone.
  EOT
  type        = map(string)
  default = {
    SergeyKirakosyan = "maintainer" // org owner: GitHub reports owners as maintainers regardless
    Approver777      = "member"
  }

  validation {
    condition     = length(var.platform_team_members) >= 2
    error_message = "The platform team needs at least two members: approvals and prevent_self_review are meaningless with one."
  }

  validation {
    condition     = alltrue([for role in values(var.platform_team_members) : contains(["member", "maintainer"], role)])
    error_message = "Team roles are member or maintainer. Prefer member: maintainers can change who is on the team, and so who can approve."
  }
}

variable "app_owner_teams" {
  description = "Teams that own catalogued GitHub Apps, keyed by team slug. Every `owner` in the catalogue must resolve to one of these."
  type        = map(string)
  default = {
    "web-team" = "Owns the customer-facing web application and the apps that serve it."
  }
}
