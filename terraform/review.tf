// Review tier and status per app; a lapsed review narrows access to the
// quarantine repository instead of failing any plan (docs/decisions/0004).

locals {
  now = plantimestamp()

  review = {
    for slug, app in var.app_catalogue : slug => {
      tier = (
        anytrue([for p, level in app.permissions : contains(local.high_risk_permissions, p) && level != "read"]) ? "high" :
        anytrue([for level in values(app.permissions) : level != "read"]) ? "medium" : "low"
      )
      due       = "${app.review_by}T00:00:00Z"
      lapses_on = timeadd("${app.review_by}T00:00:00Z", "${local.review_grace_days * 24}h")
    }
  }

  review_status = {
    for slug, app in var.app_catalogue : slug => (
      app.decommissioning ? "decommissioning" :
      timecmp(local.now, local.review[slug].lapses_on) >= 0 ? "lapsed" :
      timecmp(local.now, local.review[slug].due) >= 0 ? "overdue" :
      timecmp(timeadd(local.now, "${local.review_warning_days * 24}h"), local.review[slug].due) >= 0 ? "due_soon" :
      "current"
    )
  }

  // What each app may reach: its entry, unless its review has lapsed.
  effective_repositories = {
    for slug, app in var.app_catalogue : slug =>
    local.review_status[slug] == "lapsed" ? [local.quarantine_repository] : app.repositories
  }
}
