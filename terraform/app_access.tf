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
    // makes the review date decorative.
    //
    // The decommissioning escape is essential, not a loophole. Without it the
    // precondition blocks the very change that removes an expired app, so an
    // owner would have to EXTEND the review date of an app they are trying to
    // delete — the control would prevent the outcome it exists to encourage.
    //
    // It cannot key off an empty repository list, because GitHub forbids
    // removing an installation's last repository (see the validation in
    // variables.tf). Setting the flag is an explicit, reviewable statement of
    // intent that shows up in the pull request diff.
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
      error_message = "App '${each.key}' passed its review_by date of ${each.value.review_by}. Owner ${each.value.owner} must either re-confirm the access and extend the date, or set decommissioning = true and narrow it to the quarantine repository. See docs/GOVERNANCE.md."
    }
  }
}
