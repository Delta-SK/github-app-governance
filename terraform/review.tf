// Review status of every catalogued app, from its approved permissions and
// the plan's clock (docs/GOVERNANCE.md §3):
//
//   due soon  review_by within review_warning_days      -> warning
//   overdue   review_by passed, grace not yet over       -> warning
//   lapsed    grace over                                 -> access is narrowed
//                                                           to the quarantine
//                                                           repository
//
// A lapse never fails a plan. It changes what the app may reach, the plan
// shows it, and the next apply enforces it. Apps already being
// decommissioned are outside this cycle.

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

  // What each app may actually reach: its catalogue entry, unless its review
  // has lapsed.
  effective_repositories = {
    for slug, app in var.app_catalogue : slug =>
    local.review_status[slug] == "lapsed" ? [local.quarantine_repository] : app.repositories
  }
}
