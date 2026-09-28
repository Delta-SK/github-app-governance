# 0007 — Policy settings are code; the catalogue is data

Accepted, 2026-09-26.

## Context

Catalogue pull requests are planned automatically with the admin token
(0002). Anything a `*.tfvars` file can set, a catalogue pull request can set.

## Decision

- Only data is a variable: the repositories, the app catalogue, the
  tombstones. Everything that judges them — review tiers and grace period,
  quarantine repository, organisation — is a local in
  `terraform/settings.tf`.
- Installation IDs are not data at all: they are looked up from the live
  installation by slug.
- The pull request is the only request channel: a new-app entry's plan stays
  red ("not installed") until an owner installs the app.

## Consequences

- A catalogue file that sets a policy value is ignored with an "undeclared
  variable" warning and still judged by the real rules (verified).
- Changing policy is a code change: reviewed by the platform team and planned
  by the code plan.
