// The governance repository itself, its rules, environments and reviewing
// team. Separate from ../terraform so CI cannot rewrite the controls that
// constrain it (docs/decisions/0006).

provider "github" {
  owner = var.github_org
}

// ---------------------------------------------------------------------------
// The governance repository itself
// ---------------------------------------------------------------------------

// Adopted, not created; the import block is a no-op once in state.
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
  // A wiki is edited outside pull requests: an unreviewed channel.
  has_wiki = false

  // One commit per change, carrying the pull request's justification.
  allow_merge_commit          = false
  allow_rebase_merge          = false
  allow_squash_merge          = true
  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "PR_BODY"
  delete_branch_on_merge      = true
  // Branches must be up to date; this offers the button.
  allow_update_branch = true

  // Push protection stops a leaked token at `git push`.
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

// Security fixes as pull requests, beside the weekly version updates.
resource "github_repository_dependabot_security_updates" "governance" {
  repository = github_repository.governance.name
  enabled    = true

  depends_on = [github_repository_vulnerability_alerts.governance]
}

// Private vulnerability reporting (SECURITY.md) has no provider resource: an
// idempotent PUT, verified weekly by scripts/verify-repo-controls.sh.
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

// The reconciler's label; adopted.
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
  }

  repository  = github_repository.governance.name
  name        = each.key
  color       = each.value.color
  description = each.value.description
}

// Role ARNs for the workflows, so none is copied by hand; two adopted.
import {
  to = github_actions_variable.role_arn["AWS_PLAN_ROLE_ARN"]
  id = "${var.github_repo}:AWS_PLAN_ROLE_ARN"
}

import {
  to = github_actions_variable.role_arn["AWS_APPLY_ROLE_ARN"]
  id = "${var.github_repo}:AWS_APPLY_ROLE_ARN"
}

resource "github_actions_variable" "role_arn" {
  for_each = {
    AWS_PLAN_ROLE_ARN  = aws_iam_role.plan.arn
    AWS_APPLY_ROLE_ARN = aws_iam_role.apply.arn
    AWS_AUDIT_ROLE_ARN = aws_iam_role.audit.arn
  }

  repository    = github_repository.governance.name
  variable_name = each.key
  value         = each.value
}

// ---------------------------------------------------------------------------
// The team that reviews it
// ---------------------------------------------------------------------------

// CODEOWNERS routes nothing unless the team exists, is visible, and can push.
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

// Teams that own catalogued apps (the demo org has no other source of teams).
resource "github_team" "app_owners" {
  for_each = var.app_owner_teams

  name        = each.key
  description = each.value
  privacy     = "closed"
}

// New members receive an organisation invitation and review once they accept.
resource "github_team_members" "platform_engineering" {
  team_slug = github_team.platform_engineering.slug

  dynamic "members" {
    for_each = var.platform_team_members
    content {
      // The API returns logins lowercased; avoids a permanent diff.
      username = lower(members.key)
      role     = members.value
    }
  }
}

// ---------------------------------------------------------------------------
// Rules on main
// ---------------------------------------------------------------------------

// No bypass actors; break-glass is a change to this resource
// (docs/decisions/0005, docs/OPERATIONS.md "Break-glass").
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

    // terraform-plan is a commit status, not a check run (docs/decisions/0002).
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
// Environments: where each credential is reachable (docs/decisions/0002)
//   plan, production  main only; TF_GITHUB_TOKEN (admin)
//   plan-code         any ref, no reviewer; TF_GITHUB_READ_TOKEN only
// ---------------------------------------------------------------------------

resource "github_repository_environment" "plan" {
  repository        = github_repository.governance.name
  environment       = "plan"
  can_admins_bypass = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

// Deliberately open: it holds only the read-only token.
resource "github_repository_environment" "plan_code" {
  repository        = github_repository.governance.name
  environment       = "plan-code"
  can_admins_bypass = false
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
