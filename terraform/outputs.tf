output "app_access_matrix" {
  description = "What each app may reach, as Terraform enforces it, with its review status."
  value = {
    for slug, app in var.app_catalogue : slug => {
      owner         = app.owner
      review_by     = app.review_by
      review_tier   = local.review[slug].tier
      review_status = local.review_status[slug]
      repositories  = sort(local.effective_repositories[slug])
      permissions   = app.permissions
    }
  }
}

output "managed_repositories" {
  description = "Repositories created and configured by this configuration."
  value       = sort(keys(github_repository.this))
}

output "org_installations" {
  description = "Every app installation live in the org, declared or not."
  value = {
    for slug, i in local.installations : slug => {
      installation_id      = tostring(i.id)
      repository_selection = i.repository_selection
      suspended            = i.suspended
      permissions          = i.permissions
      created_at           = i.created_at
      declared             = contains(local.catalogued, slug)
      tombstoned           = contains(local.tombstoned, slug)
    }
  }
}

output "decommissioned_apps" {
  description = "Tombstones: apps removed from the organisation, when, and why."
  value       = var.decommissioned_apps
}

// Read by scripts/plan-guard.sh from the saved plan. Exposed as an output
// because it is a local (settings.tf), and plan JSON records output values
// but not locals.
output "quarantine_repository" {
  description = "Repository that apps being decommissioned are narrowed to."
  value       = local.quarantine_repository
}
