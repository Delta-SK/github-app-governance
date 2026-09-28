// Only data is a variable: a catalogue pull request can set any of it. The
// rules that judge it are locals in settings.tf (docs/decisions/0007).

variable "repositories" {
  description = "Repositories created and configured here (public: the test org is on the Free plan)."

  type = map(object({
    description = string
    topics      = optional(list(string), [])
  }))

  validation {
    condition     = contains(keys(var.repositories), local.quarantine_repository)
    error_message = "The quarantine repository (${local.quarantine_repository}) must be declared in `repositories`, so this configuration controls what it contains."
  }
}

variable "app_catalogue" {
  description = "The GitHub Apps permitted in the organisation, keyed by slug. An installation not listed here is unauthorised."

  type = map(object({
    owner           = string
    purpose         = string
    justification   = string
    review_by       = string
    repositories    = list(string)
    permissions     = map(string)
    decommissioning = optional(bool, false)
  }))

  # The provider silently skips removals for an empty list (docs/decisions/0003).
  validation {
    condition     = alltrue([for a in var.app_catalogue : length(a.repositories) > 0])
    error_message = "An installation must retain at least one repository — GitHub rejects removing the last one. To revoke access, set decommissioning = true and point the app at the quarantine repository. See docs/GOVERNANCE.md §5."
  }

  # The flag leaves the review cycle, so it must not keep real access.
  validation {
    condition = alltrue([
      for a in var.app_catalogue :
      a.decommissioning
      ? (length(a.repositories) == 1 && contains(a.repositories, local.quarantine_repository))
      : !contains(a.repositories, local.quarantine_repository)
    ])
    error_message = "An app with decommissioning = true must list exactly the quarantine repository (${local.quarantine_repository}), and no other app may list it."
  }

  validation {
    condition     = alltrue([for a in var.app_catalogue : can(formatdate("YYYY-MM-DD", "${a.review_by}T00:00:00Z"))])
    error_message = "Every app needs a review_by date in YYYY-MM-DD form."
  }

  validation {
    condition     = alltrue([for a in var.app_catalogue : length(trimspace(a.owner)) > 0])
    error_message = "Every app needs a named owning team. Ownership is the point of the catalogue."
  }

  # Approved permissions: compared with the installation (docs/decisions/0008).
  validation {
    condition = alltrue(flatten([
      for a in var.app_catalogue : [
        length(a.permissions) > 0,
        [for level in values(a.permissions) : contains(["read", "write", "admin"], level)],
      ]
    ]))
    error_message = "Every app needs its approved permissions, each one read, write or admin — as listed on its installation page or in `terraform output org_installations`."
  }

  validation {
    condition     = alltrue([for a in var.app_catalogue : length(trimspace(a.purpose)) > 0 && length(trimspace(a.justification)) > 0])
    error_message = "Every app needs a purpose and a justification. They are what a reviewer approves, and what an auditor reads."
  }
}

variable "decommissioned_apps" {
  description = "Tombstones: apps removed from the organisation, and why. A tombstoned app found installed is reported with its reason."

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
