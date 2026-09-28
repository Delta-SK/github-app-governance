# 0006 — Bootstrap is applied by hand, in its own state, and drift-planned weekly

Accepted, 2026-09-25; drift detection 2026-09-28.

## Context

`bootstrap/` holds the controls that constrain the pipeline: the state
backend and CI roles, this repository's settings and ruleset, its
environments, the reviewing team. If the pipeline applied them, a merged
change could weaken the controls on the next change, or lock the repository.

## Decision

- Bootstrap has its own state and is applied only by an organisation owner.
  CI can read nothing that lets it write bootstrap's resources or state.
- The weekly reconciler plans bootstrap read-only with an audit role (main
  only; bootstrap state and the resources' metadata, the calls a plan was
  observed making). Drift in anything bootstrap manages is found by the code
  that defines it.
- `scripts/verify-repo-controls.sh` covers only what that plan cannot see:
  settings with no Terraform resource (private vulnerability reporting),
  secret placement, CODEOWNERS validity, and things added beside managed
  resources (an extra deployment-branch policy).

## Consequences

- Drift is detected weekly, repaired by a person.
- The audit role's permissions follow the provider: an upgrade that reads a
  new attribute fails the drift check until the action is added.
