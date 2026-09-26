#!/usr/bin/env bash
# Verify the controls protecting THIS repository are still in place.
#
# Usage:  GH_TOKEN=<admin token> scripts/verify-repo-controls.sh <owner/repo>
#
# These controls are created by bootstrap/, which is applied by hand and has
# its own state on purpose: CI must not be able to rewrite the controls that
# constrain it. (Private vulnerability reporting is the one set through the
# REST API, from bootstrap, because the provider has no resource for it.) The cost of that separation is that nothing in CI notices if
# somebody weakens them in the GitHub UI. This script is that notice. It is
# read-only and runs weekly from reconcile.yml; exit 1 means a control is
# missing, with one "- " line per problem on stdout.

set -uo pipefail

repo=${1:?usage: verify-repo-controls.sh <owner/repo>}
failed=0
problem() { echo "- $*"; failed=1; }

# gh prints the error body to stdout on failure, so discard it explicitly.
get() {
  local out
  out=$(gh api "$1" 2>/dev/null) || out='{}'
  echo "$out"
}

# Rules in force on main, whichever ruleset they come from. Readable without
# an admin token, which is one reason this repository uses rulesets.
rules=$(gh api "repos/$repo/rules/branches/main" 2>/dev/null) || rules='[]'
rule() { jq -e --arg t "$1" "[.[] | select(.type == \$t) | $2] | any" <<<"$rules" >/dev/null; }

rule pull_request '.parameters.required_approving_review_count >= 1' ||
  problem "main does not require an approving review"
rule pull_request '.parameters.require_code_owner_review == true' ||
  problem "main does not require CODEOWNER review"
rule pull_request '.parameters.require_last_push_approval == true' ||
  problem "main does not require the last push to be approved by someone else"
rule pull_request '.parameters.dismiss_stale_reviews_on_push == true' ||
  problem "main keeps approvals after new pushes"
for ctx in validate terraform-plan; do
  rule required_status_checks "any(.parameters.required_status_checks[]; .context == \"$ctx\")" ||
    problem "main does not require the '$ctx' status check"
done
rule non_fast_forward 'true' || problem "force pushes to main are allowed"
rule deletion 'true' || problem "main can be deleted"

# No standing bypass: break-glass is a deliberate, audited ruleset change.
for id in $(jq -r '[.[].ruleset_id] | unique | .[]' <<<"$rules"); do
  bypass=$(gh api "repos/$repo/rulesets/$id" --jq '[.bypass_actors[]? | .actor_type] | join(",")' 2>/dev/null) || bypass=unknown
  [ -z "$bypass" ] ||
    problem "ruleset $id on main has bypass actors ($bypass) — if this is break-glass, remove them when done"
done

# Secret protection and a private reporting channel for SECURITY.md.
repo_json=$(get "repos/$repo")
for feature in secret_scanning secret_scanning_push_protection; do
  jq -e --arg f "$feature" '.security_and_analysis[$f].status == "enabled"' <<<"$repo_json" >/dev/null ||
    problem "$feature is not enabled"
done
jq -e '.enabled == true' <<<"$(get "repos/$repo/private-vulnerability-reporting")" >/dev/null ||
  problem "private vulnerability reporting is off — SECURITY.md points reporters to it"

# The trust model (README, "The trust boundary"): the admin credential is
# reachable only from workflow definitions on main (plan, production). Pull
# request code (plan-code) gets a read-only token.
for env in plan production; do
  env_json=$(get "repos/$repo/environments/$env")
  policies=$(gh api "repos/$repo/environments/$env/deployment-branch-policies" \
    --jq '[.branch_policies[] | "\(.type):\(.name)"] | sort | join(",")' 2>/dev/null) || policies=unknown
  { jq -e '.deployment_branch_policy.custom_branch_policies == true' <<<"$env_json" >/dev/null &&
    [ "$policies" = "branch:main" ]; } ||
    problem "the '$env' environment is not restricted to main alone (policies: ${policies:-none}) — other branches could read TF_GITHUB_TOKEN"
  jq -e '.can_admins_bypass == false' <<<"$env_json" >/dev/null ||
    problem "administrators can bypass the '$env' environment's protection rules"
done

# plan-code runs pull request code automatically, with no reviewer. That is
# safe only while it holds the read-only token and never the admin one.
plan_code_secrets=$(gh api "repos/$repo/environments/plan-code/secrets" \
  --jq '[.secrets[].name] | join(",")' 2>/dev/null) || plan_code_secrets=unknown
case ",$plan_code_secrets," in
*,TF_GITHUB_TOKEN,*)
  problem "the 'plan-code' environment holds TF_GITHUB_TOKEN — pull request code runs there unattended and must only ever see TF_GITHUB_READ_TOKEN"
  ;;
*,TF_GITHUB_READ_TOKEN,*) ;;
*)
  problem "the 'plan-code' environment has no TF_GITHUB_READ_TOKEN (secrets: ${plan_code_secrets:-none}) — code plans will fail"
  ;;
esac

secrets=$(gh api "repos/$repo/actions/secrets" --jq .total_count 2>/dev/null) || secrets=unknown
[ "$secrets" = "0" ] ||
  problem "repository-level Actions secrets present (count: $secrets) — credentials must be environment-scoped"

# A CODEOWNERS entry naming a team that does not exist routes nothing while
# looking like a control. GitHub reports such lines here.
co_errors=$(gh api "repos/$repo/codeowners/errors" --jq '.errors | length' 2>/dev/null) || co_errors=unknown
[ "$co_errors" = "0" ] ||
  problem "CODEOWNERS has errors (count: $co_errors) — see the file view on GitHub"

[ "$failed" -eq 0 ] && echo "All repository controls in place."
exit "$failed"
