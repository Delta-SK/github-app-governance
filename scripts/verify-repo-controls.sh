#!/usr/bin/env bash
# Verify the controls protecting THIS repository are still in place.
#
# Usage:  GH_TOKEN=<admin token> scripts/verify-repo-controls.sh <owner/repo>
#
# These controls are created by bootstrap/, which is applied by hand and has
# its own state on purpose: CI must not be able to rewrite the controls that
# constrain it. The cost of that separation is that nothing in CI notices if
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

prot=$(get "repos/$repo/branches/main/protection")
for ctx in validate terraform-plan; do
  jq -e --arg c "$ctx" '.required_status_checks.contexts // [] | index($c)' <<<"$prot" >/dev/null ||
    problem "main does not require the '$ctx' status check"
done
jq -e '.required_pull_request_reviews.require_code_owner_reviews == true' <<<"$prot" >/dev/null ||
  problem "main does not require CODEOWNER review"
jq -e '(.required_pull_request_reviews.required_approving_review_count // 0) >= 1' <<<"$prot" >/dev/null ||
  problem "main does not require an approving review"
jq -e '.allow_force_pushes.enabled == false' <<<"$prot" >/dev/null ||
  problem "force pushes to main are allowed (or main is unprotected)"

# The trust model (README, "The trust boundary"): the credential is reachable
# only from workflow definitions on a protected branch (plan, production), or
# after a human approves (plan-code, which runs pull request code).
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

plan_code=$(get "repos/$repo/environments/plan-code")
jq -e '[.protection_rules[]?.type] | index("required_reviewers")' <<<"$plan_code" >/dev/null ||
  problem "the 'plan-code' environment has no required reviewers — pull request code could read TF_GITHUB_TOKEN unattended"
jq -e '.can_admins_bypass == false' <<<"$plan_code" >/dev/null ||
  problem "administrators can bypass the 'plan-code' environment's required reviewers"

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
