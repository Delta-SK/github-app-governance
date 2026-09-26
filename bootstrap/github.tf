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

// ---------------------------------------------------------------------------
// The governance repository itself
// ---------------------------------------------------------------------------

// Adopted into Terraform rather than created: the repository already existed
// when these controls were written. The import block is idempotent — once the
// repository is in state it does nothing, and it stays as the record of where
// the resource came from.
import {
  to = github_repository.governance
  id = var.github_repo
}

resource "github_repository" "governance" {
  name        = var.github_repo
  description = "GitOps governance of GitHub App installation access"
  visibility  = "public"

  has_issues   = true // reconciliation findings and app requests live here
  has_projects = true
  // A wiki is edited outside pull requests and branch rules: an unreviewed
  // channel next to a reviewed one. Documentation lives in the repository.
  has_wiki = false

  // Squash only, titled and described by the pull request, so each change to
  // the catalogue is one commit carrying its own justification — the audit
  // trail is `git log`.
  allow_merge_commit          = false
  allow_rebase_merge          = false
  allow_squash_merge          = true
  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "PR_BODY"
  delete_branch_on_merge      = true
  // Branches must be up to date before merging; this offers the button.
  allow_update_branch = true

  // This repository's CI holds an organisation-admin token, and its history
  // is public. Push protection stops a leaked secret at `git push`.
  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }

  archive_on_destroy = true

  lifecycle {
    // Destroying the repository would destroy the authorisation record.
    prevent_destroy = true
  }
}

resource "github_repository_vulnerability_alerts" "governance" {
  repository = github_repository.governance.name
  enabled    = true
}

// Security fixes for the pinned actions and providers as pull requests, on
// top of the weekly version updates in .github/dependabot.yml.
resource "github_repository_dependabot_security_updates" "governance" {
  repository = github_repository.governance.name
  enabled    = true

  depends_on = [github_repository_vulnerability_alerts.governance]
}

// SECURITY.md sends reporters to GitHub's private vulnerability reporting.
// The provider has no resource for that setting, so it is enabled through
// the REST API here: idempotent (a PUT), re-run if the repository is ever
// replaced, and verified weekly by scripts/verify-repo-controls.sh. Replace
// with a native resource once integrations/github offers one.
resource "terraform_data" "private_vulnerability_reporting" {
  triggers_replace = [github_repository.governance.repo_id]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      token="$${GITHUB_TOKEN:-$(gh auth token)}"
      curl -fsS -X PUT \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${var.github_org}/${github_repository.governance.name}/private-vulnerability-reporting"
    EOT
  }
}

// Labels the automation depends on. `reconciliation` already existed
// (created implicitly by the first reconciler issue) and is adopted.
import {
  to = github_issue_label.automation["reconciliation"]
  id = "${var.github_repo}:reconciliation"
}

resource "github_issue_label" "automation" {
  for_each = {
    reconciliation = {
      color       = "D93F0B"
      description = "Opened by reconcile.yml: the organisation does not match the catalogue"
    }
    app-request = {
      color       = "0E8A16"
      description = "A request to install a GitHub App or widen its access (issue form)"
    }
  }

  repository  = github_repository.governance.name
  name        = each.key
  color       = each.value.color
  description = each.value.description
}

// ---------------------------------------------------------------------------
// The team that reviews it
// ---------------------------------------------------------------------------

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
  repository = github_repository.governance.name
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

// Adding someone who is not yet in the organisation sends them an invitation;
// they appear here, and can review, once they accept it.
resource "github_team_members" "platform_engineering" {
  team_slug = github_team.platform_engineering.slug

  dynamic "members" {
    for_each = var.platform_team_members
    content {
      // The API returns member logins lowercased. Without normalising here,
      // any capitalisation in the variable produces a permanent diff.
      username = lower(members.key)
      role     = members.value
    }
  }
}

// ---------------------------------------------------------------------------
// Rules on main
// ---------------------------------------------------------------------------

// A repository ruleset rather than classic branch protection: rulesets apply
// to administrators unless they are listed as bypass actors, and are readable
// without an admin token (OpenSSF Scorecard verifies them).
//
// There are NO bypass actors. Every change, including an owner's, needs a
// green validate and terraform-plan and an approval from a code owner other
// than the last pusher. Break-glass — CI itself broken — is a deliberate,
// audited change to this resource: add an OrganizationAdmin bypass actor,
// apply, fix, remove it (docs/OPERATIONS.md, "Break-glass").
resource "github_repository_ruleset" "governance_main" {
  name        = "main"
  repository  = github_repository.governance.name
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
      require_code_owner_review         = true
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = true
      required_review_thread_resolution = true
      allowed_merge_methods             = ["squash"]
    }

    // validate       - job in terraform-validate.yml: fmt/validate/lint of
    //                  the PR's own code, no credentials.
    // terraform-plan - commit status posted on the PR head by
    //                  terraform-plan.yml, which runs main's code on the PR's
    //                  catalogue data. A status rather than the job's check
    //                  run, because pull_request_target runs against the base
    //                  commit and GitHub does not document that its check run
    //                  attaches to the PR head.
    required_status_checks {
      strict_required_status_checks_policy = true

      required_check {
        context = "validate"
      }
      required_check {
        context = "terraform-plan"
      }
    }
  }
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
  repository        = github_repository.governance.name
  environment       = "plan"
  can_admins_bypass = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment" "plan_code" {
  repository        = github_repository.governance.name
  environment       = "plan-code"
  can_admins_bypass = false

  // Whoever pushed the code cannot release the credential to it.
  prevent_self_review = true

  // The team, not named individuals: whoever is on the platform team can
  // release a run, and leaving the team revokes it.
  reviewers {
    teams = [tonumber(github_team.platform_engineering.id)]
  }
}

resource "github_repository_environment" "production" {
  repository        = github_repository.governance.name
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

  repository     = github_repository.governance.name
  environment    = each.value
  branch_pattern = "main"
}
