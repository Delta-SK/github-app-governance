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
  team_slug = github_team.platform_engineering.slug

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

  // validate       - job in terraform-validate.yml: fmt/validate of the PR's
  //                  own code, no credentials.
  // terraform-plan - commit status posted on the PR head by
  //                  terraform-plan.yml, which runs main's code on the PR's
  //                  catalogue data. A status rather than the job's check
  //                  run, because pull_request_target runs against the base
  //                  commit and its check run is not guaranteed to attach to
  //                  the PR head.
  required_status_checks {
    strict   = true
    contexts = ["validate", "terraform-plan"]
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
//
// TF_GITHUB_TOKEN (an organisation-admin PAT) lives in these environments,
// never as a repository secret, so no job can read it implicitly. The rule
// they encode: the credential reaches either code already on main, or pull
// request code that a human has looked at — never unreviewed code.
//
//   plan       main only, no reviewer. terraform-plan.yml is a
//              pull_request_target workflow: GitHub runs main's definition
//              of it, which plans main's code against the PR's *.tfvars
//              data. Data cannot execute, so no approval is needed.
//   plan-code  reviewers required. terraform-plan-code.yml runs a PR's own
//              Terraform code, which could do anything with the credential.
//   production main only, no reviewer. The pull request was the gate.
//
// can_admins_bypass = false everywhere: an administrator gains nothing
// legitimate from bypassing, and it keeps the rule above exceptionless.

resource "github_repository_environment" "plan" {
  repository        = data.github_repository.governance.name
  environment       = "plan"
  can_admins_bypass = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment" "plan_code" {
  repository        = data.github_repository.governance.name
  environment       = "plan-code"
  can_admins_bypass = false

  // The team, not named individuals: whoever is on the platform team can
  // release a run, and leaving the team revokes it.
  reviewers {
    teams = [tonumber(github_team.platform_engineering.id)]
  }
}

resource "github_repository_environment" "production" {
  repository        = data.github_repository.governance.name
  environment       = "production"
  can_admins_bypass = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

// "main" exactly, rather than "any protected branch": protecting another
// branch later must not silently extend who can reach the credential.
resource "github_repository_environment_deployment_policy" "main_only" {
  for_each = {
    plan       = github_repository_environment.plan.environment
    production = github_repository_environment.production.environment
  }

  repository     = data.github_repository.governance.name
  environment    = each.value
  branch_pattern = "main"
}
