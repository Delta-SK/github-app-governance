# GitHub App Governance

GitOps-managed control of **which repositories each installed GitHub App can
reach**, in the `Delta-SK` organisation.

Changing an app's access is a pull request. Nothing is configured by hand in
the GitHub UI.

---

## The problem this solves

An organisation accumulates GitHub Apps. Each one is installed by somebody, for
some reason, at some point — and none of that is recorded anywhere. After a
year nobody can answer: who owns this app, why does it have access to the
payments repository, and is it still needed?

This repository makes app access **declarative**, **reviewable**, and
**auditable**: the catalogue is the authorisation record, a pull request is the
approval, and `terraform apply` is the enforcement.

---

## Architecture

```
terraform/catalogue.auto.tfvars      <- source of truth: apps, owners, access
        |
        |  pull request
        v
.github/workflows/terraform-plan.yml   fmt / validate / plan -> PR comment
        |
        |  merge to main
        v
.github/workflows/terraform-apply.yml  terraform apply
        |
        v
GitHub org: app installation repository access
State: s3://delta-sk-tfstate-751569314116 (DynamoDB lock)
```

| Path | Purpose |
| --- | --- |
| `terraform/catalogue.auto.tfvars` | The catalogue. Apps, owners, review dates, repo access |
| `terraform/app_access.tf` | Enforces repo access per app (`github_app_installation_repositories`) |
| `terraform/repositories.tf` | Repositories and branch protection as code |
| `terraform/checks.tf` | Orphan detection, scope validation, review-date expiry |
| `terraform/data.tf` | Live installation inventory from the org |
| `bootstrap/` | S3 state bucket, DynamoDB lock table, AWS OIDC role. Applied once |
| `docs/GOVERNANCE.md` | Ownership, review, expiry, orphan detection, decommissioning |

### Why the catalogue is one file

`catalogue.auto.tfvars` carries both the *intent* (which repos) and the
*justification* (owner, purpose, review date). A reviewer reads one diff and
sees the whole change. An auditor reads one file and sees the whole estate.

At organisation scale this splits into `catalogue/<team>.auto.tfvars` with
CODEOWNERS routing review per team. The schema does not change.

---

## Prerequisites

- Terraform `~> 1.9.0`
- An AWS account (state backend) with credentials available locally
- A GitHub organisation where you are an **owner**
- A **classic** personal access token with `repo` and `admin:org` scopes.
  Add `workflow` as well if you intend to push changes to
  `.github/workflows/` — GitHub rejects such pushes otherwise. The token
  Actions uses at runtime (`TF_GITHUB_TOKEN`) does **not** need `workflow`;
  only the developer pushing the files does.
  `delete_repo` is deliberately **not** granted: Terraform never deletes
  repositories here, so the token cannot either.
- At least two GitHub Apps installed on the org, each set to
  **"Only select repositories"**

---

## Authentication

### Why a classic PAT, and not a GitHub App

This is the most important design constraint in the project, and it is not
obvious.

`github_app_installation_repositories` calls these endpoints:

```
GET    /user/installations/{installation_id}/repositories
PUT    /user/installations/{installation_id}/repositories/{repository_id}
DELETE /user/installations/{installation_id}/repositories/{repository_id}
```

These are **user-to-server** endpoints. A GitHub App installation token is a
*server-to-server* credential and cannot call `/user/...` at all. Neither can
the `GITHUB_TOKEN` that GitHub Actions injects automatically.

So the usual best practice — authenticate Terraform as a GitHub App — **cannot
drive the core resource of this project.** A classic PAT belonging to an org
owner is the credential that works.

One further trap, worth knowing before you debug it yourself: the sibling
endpoint `GET /user/installations` (list *all* installations) **does** reject
classic PATs with `403 "You must authenticate with an access token authorized
to a GitHub App"`. It is easy to hit that, conclude PATs are unusable here, and
go build an OAuth flow you do not need. The provider never calls that endpoint.
The per-installation endpoints above accept classic PATs normally — verified
against this org by `PUT` and `DELETE` returning `204`.

### Fine-grained PATs do not work — tested

The obvious way to shrink this credential is a fine-grained token scoped to one
organisation. It does not work, and the failure is architectural rather than a
permissions mistake. Tested against this org with `Administration: Read/Write`
at both repository and organisation level:

| Endpoint | Fine-grained PAT |
| --- | --- |
| `/orgs/{org}/installations` | **200** — the audit read works |
| `/user/installations/{id}/repositories` (read) | **403** |
| `/user/installations/{id}/repositories/{repo}` (write) | **403** |

