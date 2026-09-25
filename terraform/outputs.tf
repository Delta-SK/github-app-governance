output "app_access_matrix" {
  description = "Which app can reach which repositories, as Terraform intends it. Compare against the GitHub UI to spot drift."
  value = {
    for slug, app in var.app_catalogue : slug => {
      owner        = app.owner
      review_by    = app.review_by
      repositories = sort(app.repositories)
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
    for i in data.github_organization_app_installations.audit.installations :
    i.app_slug => {
      installation_id      = tostring(i.id)
      repository_selection = i.repository_selection
      declared             = contains(keys(var.app_catalogue), i.app_slug)
    }
  }
}
