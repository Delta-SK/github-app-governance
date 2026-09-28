# 0002 — Plan pull request data with main's code, and pull request code with a read-only token

Accepted, 2026-09-26.

## Context

For `pull_request` events GitHub runs the workflow definition from the pull
request itself. A plan job holding the organisation-admin token (0001) would
hand it to anyone who can push a branch, before any review. Gating every plan
on a human approval closes that, but then reviewers approve runs before they
can see a plan.

## Decision

The admin token only ever meets code that is already on `main`.

| Workflow | Code | Data | Credential | Approval |
| --- | --- | --- | --- | --- |
| `terraform-validate` | PR's | PR's | none | no |
| `terraform-plan` (`pull_request_target`) | `main`'s | PR's `*.auto.tfvars`, fetched as file contents by commit; symlinks refused | admin token | no |
| `terraform-plan-code` (code paths only) | PR's | PR's | read-only fine-grained token, `-refresh=false` | no |
| `terraform-apply` | `main`'s | `main`'s | admin token | the pull request review |

Variable files cannot execute anything, and the rules that judge them are
code, not variables (0007). The read-only token cannot read installation
repositories, so the code plan does not refresh: it shows the code change
against the last applied state.

`terraform-plan` reports a commit status (`terraform-plan`) on the pull
request's head: `pull_request_target` runs against the base commit, and GitHub
does not document that its check run attaches to the head. Apply never
reuses a pull request plan: it computes a plan of record from `main`, runs the
destroy guard on it, and applies exactly that.

## Consequences

- Every pull request is planned before review, with no approval anywhere but
  the review itself.
- Anyone who can push a branch can read the read-only token: the app
  inventory and team list. A read-only GitHub App would remove the human
  owner but not the exposure, since pull request code controls the job.
- `terraform-plan.yml` stays safe only while it never runs pull request code.
  CodeQL scans the workflows on every pull request; CODEOWNERS routes every
  change to them to the platform team.
- Status checks are evidence, not a boundary: a pull request can rewrite the
  workflows that produce them. The boundaries are this split, code-owner
  review, and the apply on `main`.