The rejection is `Resource not accessible by personal access token`, which is
GitHub's generic signal that an endpoint has **no fine-grained support at
all** — not that a permission is missing. No combination of toggles enables it.

Note the split: the **audit** half of this project is reachable with a
fine-grained token, the **enforcement** half is not. A read-only reconciler
could therefore run on a much weaker credential than the applier, if the
reconciler were rewritten to query the installations API directly instead of
running `terraform plan`.

With GitHub App auth, fine-grained PATs and `GITHUB_TOKEN` all excluded, a
classic PAT is the only credential that drives this resource. That is a
constraint of the GitHub API, not a design choice, and it is why the blast
radius is managed by *who owns the token* rather than by scoping it.

### What this costs, and what it would cost at scale

A human-owned PAT is the weak point of this design. It is long-lived, bound to
one person, and carries `admin:org` across every org that person belongs to.

For production, in order of preference:

1. A dedicated **machine user** holding the PAT, with org-owner rights and
   nothing else, credential in a secrets manager with enforced rotation.
2. Scope the blast radius by running this from a dedicated org-admin identity
   used for no other purpose.
3. Push GitHub for a server-to-server API for installation repository access;
   until that exists, the user-to-server requirement is a hard constraint.

### The trust boundary

The single most important thing to understand about this CI setup: **the plan
job runs untrusted code.**

For `pull_request` events GitHub executes the workflow definition from the
*pull request head*, not from `main`. Anyone who can push a branch can rewrite
the plan job and have it run whatever they like — before any review exists,
because the job starts the moment the PR opens. Required reviews do not help
here; the attacker never needs the pull request merged.

Since this repository's credential is an org-owner PAT, that path has to be
closed structurally rather than procedurally. Two controls do it:

| Control | Effect |
| --- | --- |
| `TF_GITHUB_TOKEN` lives in the `plan` **environment**, with required reviewers | The credential is released per run, by a human who has seen the diff. It is not a repository secret, so no job can read it implicitly |
| Plan assumes a **read-only** AWS role (`s3:GetObject` only) | Even holding the credential, the job cannot write or delete state. No DynamoDB access at all, since plan runs `-lock=false` |

There are **no repository-level secrets** in this repo — verify with
`gh secret list`, which returns nothing. Everything is environment-scoped.

Apply is a different case: it runs code already merged to `main`, which has
been through review. Its environment pins the credential to protected branches
rather than gating on a reviewer, because the pull request was the gate.

### AWS

GitHub Actions assumes one of two roles via **OIDC**. No AWS keys are stored in
GitHub.

| Role | Trusted subject | Permissions |
| --- | --- | --- |
| `github-app-governance-plan` | `:pull_request`, `:ref:refs/heads/main` | `s3:GetObject`, `s3:ListBucket` |
| `github-app-governance-apply` | `:ref:refs/heads/main` | full state read/write + DynamoDB lock |

The plan role additionally trusts `main` so the scheduled reconciler can read
state; it still cannot mutate anything.

**The OIDC subject claim is not the documented format.** GitHub issues it with
immutable numeric IDs embedded:

```
repo:Delta-SK@333749275/github-app-governance@1387485403:ref:refs/heads/main
```

not the `repo:OWNER/REPO:ref:...` shown in most published examples. A trust
policy written in the older form fails with `Not authorized to perform
sts:AssumeRoleWithWebIdentity` and no indication of why.

This is a security feature, not an annoyance: pinning the IDs means a deleted
and recreated organisation or repository of the same name does **not** inherit
the trust policy. `bootstrap/variables.tf` therefore pins `github_org_id` and
`github_repo_id`, with the lookup commands in a comment there.

To see the claim your own repository issues, dispatch a workflow that prints
`$ACTIONS_ID_TOKEN_REQUEST_URL`'s decoded payload — faster than guessing.

| Name | Kind | Scope | Value |
| --- | --- | --- | --- |
| `TF_GITHUB_TOKEN` | secret | **environment** `plan` + `production` | classic PAT (`repo`, `admin:org`) |
| `AWS_PLAN_ROLE_ARN` | variable | repository | read-only state role |
| `AWS_APPLY_ROLE_ARN` | variable | repository | read-write state role |

`TF_GITHUB_TOKEN` cannot be called `GITHUB_TOKEN` — that name is reserved by
Actions. The workflows map it into the `GITHUB_TOKEN` environment variable at
the step level, which is where the provider reads it from.

