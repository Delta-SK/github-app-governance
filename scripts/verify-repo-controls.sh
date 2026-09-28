#!/usr/bin/env bash
# Check the controls on THIS repository that a plan of bootstrap/ cannot see.
#
# Usage:  GH_TOKEN=<admin token> scripts/verify-repo-controls.sh <owner/repo>
#
# The weekly reconciler plans bootstrap/ read-only, which catches any change
# to what Terraform manages there: rulesets, environments, repository
# settings, the team. Two kinds of control fall outside that, and only those
# are checked here:
#   - settings Terraform does not manage: private vulnerability reporting (no
#     provider resource), secret placement (values are never in state), and
#     CODEOWNERS validity (a file, not a setting);
#   - things added BESIDE managed resources, which Terraform never reads: an
#     extra deployment-branch policy on an environment widens who can reach
#     its token without touching the policy Terraform manages.
#
# Read-only. Exit 1 means a control is missing, one "- " line per problem.

set -uo pipefail

repo=${1:?usage: verify-repo-controls.sh <owner/repo>}
failed=0
problem() { echo "- $*"; failed=1; }

# The admin token must be reachable from main only.
for env in plan production; do
  policies=$(gh api "repos/$repo/environments/$env/deployment-branch-policies" \
    --jq '[.branch_policies[] | "\(.type):\(.name)"] | sort | join(",")' 2>/dev/null) || policies=unknown
  [ "$policies" = "branch:main" ] ||
    problem "the '$env' environment admits more than main (policies: ${policies:-none}) — other refs could read TF_GITHUB_TOKEN"
done

# plan-code runs pull request code with no reviewer: read-only token only.
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
  problem "repository-level Actions secrets present (count: $secrets) — every job could read them; credentials must be environment-scoped"

pvr=$(gh api "repos/$repo/private-vulnerability-reporting" --jq .enabled 2>/dev/null) || pvr=unknown
[ "$pvr" = "true" ] ||
  problem "private vulnerability reporting is off — SECURITY.md points reporters to it"

# A CODEOWNERS entry naming a team that does not exist routes nothing.
co_errors=$(gh api "repos/$repo/codeowners/errors" --jq '.errors | length' 2>/dev/null) || co_errors=unknown
[ "$co_errors" = "0" ] ||
  problem "CODEOWNERS has errors (count: $co_errors) — see the file view on GitHub"

[ "$failed" -eq 0 ] && echo "All controls outside Terraform in place."
exit "$failed"
