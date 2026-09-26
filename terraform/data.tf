// Live installation inventory, read from GET /orgs/{org}/installations.
//
// Declared at top level rather than scoped inside the check block so the
// org_installations output can expose it too. The trade-off: if this read
// fails the whole plan fails, where a scoped data source would only fail its
// check. Acceptable here because the same credential already drives every
// other resource — if this call fails, nothing else would work either.
data "github_organization_app_installations" "audit" {}

// The inventory keyed by slug, so checks.tf compares sets rather than
// repeating list comprehensions. An app installs at most once per org, so the
// slug is a unique key.
locals {
  installations   = { for i in data.github_organization_app_installations.audit.installations : i.app_slug => i }
  installed_slugs = toset(keys(local.installations))
  catalogued      = toset(keys(var.app_catalogue))
  tombstoned      = toset(keys(var.decommissioned_apps))
}

// Real teams in the org. An `owner` field that names a team which does not
// exist is precisely how an app becomes unowned — the team is deleted or
// renamed during a reorg and the catalogue quietly keeps pointing at a ghost.
data "github_organization_teams" "all" {
  summary_only = true
}

// ---------------------------------------------------------------------------
// Repository lookup — decouple app access from repo management
// ---------------------------------------------------------------------------

locals {
  catalogued_repos = toset(flatten([for app in var.app_catalogue : app.repositories]))
  external_repos   = setsubtract(local.catalogued_repos, toset(keys(var.repositories)))

  // Single lookup map so app_access.tf does not care where a repo is managed.
  repo_names = merge(
    { for k, r in github_repository.this : k => r.name },
    { for k, r in data.github_repository.external : k => r.name },
  )
}

// Repos referenced by catalogued apps but not created by this configuration.
//
// The lookup alone does NOT validate existence: for a repository that does
// not exist the provider returns an object with every attribute null rather
// than an error. Left like that, a typo surfaces later as an unhelpful
// "Null value found in list" on the access resource. The postcondition turns
// it into an error that names the repository.
data "github_repository" "external" {
  for_each = local.external_repos
  name     = each.value

  lifecycle {
    postcondition {
      condition     = self.repo_id != null
      error_message = "Repository '${each.value}' is listed in app_catalogue but does not exist in ${local.github_org}. Check the spelling, or declare it in `repositories` if this configuration should create it."
    }
  }
}