---

## Setup

### 1. Bootstrap the backend (once)

```bash
cd bootstrap
terraform init
terraform apply
```

Creates the S3 bucket, the DynamoDB lock table, the GitHub OIDC provider, both
CI roles, the `platform-engineering` team, this repository's branch protection,
and the two Actions environments.

Against a **fresh AWS account**, comment out the `backend "s3"` block in
`bootstrap/main.tf` for the first apply — it cannot use a bucket that does not
exist yet. Then restore the block and migrate:

```bash
terraform init -migrate-state
```

That moves bootstrap's own state into the bucket it just created, so no
unbacked-up local state file is left behind. It is the one genuine
chicken-and-egg step in the setup, and it only happens once.

Copy the outputs into `terraform/versions.tf` (backend block) and into the
repository variables `AWS_PLAN_ROLE_ARN` and `AWS_APPLY_ROLE_ARN`.

`TF_GITHUB_TOKEN` must be set as an **environment** secret on both `plan` and
`production` — not as a repository secret. A repository secret is readable by
every job, which would defeat the reviewer gate on `plan`.

### 2. Install the apps

Install each app on the org and set it to **"Only select repositories"**. An
installation set to *All repositories* exposes no per-repo scope, so there is
nothing for Terraform to govern — `checks.tf` fails the plan if it finds one.

### 3. Record installation IDs

```bash
cd terraform
export GITHUB_TOKEN=ghp_...
terraform init
terraform apply          # first apply creates repos and applies access
terraform output org_installations
```

`org_installations` lists every installation in the org with its ID and whether
it is declared. Copy the IDs into `catalogue.auto.tfvars`.

This ordering is unavoidable: an app must already be installed before its
access can be managed, and Terraform cannot install apps (see *Limitations*).

---

## How a change flows

Narrowing Renovate from two repositories to one:

1. Branch, and edit `terraform/catalogue.auto.tfvars`:

   ```hcl
   renovate = {
     repositories = [
       "payments-api",
   -   "web-frontend",
     ]
   }
   ```

2. Open a pull request. `terraform-plan` runs `fmt`, `validate` and `plan`, and
   posts the plan as a PR comment:

   ```
   ~ resource "github_app_installation_repositories" "this["renovate"]" {
       ~ selected_repositories = [
           - "web-frontend",
         ]
     }
   ```

3. CODEOWNERS requires platform-engineering review — the catalogue is an
   authorisation record, so a human approves the access change.

4. Merge. `terraform-apply` applies it and prints the resulting access matrix.

5. Verify against GitHub itself, not against state:

   ```bash
   curl -H "Authorization: Bearer $GITHUB_TOKEN" \
     https://api.github.com/user/installations/164801077/repositories \
     | jq -r '.repositories[].full_name'
   ```

---

## Inspecting the current state

```bash
cd terraform

terraform output app_access_matrix   # what Terraform intends
terraform output org_installations   # what is actually installed, declared or not
terraform plan -detailed-exitcode    # exit 0 = no drift, 2 = drift
```

Drift check, suitable for CI or a scheduled job:

```bash
terraform plan -detailed-exitcode -lock=false >/dev/null 2>&1
echo $?    # 0 clean, 2 drift, 1 error
```

---

## Governance checks

Controls run on every plan, and are split deliberately between **blocking**
and **warning**.

| Control | Detects | Severity |
| --- | --- | --- |
| `precondition` in `app_access.tf` | An app past its `review_by` date | **Blocks** the plan |
| `installations_are_declared` | An app installed in the org but absent from the catalogue — *the app nobody remembers installing* | Warns |
| (same block, 2nd assert) | A catalogued app installed as `repository_selection = all`, which silently cannot be governed | Warns |
| `reviews_are_due_soon` | An entry within `review_warning_days` (default 30) of expiry | Warns |

The split is the point. **Stale data you own blocks your own apply** — an
expiry date that never stops anything is decoration, so it is a resource
precondition rather than a `check` block. **Somebody else's rogue installation
does not block your unrelated change** — an orphan is a signal to investigate,
and halting all work until it is resolved would just teach people to bypass
the pipeline.

Both use `plantimestamp()` rather than `timestamp()`: the latter is unknown at
plan time, so the condition would only evaluate during apply — after review
rather than during it.

Detection does not depend on someone opening a pull request. `reconcile.yml`
runs the same checks weekly and opens a GitHub issue when the organisation
stops matching the catalogue, closing it automatically when it matches again.

