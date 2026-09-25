variable "github_org" {
  description = "GitHub organisation being governed."
  type        = string
  default     = "Delta-SK"
}

variable "repositories" {
  description = <<-EOT
    Repositories managed by this configuration. Public by design: the test org
    is on the GitHub Free plan, where branch protection is unavailable on
    private repositories.
  EOT

  type = map(object({
    description = string
    topics      = optional(list(string), [])
  }))
}

variable "app_catalogue" {
  description = <<-EOT
    The registry of GitHub Apps permitted in this organisation, keyed by the
    app's GitHub slug. This map is the source of truth: an installation that
    is not listed here is unauthorised by definition, and the orphan check in
    checks.tf will fail the plan.

    installation_id is discovered out-of-band (Settings > GitHub Apps, or the
    org_installations output) because an app must already be installed before
    its repository access can be managed. Terraform cannot install or uninstall
    an app — see README "Limitations".
  EOT

  type = map(object({
    installation_id = string
    owner           = string
    purpose         = string
    justification   = string
    review_by       = string
    repositories    = list(string)
  }))

  validation {
    condition     = alltrue([for a in var.app_catalogue : can(formatdate("YYYY-MM-DD", "${a.review_by}T00:00:00Z"))])
    error_message = "Every app needs a review_by date in YYYY-MM-DD form."
  }

  validation {
    condition     = alltrue([for a in var.app_catalogue : length(trimspace(a.owner)) > 0])
    error_message = "Every app needs a named owning team. Ownership is the point of the catalogue."
  }
}
