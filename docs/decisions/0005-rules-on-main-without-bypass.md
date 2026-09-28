# 0005 — Rules on `main` are a ruleset with no bypass actors

Accepted, 2026-09-26.

## Context

Classic branch protection with `enforce_admins = false` let organisation
owners push to `main` without a plan or review, and OpenSSF Scorecard could
not read it without an admin token.

## Decision

A repository ruleset on the default branch, managed in `bootstrap/`:
`validate` and `terraform-plan` required, branch up to date, one code-owner
approval of the latest push by someone other than its author, stale
approvals dismissed, conversations resolved, squash only, no force-push or
deletion — and **no bypass actors**. Break-glass is a deliberate ruleset
change: add an `OrganizationAdmin` bypass actor, apply, repair, remove it.
The managed repositories get the same kind of ruleset from `terraform/`.

## Consequences

- No change reaches `main` on one person's say-so, owners included.
- Break-glass is slower than a button, and every use is visible in the
  ruleset's history and flagged by the reconciler until removed.
- The test organisation's second reviewer, `Approver777`, is a demonstration
  identity: it exercises the mechanism, not independent judgement. Merges
  #1–#7 predate it and used the owner bypass.
