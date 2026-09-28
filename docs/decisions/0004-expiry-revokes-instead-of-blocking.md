# 0004 — A lapsed review revokes access instead of blocking plans; cadence follows risk

Accepted, 2026-09-28. Supersedes the first design, in which a passed
`review_by` failed every plan.

## Context

A precondition on `review_by` stopped every plan in the organisation while
any app was past its date. At 500 apps on annual review that is about ten
expiries a week: the pipeline blocked most of the time, green pull requests
turning red with no commit, and an incentive to rubber-stamp renewals to
unblock it. The same 366-day limit applied to an app that can rewrite
workflows as to a read-only one.

## Decision

- **Expiry revokes.** Status is computed per app on every plan: due soon (30
  days before), overdue (a 30-day grace period after `review_by`), lapsed.
  A lapsed app's access becomes the quarantine repository (0003); the next
  apply enforces it; renewing restores it. Nothing blocks.
- **Cadence follows risk**, from the app's approved permissions: write/admin
  on workflows, actions, administration, hooks, environments, secrets or
  members — 90 days; any other write — 180; read-only — 366. A date beyond the
  limit blocks only the pull request that sets it.
- Limits and grace period are code (0007).

## Consequences

- Plans depend on the date as well as the repository: the day after a grace
  period ends, a plan shows that app moving to quarantine. It is labelled in
  every plan comment and in the reconciler's issue.
- Enforcement waits for the next apply — a merge, or a manual run the
  reconciler asks for — not midnight.
- The default outcome of an unrenewed review is removal.
