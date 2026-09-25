// Configuration of the governance repository itself, and the team that
// reviews it.
//
// This lives in bootstrap rather than in ../terraform deliberately. It has
// its own state, so a failed apply here cannot leave the main configuration
// unable to merge, and a failed apply there cannot strip the controls
// protecting this repository. Managing a repository's branch protection from
// the same state that the repository's own CI applies is a lockout waiting to
// happen.

provider "github" {
  owner = var.github_org
}

data "github_repository" "governance" {
  full_name = "${var.github_org}/${var.github_repo}"
}

// CODEOWNERS is inert unless the team exists, is visible, and has write
// access to the repository. A CODEOWNERS file naming a non-existent team
// silently routes nothing while appearing to be a control.
resource "github_team" "platform_engineering" {
  name        = "platform-engineering"
  description = "Owns GitHub App governance: reviews catalogue changes and the controls enforcing them."
  privacy     = "closed" // must not be "secret", or CODEOWNERS cannot resolve it
}

resource "github_team_repository" "governance" {
  team_id    = github_team.platform_engineering.id
  repository = data.github_repository.governance.name
  permission = "push"
}

// Teams that own catalogued apps. These must exist for the
// owners_are_real_teams check in ../terraform to pass — an owner field naming
// a team that was never created is indistinguishable from one naming a team
// that was deleted, and both mean the app is unowned.
resource "github_team" "app_owners" {
  for_each = var.app_owner_teams

  name        = each.key
  description = each.value
  privacy     = "closed"
}

resource "github_team_members" "platform_engineering" {
  team_id = github_team.platform_engineering.id

  dynamic "members" {
    for_each = var.platform_team_members
    content {
      // The API returns member logins lowercased. Without normalising here,
      // any capitalisation in the variable produces a permanent diff.
      username = lower(members.value)
      role     = "maintainer"
    }
  }
}

resource "github_branch_protection" "governance_main" {
  repository_id = data.github_repository.governance.node_id
  pattern       = "main"

  required_status_checks {
    strict   = true
    contexts = ["plan"]
  }

  required_pull_request_reviews {
    required_approving_review_count = 1
    require_code_owner_reviews      = true
    dismiss_stale_reviews           = true
  }

  require_conversation_resolution = true
  allows_force_pushes             = false
  allows_deletions                = false

  // enforce_admins is left false so an org owner retains break-glass access
  // for the case where CI itself is broken. See README.
  enforce_admins = false
}

// ---------------------------------------------------------------------------
// Environments — the trust boundary for credentials
// ---------------------------------------------------------------------------

// The plan job runs untrusted PR code. Holding TF_GITHUB_TOKEN as a
// repository secret would make it readable by any job, including one a
// contributor rewrote in their own pull request. Scoping it to an environment
// with required reviewers means a human releases it per run.
resource "github_repository_environment" "plan" {
  repository  = data.github_repository.governance.name
  environment = "plan"

  reviewers {
    users = var.environment_reviewer_ids
  }
}

// Apply runs code already merged to main, so it needs no human gate beyond
// the pull request that merged it — but it is pinned to protected branches so
// the credential cannot be reached from an arbitrary ref.
resource "github_repository_environment" "production" {
  repository  = data.github_repository.governance.name
  environment = "production"

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}
