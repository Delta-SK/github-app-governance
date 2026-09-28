#!/usr/bin/env bash
# Refuse plans that release an app still reaching real repositories (the
# provider would leave it on one arbitrary repository) or delete a repository.
# docs/decisions/0003. Advisory in pull requests, enforcing in the apply job.
#
# Usage (from terraform/):  ../scripts/plan-guard.sh tfplan

set -euo pipefail

plan_file=${1:?usage: plan-guard.sh <planfile>}
plan_json=$(terraform show -json "$plan_file")
quarantine=$(jq -r '.planned_values.outputs.quarantine_repository.value // empty' <<<"$plan_json")
if [ -z "$quarantine" ]; then
  echo "::error title=plan-guard::The plan has no quarantine_repository output; cannot evaluate the guard." >&2
  exit 1
fi

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
