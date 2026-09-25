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

### AWS

GitHub Actions assumes `github-app-governance-ci` via **OIDC**. No AWS keys are
stored in GitHub. The role trusts exactly two subjects — `ref:refs/heads/main`
and `pull_request` — on this repository only.

| Name | Kind | Value |
| --- | --- | --- |
| `TF_GITHUB_TOKEN` | secret | classic PAT (`repo`, `admin:org`) |
| `AWS_ROLE_ARN` | variable | `arn:aws:iam::751569314116:role/github-app-governance-ci` |

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

Creates the S3 bucket, the DynamoDB lock table, the GitHub OIDC provider and
the CI role. It uses **local state by design** — it creates the very backend
everything else depends on. That state is gitignored; losing it means
re-importing four AWS resources, not losing the governed configuration.

Copy the outputs into `terraform/versions.tf` (backend block) and into the
repository variable `AWS_ROLE_ARN`.

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

`checks.tf` runs three assertions on every plan. They **warn rather than
block** — an orphaned app is a reason to investigate, not a reason to stop an
unrelated change.

| Check | Detects |
| --- | --- |
| `installations_are_declared` | An app installed in the org but absent from the catalogue — *the app nobody remembers installing* |
| (same block, 2nd assert) | A catalogued app installed as `repository_selection = all`, which silently cannot be governed |
| `app_reviews_are_current` | An entry whose `review_by` date has passed |

The expiry check uses `plantimestamp()` rather than `timestamp()` — the latter
is unknown at plan time, so the assertion would only evaluate during apply,
which is after review rather than during it.

To see the orphan detector fire, install any app on the org without adding it
to the catalogue, then run `terraform plan`.

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

3. Update `github_org` / `github_repo` in `bootstrap/variables.tf` so the OIDC
   trust policy matches the new repository, and re-apply `bootstrap/`.
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

**This repository's own branch protection is not Terraform-managed.** Deliberate:
if Terraform owned the required status checks on `main` and an apply half-failed,
`main` would become unmergeable and the only exit would be a UI override — in a
project whose whole thesis is not using the UI. Terraform manages the repositories
it creates; this one is configured once by hand.

---

## Intentionally omitted

Scoped out against the 8-hour budget, in rough order of what I would add next:

- **A read-only OIDC role for plan.** Plan runs `-lock=false` and only reads
  state, so it needs `s3:GetObject` alone. One role currently serves both jobs.
- **A GitHub Environment approval gate on apply.** Free on public repos, adds a
  human gate between merge and enforcement.
- **Policy-as-code** (OPA/Conftest) for rules the type system cannot express —
  e.g. "no app may reach `payments-api` without a security review label".
- **Scheduled drift detection.** `terraform plan -detailed-exitcode` on a cron,
  opening an issue on exit 2. The checks already detect orphans on every plan;
  this would catch them without waiting for someone to open a pull request.
- **Automated decommissioning workflow** — the runbook in `docs/GOVERNANCE.md`
  is written but executed by hand.
