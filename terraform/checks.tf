// Governance controls that run on every plan. These surface problems the
// core resources cannot: an app installed by hand that nobody declared, an
// installation scoped so broadly it cannot be governed, or an entry whose
// review date has quietly passed.
//
// check blocks warn rather than block. That is deliberate — an orphan app is
// a signal to investigate, not a reason to stop an unrelated apply.

check "installations_are_declared" {
  // The orphan detector. Anything installed in the org but absent from the
  // catalogue is, by definition, an app nobody signed up for.
  assert {
    condition = length(setsubtract(
      toset([for i in data.github_organization_app_installations.audit.installations : i.app_slug]),
      toset(keys(var.app_catalogue))
    )) == 0

    error_message = format(
      "Undeclared GitHub App installation(s): %s. Either add an entry to catalogue.auto.tfvars with an owner and review date, or decommission per docs/GOVERNANCE.md.",
      join(", ", setsubtract(
        toset([for i in data.github_organization_app_installations.audit.installations : i.app_slug]),
        toset(keys(var.app_catalogue))
      ))
    )
  }

  // An installation set to "all repositories" exposes no per-repo scope, so
  // selected_repositories silently governs nothing. Catch that rather than
  // reporting a false clean plan.
  assert {
    condition = length([
      for i in data.github_organization_app_installations.audit.installations :
      i.app_slug
      if contains(keys(var.app_catalogue), i.app_slug) && i.repository_selection != "selected"
    ]) == 0

    error_message = format(
      "Catalogued app(s) installed with repository_selection=all: %s. Repository access cannot be governed until these are switched to 'Only select repositories'.",
      join(", ", [
        for i in data.github_organization_app_installations.audit.installations :
        i.app_slug
        if contains(keys(var.app_catalogue), i.app_slug) && i.repository_selection != "selected"
      ])
    )
  }
}

check "reviews_are_due_soon" {
  // Expiry itself blocks, via the precondition in app_access.tf. This only
  // gives owners advance warning so the deadline is not a surprise.
  assert {
    condition = length([
      for slug, app in var.app_catalogue :
      slug if timecmp(timeadd(plantimestamp(), "${var.review_warning_days * 24}h"), "${app.review_by}T00:00:00Z") >= 0
    ]) == 0

    error_message = format(
      "App(s) due for review within %d days: %s. Re-confirm the access is still needed before the date passes — after it, plans fail.",
      var.review_warning_days,
      join(", ", [
        for slug, app in var.app_catalogue :
        "${slug} (owner: ${app.owner}, due ${app.review_by})"
        if timecmp(timeadd(plantimestamp(), "${var.review_warning_days * 24}h"), "${app.review_by}T00:00:00Z") >= 0
      ])
    )
  }
}

check "owners_are_real_teams" {
  // `owner` being free text is how ownership rots: a team is renamed or
  // deleted during a reorg and the catalogue keeps naming a team that no
  // longer exists. Nobody notices, because nothing was ever checking.
  //
  // A warning rather than a blocker: a deleted team is a reason to find a new
  // owner, not a reason to freeze every app in the org.
  assert {
    condition = length(setsubtract(
      toset([for app in var.app_catalogue : app.owner]),
      toset(data.github_organization_teams.all.teams[*].slug)
    )) == 0

    error_message = format(
      "Catalogue names owner team(s) that do not exist in the organisation: %s. Existing teams: %s. Either create the team, correct the entry, or reassign the app to a team that will actually answer for it.",
      join(", ", setsubtract(
        toset([for app in var.app_catalogue : app.owner]),
        toset(data.github_organization_teams.all.teams[*].slug)
      )),
      join(", ", data.github_organization_teams.all.teams[*].slug)
    )
  }
}

check "no_suspended_installations" {
  // A suspended installation still holds its grants and reappears intact when
  // unsuspended. Terraform reports no drift, so without this it is invisible.
  assert {
    condition = length([
      for i in data.github_organization_app_installations.audit.installations :
      i.app_slug if i.suspended && contains(keys(var.app_catalogue), i.app_slug)
    ]) == 0

    error_message = format(
      "Catalogued app(s) currently suspended: %s. Suspension retains every grant — either complete the decommissioning (docs/GOVERNANCE.md stage 4) or unsuspend and confirm the access is still wanted.",
      join(", ", [
        for i in data.github_organization_app_installations.audit.installations :
        i.app_slug if i.suspended && contains(keys(var.app_catalogue), i.app_slug)
      ])
    )
  }
}