To see the orphan detector fire, install any app on the org without adding it
to the catalogue, then run `terraform plan`. To see expiry block, set any
`review_by` to a past date.

Full design in [docs/GOVERNANCE.md](docs/GOVERNANCE.md).

---

## Pointing at a different organisation

1. Change `github_org` in `terraform/variables.tf` (or pass `-var`).
2. Point the backend elsewhere:

   ```bash
   terraform init -reconfigure \
     -backend-config="bucket=your-bucket" \
     -backend-config="key=github-app-governance/terraform.tfstate" \
     -backend-config="region=your-region" \
     -backend-config="dynamodb_table=your-lock-table"
   ```

3. Update `github_org`, `github_repo`, **`github_org_id` and `github_repo_id`**
   in `bootstrap/variables.tf` so the OIDC trust policy matches the new
   repository, along with `platform_team_members` and
   `environment_reviewer_ids`. Then re-apply `bootstrap/`. The two numeric IDs
   are the easiest thing to forget and produce the least helpful error — see
   *Authentication*.
4. Replace `installation_id` values in `catalogue.auto.tfvars` — they are
   per-installation and will not carry over.
5. Update the team names in `.github/CODEOWNERS`.

Nothing else is org-specific.

---

## Limitations

**Terraform cannot install or uninstall a GitHub App.** It manages only the
repository scope of an installation that already exists. Installing is a UI or
API action; uninstalling likewise. This shapes the decommissioning runbook —
Terraform narrows access to zero, a human removes the installation.

**Installation IDs are discovered, not derived.** They must be copied into the
catalogue. The `org_installations` output exists to make that a lookup rather
than a hunt.

**The access resource is authoritative.** Applying it removes any repository
access not in the catalogue. That is the point, but the first apply against an
existing org will revoke undeclared access — plan before applying to a live
organisation.

**A human-owned PAT is the root credential.** Discussed under *Authentication*.

**The test org is on the GitHub Free plan**, so the managed repositories are
**public** — branch protection is unavailable on private repositories on Free.
On a paid plan, set `visibility = "private"` in `repositories.tf`.

**A single-account organisation cannot satisfy its own review requirement.**
`main` requires one approving CODEOWNER review, but in this test org the only
member of `@Delta-SK/platform-engineering` is also the only author — and GitHub
does not permit self-approval. Merges here therefore use the org-owner bypass.
The control is correctly configured and would function normally with a second
engineer; it simply cannot be *demonstrated* satisfying itself. Adding one more
account to the org is the only real fix.

**Organisation owners can bypass branch protection** (`enforce_admins` is
false), so a determined admin can push to `main` without a plan. That mirrors
how most organisations run — owners retain break-glass access — but it does
mean branch protection is a guardrail here, not a hard boundary. Turning on
`enforce_admins` closes it, at the cost of needing a documented break-glass
procedure for the case where CI itself is broken.

**Automated decommissioning is documented but not implemented.** The escalation
ladder in `docs/GOVERNANCE.md` describes an auto-generated pull request that
narrows an expired app to zero repositories. Expiry currently blocks the plan
and the reconciler raises an issue; nothing opens that PR for you.

**Tombstones are a convention, not a control.** Nothing enforces that a removed
catalogue entry leaves a record behind.

**One catalogue, one state.** The per-team split described in
`docs/GOVERNANCE.md` is a design, not an implementation. At two apps it would
be premature; the point at which it stops being premature is discussed there.

---

## Intentionally omitted

In rough order of what I would add next:

- **Policy-as-code** (OPA/Conftest) for rules the type system cannot express —
  e.g. "no app may reach `payments-api` without a security review label".
- **Automated decommissioning workflow** — open the narrow-to-zero pull request
  automatically once an app passes expiry, rather than relying on the owner to
  act on the blocked plan.
- **A machine user for the PAT.** The credential is currently tied to a human
  account and carries `admin:org` across every organisation that account
  belongs to. A dedicated machine user with org-owner rights and nothing else
  would bound the blast radius. Environment gating limits *who can use* the
  credential; it does nothing about *how much it can reach*.
- **Per-team catalogue and state split**, at the point where a single plan
  becomes slow or a single reviewer becomes a bottleneck.
- **Permission-change detection.** This governs which repositories an app can
  reach, not what it can do there. An app version bump that widens its
  permission set is invisible to this configuration — see `docs/GOVERNANCE.md`
  §6, point 4.
