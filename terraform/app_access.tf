// Which repositories each installed GitHub App may reach. Authoritative:
// applying it removes any access not in the catalogue. Provider behaviour
// that shapes decommissioning (update adds before removing; destroy leaves
// one arbitrary repository; read fails on a missing installation) is in
// docs/GOVERNANCE.md §5.

resource "github_app_installation_repositories" "this" {
  for_each = var.app_catalogue

  // Looked up by slug rather than typed: the organisation already knows it.
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

    // Also caused only by the pull request that sets the date: as time passes
    // the limit moves further out, never closer.
    precondition {
      condition     = timecmp(local.review[each.key].due, timeadd(local.now, "${local.review_max_days[local.review[each.key].tier] * 24}h")) <= 0
      error_message = "App '${each.key}' is ${local.review[each.key].tier} risk, so it is reviewed at least every ${local.review_max_days[local.review[each.key].tier]} days, and review_by ${each.value.review_by} is further away than that. Pick an earlier date."
    }
  }
}
