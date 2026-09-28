# GitHub App Governance

[![apply](https://img.shields.io/github/actions/workflow/status/Delta-SK/github-app-governance/terraform-apply.yml?branch=main&label=apply&logo=terraform)](https://github.com/Delta-SK/github-app-governance/actions/workflows/terraform-apply.yml)
[![org matches catalogue](https://img.shields.io/github/actions/workflow/status/Delta-SK/github-app-governance/reconcile.yml?branch=main&label=org%20matches%20catalogue)](https://github.com/Delta-SK/github-app-governance/actions/workflows/reconcile.yml)
[![open findings](https://img.shields.io/github/issues/Delta-SK/github-app-governance/reconciliation?label=open%20findings&color=informational)](https://github.com/Delta-SK/github-app-governance/issues?q=is%3Aissue+is%3Aopen+label%3Areconciliation)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Delta-SK/github-app-governance/badge)](https://scorecard.dev/viewer/?uri=github.com/Delta-SK/github-app-governance)
[![IaC: Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform&logoColor=white)](https://developer.hashicorp.com/terraform)
[![Dependabot](https://img.shields.io/badge/dependencies-Dependabot-025E8C?logo=dependabot)](.github/dependabot.yml)

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

```text
terraform/catalogue.auto.tfvars      <- source of truth: apps, owners, access
        |
        |  pull request
        v
terraform-validate.yml   PR's own code: fmt, validate, lint         (no credentials)
terraform-plan.yml       main's code x PR's catalogue: plan, guard  (automatic)
terraform-plan-code.yml  PR's own code, read-only token: plan, guard (if code changed)
        |
        |  review (CODEOWNERS) + merge to main
        v
terraform-apply.yml      plan of record -> guard -> apply that plan
        |
        v
GitHub org: app installation repository access
State: s3://delta-sk-tfstate-751569314116 (S3-native lock)

reconcile.yml            weekly: plan + checks + bootstrap drift plan
                         -> opens / updates / closes one issue
scorecard.yml            weekly + on push: OpenSSF Scorecard -> badge, Security tab
codeql.yml               every PR + weekly: CodeQL on the workflows -> Security tab
```

| Path | Purpose |
| --- | --- |
| `terraform/catalogue.auto.tfvars` | The catalogue. Apps, owners, review dates, repo access |
| `terraform/decommissioned.auto.tfvars` | Tombstones: apps removed, when, and why |
| `terraform/settings.tf` | Policy settings (org, review tiers, grace period, quarantine repo) — code, deliberately not variables |
| `terraform/review.tf` | Review tier and status per app; a lapsed review narrows access to quarantine |
| `terraform/app_access.tf` | Enforces repo access per app; installation ID looked up by slug; preconditions for installed apps and review limits |
| `terraform/repositories.tf` | Repositories (including the quarantine repository): rulesets, secret scanning, push protection |
| `terraform/checks.tf` | Warnings: orphans, tombstoned apps reinstalled, ghost owners, suspensions, reviews due |
| `terraform/data.tf` | Live inventory: installations, teams, externally managed repositories |
| `scripts/take-pr-catalogue.sh` | Takes a pull request's catalogue files — and nothing else — for the automatic plan |
| `scripts/plan-report.sh` | Plan, checks and guard, rendered as the pull request comment |
| `scripts/plan-guard.sh` | Refuses plans that would release an un-quarantined app or delete a repository |
| `scripts/verify-repo-controls.sh` | The few controls a plan of `bootstrap/` cannot see: secret placement, private reporting, CODEOWNERS, extra environment policies |
| `bootstrap/` | State backend, OIDC roles, and this repository itself: its settings, ruleset, environments, reviewing team, labels. Applied by hand |
| `.terraform-version` | The one exact Terraform version, for CI and for every engineer |
| `.github/dependabot.yml` | Keeps pinned actions and providers current |
| `.github/workflows/scorecard.yml` | OpenSSF Scorecard: independent supply-chain review, published as the badge |
| `.github/workflows/codeql.yml` | CodeQL static analysis of the workflows themselves |
| `SECURITY.md`, `LICENSE` | How to report a vulnerability privately; MIT licence |
| `.markdownlint-cli2.jsonc` | Markdown rules for the docs, enforced in CI |
| `docs/GOVERNANCE.md` | The operating model: ownership, review, expiry, orphans, decommissioning, scale |
| `docs/OPERATIONS.md` | Step-by-step daily guide, for app owners and for the platform team |
| `docs/decisions/` | Decision records: each design decision, its reasons and its costs, stated once |

### Why the catalogue is one file

`catalogue.auto.tfvars` carries both the *intent* (which repos) and the
*justification* (owner, purpose, review date). A reviewer reads one diff and
sees the whole change. An auditor reads one file and sees the whole estate.

At organisation scale this splits into `catalogue/<team>.auto.tfvars` with
CODEOWNERS routing review per team. The schema does not change.

---

## Prerequisites

- Terraform, exactly the version in [`.terraform-version`](.terraform-version)
  (currently 1.16.4). `tfenv`, `tfswitch` and `mise` pick it up
  automatically; `terraform/versions.tf` refuses anything outside 1.16.x
- An AWS account (state backend) with credentials available locally
- A GitHub organisation where you are an **owner**
- A fine-grained, read-only token for plans of pull request code — see
  *Setup* step 1
- A **classic** personal access token with `repo` and `admin:org` scopes.
  Add `workflow` as well if you intend to push changes to
  `.github/workflows/` — GitHub rejects such pushes otherwise. The token
  Actions uses at runtime (`TF_GITHUB_TOKEN`) does **not** need `workflow`;
  only the developer pushing the files does.
  `delete_repo` is deliberately **not** granted: Terraform never deletes
  repositories here, so the token cannot either.
- At least two GitHub Apps installed on the org, each set to
  **"Only select repositories"**
- `jq` and the GitHub CLI (`gh`) for the inspection commands below

---

## Authentication

| Name | Kind | Where | What |
| --- | --- | --- | --- |
| `TF_GITHUB_TOKEN` | secret | environments `plan`, `production` — code on `main` only | classic PAT, exactly `repo` + `admin:org` |
| `TF_GITHUB_READ_TOKEN` | secret | environment `plan-code` | fine-grained PAT, owner = the org: all repositories, organisation *Administration* and *Members* read |
| `AWS_PLAN_ROLE_ARN` | variable, set by bootstrap | repository | read-only access to the main state |
| `AWS_APPLY_ROLE_ARN` | variable, set by bootstrap | repository | read-write access to the main state and its lock |
| `AWS_AUDIT_ROLE_ARN` | variable, set by bootstrap | repository | read-only plan of `bootstrap/` |

No repository-level secrets exist, and no AWS keys: GitHub Actions assumes the
AWS roles through OIDC.

**Why a classic PAT.** The provider manages installation access through
user-to-server endpoints that GitHub App tokens cannot call and fine-grained
PATs are refused on (tested). A classic PAT is the only credential that works
on this plan; on GitHub Enterprise Cloud an enterprise-owned App with the
*organization installation repositories* permission replaces it, and is the
production path. Details, test results and the migration:
[decision 0001](docs/decisions/0001-classic-pat-for-installation-access.md).

**The trust boundary.** The admin token only ever meets code that is already
on `main`. Pull request *data* is planned with `main`'s code; pull request
*code* is planned with the read-only token. Nothing needs a human to release a
credential, so every pull request is planned before review:
[decision 0002](docs/decisions/0002-plan-data-and-code-separately.md).

**AWS roles.**

| Role | Assumable from | Can |
| --- | --- | --- |
| `github-app-governance-plan` | environments `plan`, `plan-code`, `production` | read the main state |
| `github-app-governance-apply` | environment `production` | read and write the main state; create and delete its lock object |
| `github-app-governance-audit` | environment `production` | read `bootstrap.tfstate` and the metadata of bootstrap's AWS resources |

No role can read or write bootstrap's state except the audit role's read, and
none can delete state. Locking is S3-native (`use_lockfile`); plans never
lock.

The OIDC subject claim embeds immutable numeric IDs —
`repo:Delta-SK@333749275/github-app-governance@1387485403:environment:<name>`
— not the `repo:OWNER/REPO:...` form in most examples; a policy written in
that form fails with an unexplained `Not authorized to perform
sts:AssumeRoleWithWebIdentity`. Pinning the IDs (`bootstrap/variables.tf`)
also means a deleted and recreated organisation or repository of the same
name does not inherit the trust.

---

## Setup

### 1. Bootstrap the backend (once)

```bash
cd bootstrap
terraform init
terraform apply
```

Creates the S3 state bucket (versioned, encrypted, TLS-only, locking
S3-native), the GitHub OIDC provider, the three CI roles (plan, apply,
audit), the `platform-engineering` team, the app-owning teams listed in
`app_owner_teams`, this repository's settings and its ruleset on `main`, and
the three Actions environments (`plan`, `plan-code`, `production`).

Bootstrap needs AWS administrator credentials and the classic PAT, and it is
**not** run by CI — see *Limitations* for why, and for what checks it instead.

Against a **fresh AWS account**, comment out the `backend "s3"` block in
`bootstrap/main.tf` for the first apply — it cannot use a bucket that does not
exist yet. Then restore the block and migrate:

```bash
terraform init -migrate-state
```

That moves bootstrap's own state into the bucket it just created, so no
unbacked-up local state file is left behind. It is the one genuine
chicken-and-egg step in the setup, and it only happens once.

Copy the bucket name into `terraform/versions.tf` (backend block). The role
ARNs need no copying: bootstrap publishes them as the repository variables
the workflows read.

Both GitHub tokens are **environment** secrets — never repository secrets,
which every job could read, including one a pull request rewrote. The admin
token goes only where `main`'s code runs; the read-only one is the only
credential pull request code ever sees:

```bash
for env in plan production; do
  gh secret set TF_GITHUB_TOKEN --env "$env" -R <org>/<repo>      # classic PAT; prompts for the value
done
gh secret set TF_GITHUB_READ_TOKEN --env plan-code -R <org>/<repo>  # fine-grained, read-only
```

Create the read-only token under **Settings → Developer settings →
Fine-grained tokens**: resource owner = the organisation, all repositories,
organisation permissions *Administration: read-only* and *Members:
read-only*, nothing else, with an expiry date.

### 2. Install the apps

Install each app on the org and set it to **"Only select repositories"**. An
installation set to *All repositories* exposes no per-repo scope, so there is
nothing for Terraform to govern — `checks.tf` fails the plan if it finds one.

### 3. Catalogue the apps

For each installed app, read its slug and approved permissions:

```bash
gh api orgs/<your-org>/installations \
  --jq '.installations[] | {app_slug, repository_selection, permissions}'
```

Add an entry per app to `catalogue.auto.tfvars`: owning team (which must
exist — see `app_owner_teams` in bootstrap), purpose, justification,
repositories, `permissions`, and a `review_by` within the limit for its risk
tier. The installation ID is not recorded; Terraform looks it up by slug.
Recording the permissions is the approval of what the app may do; from then
on any change to them is reported.

### 4. First apply

```bash
cd terraform
export GITHUB_TOKEN=ghp_...      # the classic PAT; never commit it
terraform init
terraform plan                    # read it — the resource is authoritative
terraform apply
terraform output org_installations   # every installation now shows declared = true
```

From here on, every change goes through a pull request.

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

2. Open a pull request. Two checks start at once, with nobody approving
   anything: `validate` (fmt, validate, shellcheck and markdownlint on the
   pull request's own files) and `terraform-plan` (main's code planned against this catalogue,
   plus the destroy guard). Within a couple of minutes the plan is posted as
   a PR comment with a summary table:

   ```text
   ~ resource "github_app_installation_repositories" "this["renovate"]" {
       ~ selected_repositories = [
           - "web-frontend",
         ]
     }
   ```

3. CODEOWNERS requires platform-engineering review — the catalogue is an
   authorisation record, so a human approves the access change.

4. Merge. `terraform-apply` computes the plan of record from `main`, runs the
   destroy guard on it, applies exactly that plan, and prints the resulting
   access matrix.

5. Verify against GitHub itself, not against state:

   ```bash
   id=$(gh api orgs/Delta-SK/installations \
     --jq '.installations[] | select(.app_slug == "renovate") | .id')
   curl -H "Authorization: Bearer $GITHUB_TOKEN" \
     "https://api.github.com/user/installations/$id/repositories" \
     | jq -r '.repositories[].full_name'
   ```

Adding access is the same flow with a line added. Adding a new app, renewing a
review, and removing an app are walked through step by step in
[docs/OPERATIONS.md](docs/OPERATIONS.md).

---

## Inspecting the current state

```bash
cd terraform

terraform output app_access_matrix     # what Terraform intends
terraform output org_installations     # what is installed: ID, scope, suspended, declared, tombstoned
terraform output decommissioned_apps   # tombstones
```

Full drift and governance status. **The exit code alone is not enough**:
governance checks are warnings and leave it at 0, so read them from the plan:

```bash
terraform plan -lock=false -detailed-exitcode -out=tfplan >/dev/null 2>&1
echo "exit: $?"                                     # 0 no changes, 2 drift, 1 error
terraform show -json tfplan \
  | jq -r '.checks[] | select(.status == "fail") | .address.to_display'
                                                    # empty = every check passes
```

This repository's own controls — drift in everything `bootstrap/` manages,
then the few things a plan cannot see:

```bash
cd ../bootstrap && terraform plan -lock=false -detailed-exitcode   # 0 = no drift
GH_TOKEN=$GITHUB_TOKEN ../scripts/verify-repo-controls.sh Delta-SK/github-app-governance
```

Or run all of the above in CI, with the result as an issue:
`gh workflow run reconcile.yml`.

---

## Governance checks

Controls are split deliberately between **blocking** and **warning**.

**Blocking** — the plan fails, nothing is applied:

| Control | Where | Refuses |
| --- | --- | --- |
| Review horizon by risk | precondition, `app_access.tf` | A `review_by` further away than the app's tier allows: 90 days if it can write to workflows, actions, administration, hooks, environments, secrets or members; 180 days for any other write; 366 for read-only |
| Not installed | precondition, `app_access.tf` | A catalogue entry for an app that is not installed yet — so a request cannot merge before an owner installs the app |
| Decommissioning shape | validation, `variables.tf` | `decommissioning = true` with anything other than exactly the quarantine repository; the quarantine repository used by any other app |
| Required fields | validation, `variables.tf` | Empty `owner`, `purpose`, `justification`, empty repository list, malformed dates, missing or invalid `permissions` |
| Tombstone clash | validation, `variables.tf` | An app both catalogued and tombstoned |
| External repository | postcondition, `data.tf` | A repository name that does not exist in the org (with the name in the error) |
| Destroy guard | `scripts/plan-guard.sh` | Releasing an app not yet quarantined; deleting a repository |

**Warning** — shown on every plan and in the PR comment summary, raised as an
issue by the weekly reconciler, but never blocks an unrelated change:

| Check | Detects |
| --- | --- |
| `installations_are_declared` | An app installed but neither catalogued nor tombstoned — *the app nobody remembers installing*; and a catalogued app set to *All repositories*, which cannot be governed |
| `tombstones_are_uninstalled` | A decommissioned app that is still — or again — installed, with the reason it was removed |
| `owners_are_real_teams` | An `owner` that is not an existing team — how ownership silently rots in a reorg |
| `no_suspended_installations` | A catalogued app suspended outside the runbook; suspension keeps every grant |
| `reviews_are_due_soon` | A review due within 30 days |
| `reviews_are_overdue` | A review date passed, within the 30-day grace period — with the date access will move to quarantine |
| `reviews_have_lapsed` | Grace period over: the app's access **has been narrowed to the quarantine repository** in the plan, and the next apply enforces it |
| `permissions_match_catalogue` | An installation whose live permissions differ from the approved `permissions` in its entry — typically an owner accepting an app update's request for more access in the UI |

Weekly, `reconcile.yml` also plans `bootstrap/` read-only, so any change to
the controls on *this* repository — ruleset, environments, settings, team —
is found by the same code that defines them. `scripts/verify-repo-controls.sh`
covers only what that plan cannot see.

The split is the point: **a defect the pull request introduces blocks that
pull request**, because its author can fix it; **something that happened
elsewhere warns**, because it must not stop unrelated work. Expiry follows the
same rule — it revokes the lapsed app's access rather than blocking anyone
([0004](docs/decisions/0004-expiry-revokes-instead-of-blocking.md)).
Time-based conditions use `plantimestamp()`, so they are evaluated in the plan
a reviewer sees, not only at apply.

**How these were verified** (Terraform 1.16.4, against the test org, plan
only): the live configuration plans clean with every check passing; then each
control was triggered with a deliberately broken catalogue passed as a
`-var-file` — policy overrides from a catalogue file, permission drift, the
decommissioning loophole, early release (guard), a mistyped repository, a
review due soon, overdue, lapsed (only that app moves to quarantine), beyond
its tier limit, and a new app not yet installed. Each blocked or warned as
designed. The reconciler's issue flow was exercised in CI (issue #3); to see
the orphan path end to end, install any app without cataloguing it and run
`gh workflow run reconcile.yml`.

Full design in [docs/GOVERNANCE.md](docs/GOVERNANCE.md); what to do when each
one fires is in [docs/OPERATIONS.md](docs/OPERATIONS.md).

---

## Pointing at a different organisation

Every org- or account-specific value, in the order you meet them. Terraform
forbids variables in `backend` blocks, so the backend values are literals that
must be edited **and committed** — CI runs a plain `terraform init` and reads
them from the file.

| File | Values | Notes |
| --- | --- | --- |
| `bootstrap/variables.tf` | `github_org`, `github_repo`, **`github_org_id`**, **`github_repo_id`**, `state_bucket`, `aws_region` | The numeric IDs go into the OIDC trust policy; get them with the `curl` commands in the file's comments. They produce the least helpful error if wrong (see *Authentication*). The bucket name must be globally unique |
| `bootstrap/variables.tf` | `platform_team_members` (username → role, at least two), `app_owner_teams` | Team members review catalogue changes and approve code plans. New members receive an organisation invitation and can review once they accept |
| `bootstrap/github.tf` | `description` of `github_repository.governance` | The governance repository must already exist (it is where this code lives); bootstrap adopts it with an `import` block. Enabling private vulnerability reporting needs `curl` and the token in `GITHUB_TOKEN` (or `gh auth login`) |
| `bootstrap/main.tf` and `terraform/versions.tf` | `backend "s3"` `bucket`, `region` | Same values as above, in both files |
| `.github/workflows/*.yml` | `AWS_REGION` | Must match the backend region |
| Repository settings | secrets `TF_GITHUB_TOKEN` in `plan` and `production`, `TF_GITHUB_READ_TOKEN` in `plan-code` | Never repository-level secrets — see *Setup* step 1. The role-ARN variables are set by bootstrap |
| `terraform/settings.tf` | `github_org` | A local, not a variable — see *The trust boundary* |
| `terraform/catalogue.auto.tfvars` | `repositories`, every app's `owner` and `permissions` | See *Setup* step 3 |
| `terraform/decommissioned.auto.tfvars` | tombstones | Start from `{}` |
| `.github/CODEOWNERS` | `@Delta-SK/...` | The team must exist and be visible, or CODEOWNERS silently routes nothing (the reconciler checks) |

Then follow *Setup* from step 1. Nothing else is org-specific: the scripts and
the reconciler take the repository name from the workflow context.

For a quick local look without CI, override the backend instead of editing it:

```bash
terraform init -reconfigure \
  -backend-config="bucket=your-bucket" \
  -backend-config="key=github-app-governance/terraform.tfstate" \
  -backend-config="region=your-region"
```

---

## Versions and pinning

Nothing that runs here floats. Every version is pinned in exactly one place,
and everything that can be kept current automatically is.

| What | Pinned to | Where | Kept current by |
| --- | --- | --- | --- |
| Terraform CLI | 1.16.4 exactly | `.terraform-version` (CI reads it; so do `tfenv`, `tfswitch`, `mise`) | Hand — [OPERATIONS.md](docs/OPERATIONS.md), *Monthly* |
| Terraform CLI range | `~> 1.16.0` | `required_version` in both configurations | Moves with the line above |
| Providers | exact versions + hashes for linux/darwin × amd64/arm64 | `.terraform.lock.hcl` in both configurations | Dependabot (`terraform`) |
| Provider ranges | `integrations/github ~> 6.13`, `hashicorp/aws ~> 6.0` | `required_providers` | Dependabot |
| GitHub Actions | full commit SHA, version in a trailing comment | every `uses:` | Dependabot (`github-actions`), one-week cooldown |
| Runner image | `ubuntu-24.04` | every `runs-on:` | Hand — never `ubuntu-latest`, which moves to a new OS under you |
| State locking | S3-native `use_lockfile` | both `backend "s3"` blocks | — (replaced the deprecated DynamoDB lock) |

Every JavaScript action runs on Node.js 24; none is on a deprecated runtime.
The one container action, Scorecard, is SHA-pinned, but its `action.yaml`
references its image as `ghcr.io/ossf/scorecard-action:v2.4.4` — a registry
tag, which is mutable. That residual is accepted: it is OpenSSF's own release,
and the job holds no credential beyond its two narrow permissions. `.terraform/`
is never committed; lock files always are.

---

## Limitations

Each links to the decision that explains it.

- **Terraform cannot install, suspend or uninstall an app** — only scope an
  existing installation. A new-app pull request stays red until an owner
  installs the app; uninstalling is the last, human step of decommissioning.
  On Enterprise Cloud an enterprise App could do both
  ([0001](docs/decisions/0001-classic-pat-for-installation-access.md),
  [0003](docs/decisions/0003-decommission-through-quarantine.md)).
- **The access resource is authoritative.** The first apply against an
  existing organisation revokes all undeclared access — plan first.
- **No installation can reach zero repositories.** Revoked access means
  "reaches only `app-quarantine`"; an app uninstalled by hand while catalogued
  breaks every plan until its entry is removed
  ([0003](docs/decisions/0003-decommission-through-quarantine.md)).
- **A human-owned classic PAT is the root credential**, and restricting
  classic PATs by organisation policy would cut this pipeline off
  ([0001](docs/decisions/0001-classic-pat-for-installation-access.md)).
- **Code plans are not refreshed, and their read-only token is readable by
  any branch**
  ([0002](docs/decisions/0002-plan-data-and-code-separately.md)).
- **Expiry depends on the clock.** The day a grace period ends, plans show
  that app moving to quarantine; the next apply enforces it
  ([0004](docs/decisions/0004-expiry-revokes-instead-of-blocking.md)).
- **Permissions are audited, not enforced.** A widened permission is reported
  within a week, not prevented
  ([0008](docs/decisions/0008-permissions-are-audited-not-enforced.md)).
- **Bootstrap drift is detected weekly and repaired by a person**
  ([0006](docs/decisions/0006-bootstrap-apart-and-drift-planned.md)).
- **Break-glass is a ruleset change**, not a button; the second reviewer in
  the test org is a demonstration identity
  ([0005](docs/decisions/0005-rules-on-main-without-bypass.md)).
- **A quarantined app is not chased.** Nothing warns if one sits in
  quarantine indefinitely; it reaches only an empty repository.
- **The test organisation is on the Free plan**, so the managed repositories
  are public (rulesets need a paid plan for private repositories). On a paid
  plan, set `visibility = "private"` in `repositories.tf`.
- **Some OpenSSF Scorecard checks cannot reach 10 here.** Branch-Protection
  tops out at 8 with one required reviewer; Code-Review rises as reviewed
  merges replace #1–#7; Maintained scores after 90 days; checks aimed at
  published libraries are not pursued.
- **One catalogue, one state.** Splitting per team is designed
  (docs/GOVERNANCE.md §8), not built; at three apps it would be premature.

---

## Intentionally omitted

In rough order of what I would add next:

- **The Enterprise Cloud credential path** — an enterprise-owned GitHub App
  and a thin adapter over the organisation-installations API, retiring the
  classic PAT ([0001](docs/decisions/0001-classic-pat-for-installation-access.md)).
  Not buildable on the Free-plan test organisation.
- **Required code scanning on `main`** — a `required_code_scanning` rule in
  the ruleset, blocking pull requests that introduce high-severity CodeQL
  findings. Deferred until CodeQL has a baseline analysis on `main`; adding it
  first would block the pull request that introduces CodeQL.
- **Policy-as-code** (OPA/Conftest) for rules the type system cannot express —
  e.g. "no app may reach `payments-api` without a security review label".
- **Per-team catalogue and state split**, with CODEOWNERS routing each team's
  file to that team.
