# 0008 — App permissions are recorded and compared, not enforced

Accepted, 2026-09-26.

## Context

Terraform enforces which repositories an app reaches. What it can do there is
part of the app, and widens outside any pull request: an app update requests
more, and an owner accepts in the UI.

## Decision

Each catalogue entry records its approved `permissions`. Every plan and the
weekly reconciler compare them with the live installation, both ways. A
difference is a warning naming each permission that moved; the response is a
pull request that records the change — approving it — or decommissions the
app. Permissions also set the review tier (0004).

## Consequences

- Scope is enforced as code; capability is audited as code. A widened
  permission is visible within a week, not prevented.
- Apps being decommissioned or quarantined by a lapsed review are left out:
  their permissions no longer matter.
