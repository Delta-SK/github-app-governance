// Which repositories each installed GitHub App may reach. Authoritative:
// access not in the catalogue is removed. Provider behaviour that shapes
// decommissioning: docs/decisions/0003.

resource "github_app_installation_repositories" "this" {
  for_each = var.app_catalogue

  // Looked up by slug, not typed (docs/decisions/0007).
  installation_id = try(tostring(local.installations[each.key].id), "")

  selected_repositories = [
    for repo in local.effective_repositories[each.key] : local.repo_names[repo]
  ]

  lifecycle {
    // Blocks only the pull request that adds an app before it is installed.
    precondition {
      condition     = contains(local.installed_slugs, each.key)
      error_message = "App '${each.key}' is in the catalogue but not installed in ${local.github_org}. For a new app: once this request is approved, an organisation owner installs it (Only select repositories) and the plan is re-run. For an app uninstalled by hand: see docs/OPERATIONS.md."
    }

    // Also only the pull request that sets the date: the limit only recedes.
    precondition {
      condition     = timecmp(local.review[each.key].due, timeadd(local.now, "${local.review_max_days[local.review[each.key].tier] * 24}h")) <= 0
      error_message = "App '${each.key}' is ${local.review[each.key].tier} risk, so it is reviewed at least every ${local.review_max_days[local.review[each.key].tier]} days, and review_by ${each.value.review_by} is further away than that. Pick an earlier date."
    }
  }
}
