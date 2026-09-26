// Governance controls that run on every plan. These surface problems the
// core resources cannot: an app installed by hand that nobody declared, an
// installation scoped so broadly it cannot be governed, a catalogue entry
// that has drifted from reality, or a review date approaching.
//
// check blocks warn rather than block. That is deliberate — an orphan app is
// a signal to investigate, not a reason to stop an unrelated apply. Warnings
// do NOT change terraform's exit code, so the scheduled reconciler reads
// check results out of the plan JSON instead (reconcile.yml).
//
// The blocking controls live elsewhere: variable validations in variables.tf,
// resource preconditions (expiry, review horizon, installation ID) in
// app_access.tf, and the destroy guard in scripts/plan-guard.sh.

locals {
  orphans = setsubtract(local.installed_slugs, setunion(local.catalogued, local.tombstoned))

  unselectable = sort([
    for slug in setintersection(local.catalogued, local.installed_slugs) :
    slug if local.installations[slug].repository_selection != "selected"
  ])

  not_installed = setsubtract(local.catalogued, local.installed_slugs)

  reinstalled_tombstones = sort([
    for slug in setintersection(local.tombstoned, local.installed_slugs) :
    "${slug} (removed ${var.decommissioned_apps[slug].removed_on}: ${var.decommissioned_apps[slug].reason})"
  ])

  // Decommissioning apps are past their review date by design and may be
  // suspended as part of the runbook, so they are exempt from the review and
  // suspension checks — otherwise following the runbook would raise alerts.
  due_soon = sort([
    for slug, app in var.app_catalogue :
    "${slug} (owner: ${app.owner}, due ${app.review_by})"
    if !app.decommissioning && timecmp(timeadd(plantimestamp(), "${local.review_warning_days * 24}h"), "${app.review_by}T00:00:00Z") >= 0
  ])

  suspended = sort([
    for slug in setintersection(local.catalogued, local.installed_slugs) :
    slug if local.installations[slug].suspended && !var.app_catalogue[slug].decommissioning
  ])

  ghost_owners = setsubtract(
    toset([for app in var.app_catalogue : app.owner]),
    toset(data.github_organization_teams.all.teams[*].slug)
  )
}

check "installations_are_declared" {
  // The orphan detector. Anything installed in the org but absent from both
  // the catalogue and the tombstones is, by definition, an app nobody signed
  // up for.
  assert {
    condition     = length(local.orphans) == 0
    error_message = "Undeclared GitHub App installation(s): ${join(", ", local.orphans)}. Either add an entry to catalogue.auto.tfvars with an owner and review date, or decommission per docs/OPERATIONS.md."
  }

  // An installation set to "all repositories" exposes no per-repo scope, so
  // selected_repositories silently governs nothing. Catch that rather than
  // reporting a false clean plan.
  assert {
    condition     = length(local.unselectable) == 0
    error_message = "Catalogued app(s) installed with repository_selection=all: ${join(", ", local.unselectable)}. Repository access cannot be governed until these are switched to 'Only select repositories'."
  }
}

check "catalogue_matches_installations" {
  // An app uninstalled by hand while still catalogued. Once state exists the
  // access resource fails to refresh first (the provider errors on a missing
  // installation); this names the cause. A mismatched installation_id is
  // the other half of this comparison, and blocks — see app_access.tf.
  assert {
    condition     = length(local.not_installed) == 0
    error_message = "Catalogued app(s) not installed in the org: ${join(", ", local.not_installed)}. If the app was removed on purpose, move its entry to decommissioned_apps; otherwise reinstall it."
  }
}

check "tombstones_are_uninstalled" {
  // Expected briefly between releasing an app (stage 3) and uninstalling it
  // (stage 4). After that, it means somebody reinstalled an app the org
  // already decided to remove — and this says why it was removed.
  assert {
    condition     = length(local.reinstalled_tombstones) == 0
    error_message = "Decommissioned app(s) still installed: ${join("; ", local.reinstalled_tombstones)}. Finish stage 4 (uninstall in the org settings), or, if it is genuinely needed again, re-add it to the catalogue through a pull request."
  }
}

check "reviews_are_due_soon" {
  // Expiry itself blocks, via the precondition in app_access.tf. This only
  // gives owners advance warning so the deadline is not a surprise.
  assert {
    condition     = length(local.due_soon) == 0
    error_message = "App(s) due for review within ${local.review_warning_days} days: ${join(", ", local.due_soon)}. Re-confirm the access is still needed before the date passes — after it, plans fail."
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
    condition     = length(local.ghost_owners) == 0
    error_message = "Catalogue names owner team(s) that do not exist in the organisation: ${join(", ", local.ghost_owners)}. Existing teams: ${join(", ", data.github_organization_teams.all.teams[*].slug)}. Either create the team, correct the entry, or reassign the app to a team that will actually answer for it."
  }
}

check "no_suspended_installations" {
  // A suspended installation still holds its grants and reappears intact when
  // unsuspended. Terraform reports no drift, so without this it is invisible.
  assert {
    condition     = length(local.suspended) == 0
    error_message = "Catalogued app(s) currently suspended: ${join(", ", local.suspended)}. Suspension retains every grant — either decommission it properly (docs/OPERATIONS.md) or unsuspend and confirm the access is still wanted."
  }
}
