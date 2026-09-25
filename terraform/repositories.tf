resource "github_repository" "this" {
  for_each = var.repositories

  name        = each.key
  description = each.value.description
  topics      = each.value.topics

  visibility = "public"
  auto_init  = true

  delete_branch_on_merge = true
  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
}

resource "github_repository_vulnerability_alerts" "this" {
  for_each = github_repository.this

  repository = each.value.name
  enabled    = true
}

resource "github_branch_protection" "main" {
  for_each = github_repository.this

  repository_id = each.value.node_id
  pattern       = "main"

  required_pull_request_reviews {
    required_approving_review_count = 1
    dismiss_stale_reviews           = true
  }

  require_conversation_resolution = true
  allows_force_pushes             = false
  allows_deletions                = false

  # No required_status_checks: no CI runs inside these repositories, and
  # requiring a check that never reports would make main unmergeable.
}
