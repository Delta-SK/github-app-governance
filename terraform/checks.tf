// Governance findings: warnings, because each describes something outside the
// pull request. They leave the exit code at 0, so the reconciler reads them
// from the plan JSON.

locals {
  // Decommissioning or lapsed apps: their permissions no longer matter.
  in_review_cycle = {
    for slug in local.catalogued : slug => !contains(["decommissioning", "lapsed"], local.review_status[slug])
  }

  orphans = setsubtract(local.installed_slugs, setunion(local.catalogued, local.tombstoned))

  unselectable = sort([
    for slug in setintersection(local.catalogued, local.installed_slugs) :
    slug if local.installations[slug].repository_selection != "selected"
  ])

  reinstalled_tombstones = sort([
    for slug in setintersection(local.tombstoned, local.installed_slugs) :
    "${slug} (removed ${var.decommissioned_apps[slug].removed_on}: ${var.decommissioned_apps[slug].reason})"
  ])

  reviews = {
    for status in ["due_soon", "overdue", "lapsed"] : status => sort([
      for slug, app in var.app_catalogue :
      "${slug} (owner ${app.owner}, review_by ${app.review_by}, quarantine from ${formatdate("YYYY-MM-DD", local.review[slug].lapses_on)})"
      if local.review_status[slug] == status
    ])
  }

  suspended = sort([
    for slug in setintersection(local.catalogued, local.installed_slugs) :
    slug if local.installations[slug].suspended && local.in_review_cycle[slug]
  ])

  // Both directions: a widening is a security finding, a narrowing means the
  // catalogue is stale.
  permission_drift = sort(flatten([
    for slug in setintersection(local.catalogued, local.installed_slugs) : [
      for key in setunion(keys(var.app_catalogue[slug].permissions), keys(local.installations[slug].permissions)) :
      "${slug}.${key}: approved ${lookup(var.app_catalogue[slug].permissions, key, "none")}, live ${lookup(local.installations[slug].permissions, key, "none")}"
      if lookup(var.app_catalogue[slug].permissions, key, "none") != lookup(local.installations[slug].permissions, key, "none")
    ] if local.in_review_cycle[slug]
  ]))

  ghost_owners = setsubtract(
    toset([for app in var.app_catalogue : app.owner]),
    toset(data.github_organization_teams.all.teams[*].slug)
  )
}

check "installations_are_declared" {
  assert {
    condition     = length(local.orphans) == 0
    error_message = "Undeclared GitHub App installation(s): ${join(", ", local.orphans)}. Either catalogue each one with an owner, purpose and review date, or decommission it (docs/OPERATIONS.md)."
  }

  // "All repositories" leaves nothing per-repository for Terraform to govern.
  assert {
    condition     = length(local.unselectable) == 0
    error_message = "Catalogued app(s) installed with repository_selection=all: ${join(", ", local.unselectable)}. Switch them to 'Only select repositories' before their access can be governed."
  }
}

check "tombstones_are_uninstalled" {
  // Expected between releasing an app and uninstalling it; after that it
  // means a removed app was reinstalled.
  assert {
    condition     = length(local.reinstalled_tombstones) == 0
    error_message = "Decommissioned app(s) still installed: ${join("; ", local.reinstalled_tombstones)}. Finish the uninstall, or re-add the app to the catalogue through a pull request if it is needed again."
  }
}

check "reviews_are_due_soon" {
  assert {
    condition     = length(local.reviews.due_soon) == 0
    error_message = "Review due within ${local.review_warning_days} days: ${join("; ", local.reviews.due_soon)}. The owner renews it with a pull request that sets a new review_by."
  }
}

check "reviews_are_overdue" {
  assert {
    condition     = length(local.reviews.overdue) == 0
    error_message = "Review overdue: ${join("; ", local.reviews.overdue)}. Unless renewed, access moves to the quarantine repository on the date shown."
  }
}

check "reviews_have_lapsed" {
  assert {
    condition     = length(local.reviews.lapsed) == 0
    error_message = "Review lapsed, access narrowed to the quarantine repository: ${join("; ", local.reviews.lapsed)}. Renew with a new review_by to restore it, or decommission the app."
  }
}

check "owners_are_real_teams" {
  // A team renamed or deleted in a reorg leaves its apps unowned.
  assert {
    condition     = length(local.ghost_owners) == 0
    error_message = "Owner team(s) that do not exist in the organisation: ${join(", ", local.ghost_owners)}. Existing teams: ${join(", ", data.github_organization_teams.all.teams[*].slug)}. Reassign the app to a team that will answer for it."
  }
}

check "no_suspended_installations" {
  // Suspension keeps every grant, and Terraform sees no drift.
  assert {
    condition     = length(local.suspended) == 0
    error_message = "Catalogued app(s) suspended: ${join(", ", local.suspended)}. Either decommission it or unsuspend it and confirm the access is still wanted."
  }
}

check "permissions_match_catalogue" {
  // Permissions change outside pull requests: an owner accepts an app
  // update's request for more.
  assert {
    condition     = length(local.permission_drift) == 0
    error_message = "Installed permissions differ from the catalogue: ${join("; ", local.permission_drift)}. Record an accepted change in the app's permissions through a pull request, or find out who accepted it."
  }
}
