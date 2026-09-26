variable "github_org" {
  description = "GitHub organisation being governed."
  type        = string
  default     = "Delta-SK"
}

variable "review_warning_days" {
  description = "How long before review_by to start warning on every plan. Expiry itself blocks; this is the advance notice."
  type        = number
  default     = 30
}

variable "max_review_days" {
  description = "Furthest a review_by date may be set in the future. Without a ceiling, `review_by = \"2099-12-31\"` quietly opts an app out of review."
  type        = number
  default     = 366
}

variable "quarantine_repository" {
  description = <<-EOT
    Repository that apps being decommissioned are narrowed to. GitHub will not
    let an installation drop its last repository, so "revoke all access" has
    to be expressed as "point it at a repository containing nothing".
  EOT
  type        = string
  default     = "app-quarantine"

  validation {
    condition     = contains(keys(var.repositories), var.quarantine_repository)
    error_message = "The quarantine repository must be declared in `repositories`, so this configuration controls what it contains."
  }
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
    checks.tf flags it on every plan and in the weekly reconciliation issue.

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
    decommissioning = optional(bool, false)
  }))

  # GitHub refuses to remove the last repository from an installation, and
  # the provider works around it by silently skipping every removal when the
  # list is empty (resource_github_app_installation_repositories.go). The
  # result: `terraform apply` reports success, nothing changes, and every
  # later plan shows the same diff forever. Reject the empty list here so the
  # failure is a clear message at plan time rather than a silent drift loop.
  validation {
    condition     = alltrue([for a in var.app_catalogue : length(a.repositories) > 0])
    error_message = "An installation must retain at least one repository — GitHub rejects removing the last one. To revoke access, set decommissioning = true and point the app at the quarantine repository. See docs/GOVERNANCE.md §5."
  }

  # `decommissioning = true` exempts an app from the expiry precondition. That
  # exemption must not be usable to keep real access: a decommissioning app
  # reaches the quarantine repository and nothing else. Conversely the
  # quarantine repository is for decommissioning only, so its presence in a
  # diff always means the same thing.
  validation {
    condition = alltrue([
      for a in var.app_catalogue :
      a.decommissioning
      ? (length(a.repositories) == 1 && contains(a.repositories, var.quarantine_repository))
      : !contains(a.repositories, var.quarantine_repository)
    ])
    error_message = "An app with decommissioning = true must list exactly the quarantine repository (${var.quarantine_repository}), and no other app may list it."
  }

  # A placeholder such as "TBD" would plan cleanly (nothing calls the API for a
  # create at plan time) and only fail during apply, after merge.
  validation {
    condition     = alltrue([for a in var.app_catalogue : can(regex("^[0-9]+$", a.installation_id))])
    error_message = "installation_id must be the numeric ID of an existing installation. Install the app first, then copy the ID from its Configure page URL or `gh api orgs/<org>/installations`."
  }

  validation {
    condition     = alltrue([for a in var.app_catalogue : can(formatdate("YYYY-MM-DD", "${a.review_by}T00:00:00Z"))])
    error_message = "Every app needs a review_by date in YYYY-MM-DD form."
  }

  validation {
    condition     = alltrue([for a in var.app_catalogue : length(trimspace(a.owner)) > 0])
    error_message = "Every app needs a named owning team. Ownership is the point of the catalogue."
  }

  validation {
    condition     = alltrue([for a in var.app_catalogue : length(trimspace(a.purpose)) > 0 && length(trimspace(a.justification)) > 0])
    error_message = "Every app needs a purpose and a justification. They are what a reviewer approves, and what an auditor reads."
  }
}

variable "decommissioned_apps" {
  description = <<-EOT
    Tombstones: apps this organisation has removed, and why. Keyed by app
    slug. An entry moves here from app_catalogue in the pull request that
    releases the app from Terraform (docs/GOVERNANCE.md §5, stage 3).

    This is a control, not a comment. If a tombstoned app is found installed,
    the tombstones_are_uninstalled check names it together with the reason it
    was removed — so re-installing something the org already decided against
    surfaces that decision instead of looking like a fresh orphan.
  EOT

  type = map(object({
    removed_on       = string
    owner_at_removal = string
    reason           = string
    ticket           = optional(string, "")
  }))
  default = {}

  validation {
    condition     = length(setintersection(toset(keys(var.decommissioned_apps)), toset(keys(var.app_catalogue)))) == 0
    error_message = "An app cannot be both catalogued and tombstoned. Remove it from one of app_catalogue or decommissioned_apps."
  }

  validation {
    condition     = alltrue([for t in var.decommissioned_apps : can(formatdate("YYYY-MM-DD", "${t.removed_on}T00:00:00Z")) && length(trimspace(t.reason)) > 0])
    error_message = "Every tombstone needs a removed_on date in YYYY-MM-DD form and a reason."
  }
}
