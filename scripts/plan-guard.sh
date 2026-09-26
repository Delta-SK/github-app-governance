#!/usr/bin/env bash
# Refuse plans that would destroy something this pipeline must never destroy.
#
# Usage (from terraform/):  ../scripts/plan-guard.sh tfplan
#
# Terraform cannot express "you may not destroy X unless its prior state was
# Y" — a precondition on a resource disappears together with the resource.
# The saved plan can, because it records the before-state of every change.
#
# Guards:
#   1. Releasing an app (removing it from the catalogue) destroys its
#      github_app_installation_repositories resource. The provider then
#      removes every repository EXCEPT ONE ARBITRARY ONE, because GitHub
#      forbids removing the last. Unless the app is already narrowed to the
#      quarantine repository, that silently leaves it on a random real
#      repository. Quarantine first, release second.
#   2. This pipeline never deletes repositories. The token lacks delete_repo,
#      so the apply would fail halfway; refusing at plan time is clearer.
#
# Runs in the PR plan job (early feedback — that job runs untrusted code, so
# it is advisory there) and in the apply job on main (the enforcing copy).

set -euo pipefail

plan_file=${1:?usage: plan-guard.sh <planfile>}
plan_json=$(terraform show -json "$plan_file")
quarantine=$(jq -r '.variables.quarantine_repository.value' <<<"$plan_json")

violations=$(jq -r --arg q "$quarantine" '
  .resource_changes[]?
  | select(.change.actions | index("delete"))
  | if .type == "github_app_installation_repositories" then
      select((.change.before.selected_repositories // []) != [$q])
      | "\(.address) would be released while still reaching: \(.change.before.selected_repositories | join(", ")). The provider would leave it on one arbitrary repository of those. Quarantine it first (decommissioning = true, repositories = [\"\($q)\"]), merge, then release it in a second pull request."
    elif .type == "github_repository" then
      "\(.address) would be deleted. This pipeline never deletes repositories; see docs/OPERATIONS.md \"Stop managing a repository\"."
    else empty end
' <<<"$plan_json")

if [ -n "$violations" ]; then
  while IFS= read -r v; do
    echo "::error title=plan-guard::$v"
  done <<<"$violations"
  exit 1
fi

echo "plan-guard: no forbidden destroys."
