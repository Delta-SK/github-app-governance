#!/usr/bin/env bash
# Plan, evaluate the governance checks and the destroy guard, and write the
# pull request comment. Shared by both plan workflows. Exit 1 only if the plan
# or the guard fails; governance checks are warnings.
#
# Usage (from terraform/, after init, GITHUB_TOKEN set; REPORT_NOTE optional):
#   ../scripts/plan-report.sh "<comment heading>" <report.md>

set -uo pipefail

heading=${1:?usage: plan-report.sh <heading> <report.md>}
report=${2:?usage: plan-report.sh <heading> <report.md>}
here=$(dirname "$0")

terraform plan -no-color -input=false -lock=false -out=tfplan >plan.txt 2>&1
plan_exit=$?
cat plan.txt # into the job log as well

plan_result=failure
guard_result=skipped
guard_errors=""
failed_checks=""

if [ "$plan_exit" -eq 0 ]; then
  plan_result=success
  # Checks are warnings and do not move the exit code; read them from the
  # saved plan instead.
  failed_checks=$(terraform show -json tfplan |
    jq -r '[.checks[]? | select(.status == "fail") | .address.to_display] | join(", ")')

  if guard_out=$(bash "$here/plan-guard.sh" tfplan 2>&1); then
    guard_result=success
  else
    guard_result=failure
    guard_errors=$(sed -n 's/^::error[^:]*:://p' <<<"$guard_out")
  fi
fi

# GitHub rejects comments over 65536 characters.
plan_text=$(head -c 60000 plan.txt)
[ "$(wc -c <plan.txt)" -gt 60000 ] && plan_text+=$'\n\n...truncated, see the workflow log.'

{
  echo "$heading"
  echo
  echo "| check | result |"
  echo "| --- | --- |"
  echo "| plan | $plan_result |"
  echo "| destroy guard | $guard_result |"
  echo "| governance checks | ${failed_checks:+⚠️ }${failed_checks:-all pass} |"
  echo
  if [ -n "${REPORT_NOTE:-}" ]; then
    echo "$REPORT_NOTE"
    echo
  fi
  if [ -n "$guard_errors" ]; then
    echo "**Destroy guard refused this plan:**"
    echo
    while IFS= read -r line; do echo "> $line"; done <<<"$guard_errors"
    echo
  fi
  echo "<details><summary>Show plan</summary>"
  echo
  echo '```terraform'
  echo "$plan_text"
  echo '```'
  echo
  echo "</details>"
  echo
  echo "_Governance checks warn without failing — an orphan elsewhere in the org should not block your change. What each one means: docs/OPERATIONS.md._"
} >"$report"

[ "$plan_result" = success ] && [ "$guard_result" = success ]
