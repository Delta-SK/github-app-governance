// Live installation inventory (GET /orgs/{org}/installations), keyed by slug:
// an app installs at most once per organisation.
data "github_organization_app_installations" "audit" {}

locals {
  installations   = { for i in data.github_organization_app_installations.audit.installations : i.app_slug => i }
  installed_slugs = toset(keys(local.installations))
  catalogued      = toset(keys(var.app_catalogue))
  tombstoned      = toset(keys(var.decommissioned_apps))
}

// Real teams, so an owner naming a deleted or renamed team is reported.
data "github_organization_teams" "all" {
  summary_only = true
}

// Apps may reach repositories this configuration does not create; they are
// looked up so a misspelled name fails the plan.
locals {
  catalogued_repos = toset(flatten([for app in var.app_catalogue : app.repositories]))
  external_repos   = setsubtract(local.catalogued_repos, toset(keys(var.repositories)))

  repo_names = merge(
    { for k, r in github_repository.this : k => r.name },
    { for k, r in data.github_repository.external : k => r.name },
  )
}

data "github_repository" "external" {
  for_each = local.external_repos
  name     = each.value

  lifecycle {
    // For a missing repository the provider returns nulls, not an error.
    postcondition {
      condition     = self.repo_id != null
      error_message = "Repository '${each.value}' is listed in app_catalogue but does not exist in ${local.github_org}. Check the spelling, or declare it in `repositories` if this configuration should create it."
    }
  }
}
