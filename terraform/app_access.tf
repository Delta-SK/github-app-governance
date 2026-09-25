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
}
