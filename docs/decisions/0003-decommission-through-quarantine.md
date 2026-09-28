# 0003 — Revoke through a quarantine repository; release before uninstalling

Accepted, 2026-09-25.

## Context

Behaviour of `github_app_installation_repositories` in `integrations/github`
6.13, read from `resource_github_app_installation_repositories.go`:

| Operation | Behaviour |
| --- | --- |
| update | adds new repositories, then removes old ones |
| update to `[]` | skips every removal and reports success; every later plan shows the same diff |
| destroy | removes every repository **except one arbitrary one** (GitHub forbids removing the last) |
| read of a missing installation | errors, failing every plan |

A Terraform `removed` block cannot target a single `for_each` instance, so an
entry cannot be dropped from state without calling the provider.

## Decision

- Revoked access is expressed as "reaches only `app-quarantine`", an empty
  repository. Empty repository lists are rejected. Update's add-then-remove
  order makes the move safe.
- Decommissioning is staged: quarantine (`decommissioning = true`), soak,
  **release** (the entry moves to `decommissioned.auto.tfvars`, which destroys
  the resource — leaving exactly the quarantine repository), then uninstall in
  the organisation settings.
- `scripts/plan-guard.sh` refuses any plan that releases an app still reaching
  real repositories, or deletes a repository — in the pull request (advisory)
  and in the apply job on `main` (enforcing).
- Removed apps leave a tombstone; a tombstoned app found installed again is
  reported with the reason it was removed.

## Consequences

- An app uninstalled by hand while catalogued breaks every plan until its
  entry is removed; the runbook's order avoids it.
- Uninstalling is a human step on plans below Enterprise Cloud (0001).
