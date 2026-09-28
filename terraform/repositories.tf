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

  // No advanced_security block: GitHub rejects it on public repositories.
  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
}

resource "github_repository_vulnerability_alerts" "this" {
  for_each = github_repository.this

  repository = each.value.name
  enabled    = true
}

// Rulesets with no bypass actors (docs/decisions/0005).
resource "github_repository_ruleset" "main" {
  for_each = github_repository.this

  name        = "main"
  repository  = each.value.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count   = 1
      dismiss_stale_reviews_on_push     = true
      required_review_thread_resolution = true
      allowed_merge_methods             = ["squash"]
    }

    # No required_status_checks: no CI runs inside these repositories, and
    # requiring a check that never reports would make main unmergeable.
  }
}
