output "app_access_matrix" {
  description = "Which app can reach which repositories, as Terraform intends it. Compare against the GitHub UI to spot drift."
  value = {
    for slug, app in var.app_catalogue : slug => {
      owner           = app.owner
      review_by       = app.review_by
      decommissioning = app.decommissioning
      repositories    = sort(app.repositories)
    }
  }
}

output "managed_repositories" {
  description = "Repositories created and configured by this configuration."
  value       = sort(keys(github_repository.this))
}

output "org_installations" {
  description = "Every app installation live in the org, declared or not. Source for installation_id values and for spotting orphans."
  value = {
    for slug, i in local.installations : slug => {
      installation_id      = tostring(i.id)
      repository_selection = i.repository_selection
      suspended            = i.suspended
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
