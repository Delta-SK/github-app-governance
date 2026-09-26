// Core of the assignment: which repositories each installed GitHub App may
// reach, expressed as code. This resource is authoritative — applying it
// removes any repository access not listed in the catalogue.
//
// Provider behaviour worth knowing (verified in the v6.13.0 source,
// resource_github_app_installation_repositories.go):
//   - update ADDS new repositories before REMOVING old ones, so moving an app
//     from its real repositories to the quarantine repository is safe;
//   - destroy removes every repository EXCEPT ONE ARBITRARY ONE, because
//     GitHub forbids removing the last. Releasing an app that still reaches
//     real repositories would leave it on a random one of them. That is why
//     scripts/plan-guard.sh refuses any destroy of an app not already
//     quarantined;
//   - read ERRORS on an installation that no longer exists, so an app must be
//     released from Terraform BEFORE it is uninstalled (GOVERNANCE.md §5).

resource "github_app_installation_repositories" "this" {
  for_each = var.app_catalogue

  installation_id = each.value.installation_id

  // local.repo_names merges managed repos (github_repository.this) with
  // external repos (data.github_repository.external). A managed repo gets
  // an implicit create-before-access dependency; an external repo gets a
  // plan-time existence check via the postcondition in data.tf. Either way a
  // typo fails the plan with a message naming the repository.
  selected_repositories = [
    for repo in each.value.repositories : local.repo_names[repo]
  ]

  lifecycle {
    // Expiry is a hard stop, not a warning. A check block would let an app
    // whose review date has passed keep being applied indefinitely, which
    // makes the review date decorative.
    //
    // The decommissioning escape is essential, not a loophole. Without it the
    // precondition blocks the very change that removes an expired app, so an
    // owner would have to EXTEND the review date of an app they are trying to
    // delete — the control would prevent the outcome it exists to encourage.
    // It cannot be abused to keep real access: variables.tf only accepts
    // decommissioning = true together with the quarantine repository alone.
    //
    // Known limitation: a precondition failure aborts the whole plan, so one
    // team's lapsed app blocks unrelated changes too. That is bounded by
    // splitting state per team at scale (docs/GOVERNANCE.md §7); at this size
    // there is one state and the blocking is therefore org-wide.
    precondition {
      condition = (
        timecmp(plantimestamp(), "${each.value.review_by}T00:00:00Z") < 0
        || each.value.decommissioning
      )
      error_message = "App '${each.key}' passed its review_by date of ${each.value.review_by}. Owner ${each.value.owner} must either re-confirm the access and extend the date, or set decommissioning = true and narrow it to the quarantine repository. See docs/OPERATIONS.md."
    }

    // The catalogue is keyed by slug but acts on installation_id. Pairing one
    // app's slug with another app's ID would make Terraform replace this
    // resource onto the OTHER app's installation — granting it these
    // repositories. That is an error in the pull request itself, so it
    // blocks rather than warns.
    precondition {
      condition     = !contains(local.installed_slugs, each.key) || tostring(try(local.installations[each.key].id, "")) == each.value.installation_id
      error_message = "App '${each.key}' has installation_id ${each.value.installation_id}, but the '${each.key}' installation in the org is ${try(local.installations[each.key].id, "absent")}. Take the ID from `terraform output org_installations`."
    }

    // A review date years away is an opt-out from review. Unlike expiry this
    // can only fail on the pull request that introduces the date, so blocking
    // costs nobody else anything.
    precondition {
      condition     = timecmp("${each.value.review_by}T00:00:00Z", timeadd(plantimestamp(), "${local.max_review_days * 24}h")) <= 0
      error_message = "App '${each.key}' has review_by ${each.value.review_by}, more than ${local.max_review_days} days away. Reviews are at least annual; pick an earlier date."
    }
  }
}
