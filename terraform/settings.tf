// Policy settings: the rules that judge the catalogue. Locals, not variables,
// so a catalogue (*.tfvars) pull request cannot change them — only a reviewed
// code change can.

locals {
  github_org = "Delta-SK"

  # Longest allowed time between reviews, by the riskiest permission an app
  # holds (docs/GOVERNANCE.md §3).
  review_max_days = {
    high   = 90  # write/admin on a permission in high_risk_permissions
    medium = 180 # any other write/admin
    low    = 366 # read-only
  }

  # Permissions that control what code runs, or who has access.
  high_risk_permissions = [
    "actions", "administration", "environments", "members",
    "organization_administration", "organization_hooks",
    "organization_secrets", "repository_hooks", "secrets", "workflows",
  ]

  review_warning_days = 30 # warn this long before review_by
  review_grace_days   = 30 # after review_by, access moves to quarantine

  # GitHub will not let an installation drop its last repository, so revoked
  # access is expressed as "reaches only this empty repository".
  quarantine_repository = "app-quarantine"
}
