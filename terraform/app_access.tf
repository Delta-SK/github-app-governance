// Core of the assignment: which repositories each installed GitHub App may
// reach, expressed as code. This resource is authoritative — applying it
// removes any repository access not listed in the catalogue.

resource "github_app_installation_repositories" "this" {
  for_each = var.app_catalogue

  installation_id = each.value.installation_id

  // Indexing github_repository rather than using the raw strings gives two
  // things for free: an implicit dependency so repositories exist before
  // access is granted, and a hard error if the catalogue names a repository
  // this configuration does not manage.
  selected_repositories = [
    for repo in each.value.repositories : github_repository.this[repo].name
  ]

  lifecycle {
    // Expiry is a hard stop, not a warning. A check block would let an app
    // whose review date has passed keep being applied indefinitely, which
    // makes the review date decorative. A precondition fails the plan.
    //
    // This deliberately differs from the orphan detector in checks.tf, which
    // only warns: stale data you own should block your own apply, but an
    // installation somebody else added should not block an unrelated change.
    precondition {
      condition     = timecmp(plantimestamp(), "${each.value.review_by}T00:00:00Z") < 0
      error_message = "App '${each.key}' passed its review_by date of ${each.value.review_by}. Owner ${each.value.owner} must re-confirm the access is still needed and extend the date, or begin decommissioning per docs/GOVERNANCE.md."
    }
  }
}
