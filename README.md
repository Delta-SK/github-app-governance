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

```text
terraform/catalogue.auto.tfvars      <- source of truth: apps, owners, access
        |
        |  pull request
        v
terraform-validate.yml   PR's own code: fmt, validate, lint         (no credentials)
terraform-plan.yml       main's code x PR's catalogue: plan, guard  (automatic)
terraform-plan-code.yml  PR's own code: plan, guard  (only if code changed; approval)
        |
        |  review (CODEOWNERS) + merge to main
        v
terraform-apply.yml      plan of record -> guard -> apply that plan
        |
        v
GitHub org: app installation repository access
State: s3://delta-sk-tfstate-751569314116 (S3-native lock)

reconcile.yml            weekly: plan + checks + repo controls
                         -> opens / updates / closes one issue
```

| Path | Purpose |
| --- | --- |
| `terraform/catalogue.auto.tfvars` | The catalogue. Apps, owners, review dates, repo access |
| `terraform/decommissioned.auto.tfvars` | Tombstones: apps removed, when, and why |
| `terraform/settings.tf` | Policy settings (org, review horizon, quarantine repo) — code, deliberately not variables |
| `terraform/app_access.tf` | Enforces repo access per app; preconditions for expiry, review horizon, installation ID |
| `terraform/repositories.tf` | Repositories (including the quarantine repository) and their branch protection |
| `terraform/checks.tf` | Warnings: orphans, tombstoned apps reinstalled, ghost owners, suspensions, reviews due |
| `terraform/data.tf` | Live inventory: installations, teams, externally managed repositories |
| `scripts/take-pr-catalogue.sh` | Takes a pull request's catalogue files — and nothing else — for the automatic plan |
| `scripts/plan-report.sh` | Plan, checks and guard, rendered as the pull request comment |
| `scripts/plan-guard.sh` | Refuses plans that would release an un-quarantined app or delete a repository |
| `scripts/verify-repo-controls.sh` | Checks this repository's own branch protection, environments, secrets, CODEOWNERS |
| `bootstrap/` | State backend, OIDC roles, this repo's branch protection, environments, teams. Applied by hand |
| `.terraform-version` | The one exact Terraform version, for CI and for every engineer |
| `.github/dependabot.yml` | Keeps pinned actions and providers current |
| `.markdownlint-cli2.jsonc` | Markdown rules for the docs, enforced in CI |
| `docs/GOVERNANCE.md` | The operating model: ownership, review, expiry, orphans, decommissioning, scale |
| `docs/OPERATIONS.md` | Step-by-step daily guide, for app owners and for the platform team |

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

### Why a classic PAT, and not a GitHub App

This is the most important design constraint in the project, and it is not
obvious.

`github_app_installation_repositories` calls these endpoints:

```text
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

The credential is an organisation-admin PAT, and GitHub offers nothing weaker
that can read installation access (see *Fine-grained PATs do not work*). So
the whole CI design comes down to one rule:

> **The credential only ever meets code that is already on `main`, or code a
> human has approved. Pull request *data* may reach it; pull request *code*
> may not — unless someone looked first.**

The obvious setup breaks that rule. For `pull_request` events GitHub runs the
workflow definition from the *pull request head*: anyone who can push a branch
can rewrite the plan job and have it do anything with the credential, the
moment the pull request opens. The previous version of this repository closed
that with a reviewer gate on every plan — safe, but every catalogue change
then sat waiting for a human to click *approve* before anyone could see its
plan.

The current design separates **code** from **data** instead:

| Workflow | Trigger | Runs whose code | On what data | Credential | Approval |
| --- | --- | --- | --- | --- | --- |
| `terraform-validate` | `pull_request` | the PR's | the PR's | **none** | no |
| `terraform-plan` | `pull_request_target` | **main's** | the PR's `*.auto.tfvars` | yes | **no** |
| `terraform-plan-code` | `pull_request`, code paths only | the PR's | the PR's | yes | **yes** (`plan-code`) |
| `terraform-apply` | push to `main` | main's | main's | yes (write) | no — the PR was the gate |
| `reconcile` | weekly | main's | main's | yes | no |

Why `terraform-plan` is safe without approval:

- `pull_request_target` runs the workflow **as it is on `main`**, in a checkout
  of `main`. A pull request cannot change what this job does.
- The only thing it takes from the pull request is the catalogue files, as
  plain file contents fetched by exact commit through the API
  (`scripts/take-pr-catalogue.sh`). Variable-definition files are pure data —
  HCL forbids function calls and references in them — so they cannot execute
  anything. Symlinks are refused rather than followed.
- The *rules* that judge the catalogue are locals in `terraform/settings.tf`,
  not variables. A catalogue file therefore cannot set `max_review_days =
  99999` or point the plan at another organisation: Terraform ignores
  undeclared variables with a warning. (Verified: a catalogue carrying both
  still fails the review-horizon precondition.)
- Its environment, `plan`, admits `main` only, so the credential cannot be
  reached by any other workflow definition.

What it cannot do: show the effect of a pull request's **code** changes,
because it deliberately runs `main`'s code. Such pull requests are rare,
made by the platform team, and get two things: the automatic plan says so in
its comment, and `terraform-plan-code` plans their own code once a
platform-engineering reviewer approves the `plan-code` environment. That is
the one approval left, and it sits exactly where running unreviewed code
with an admin credential would otherwise happen.

Supporting controls:

| Control | Effect |
| --- | --- |
| `TF_GITHUB_TOKEN` exists only as an **environment** secret | No job can read it implicitly; there are no repository-level secrets (`gh secret list` returns nothing) |
| `plan` and `production` admit **`main` only**, admin bypass off | Protecting another branch later cannot silently widen who reaches the credential |
| `plan-code` requires the **platform-engineering team**, admin bypass off | Whoever is on the team can release a run; leaving the team revokes it |
| Every plan assumes a **read-only** AWS role | Plans cannot write or delete state. Only apply, from `main`, can |
| Actions pinned to **commit SHAs**, Dependabot keeps them current | A moved tag cannot swap the code that runs beside the credential |
| CODEOWNERS on `.github/`, `scripts/`, `terraform/`, `bootstrap/`, `.terraform-version` | Every change to a control is reviewed by the platform team |

**Required status checks are evidence, not a boundary.** `validate` runs the
pull request's own workflow file, and a commit status such as
`terraform-plan` can be posted by anyone with write access. They catch
mistakes; they do not stop an attacker. The boundaries are the trust rule
above, CODEOWNER review, and the apply job, which re-plans and re-runs the
guard from `main`, where pull request code cannot reach.

`terraform-plan` reports through a **commit status** named `terraform-plan`
on the pull request's head commit, not through its job's check run:
`pull_request_target` runs against the base commit, and its check run is not
guaranteed to attach to the head, so it could never reliably satisfy a
required check.

**Apply does not reuse any pull request plan — deliberately.** The automatic
plan ran against `main` as it was when the pull request was last pushed; the
code plan ran pull request code, and nothing that job produced may reach the
apply credential. The apply job computes a *plan of record* from `main`, logs
it, runs the destroy guard on it, and applies exactly that saved plan. Branch
protection requires branches to be up to date, so the plans differ only if the
organisation drifted in between — and the plan of record, in the apply log,
is what actually happened.

### AWS

GitHub Actions assumes one of two roles via **OIDC**. No AWS keys are stored in
GitHub.

| Role | Trusted subject | Permissions |
| --- | --- | --- |
| `github-app-governance-plan` | `:environment:plan`, `:environment:plan-code`, `:environment:production` | `s3:GetObject` on the main state key |
| `github-app-governance-apply` | `:environment:production` | `s3:GetObject` + `s3:PutObject` on the main state key; get/put/delete on its `.tflock` lock object |

Declaring `environment:` on a job **replaces** the `:pull_request` /
`:ref:refs/heads/main` portion of the subject claim with
`:environment:<name>`. Trust policies written against the ref-based form stop
matching the moment a job moves into an environment — with the same opaque
`Not authorized to perform sts:AssumeRoleWithWebIdentity` as the ID mismatch
above. It is the better form regardless: the environment carries its own
deployment-branch policy, so "which branches may assume this role" is
enforced once, by the environment, rather than duplicated in IAM.

The plan role also trusts `production` so the scheduled reconciler can read
state; it still cannot write anything.

Both roles are scoped to `github-app-governance/terraform.tfstate`
specifically, **not** `bucket/*`. `bootstrap.tfstate` holds the OIDC roles,
this repository's branch protection and the reviewing team — CI must not be
able to rewrite the controls that constrain it. Neither role can delete
state; the apply role can delete only its own lock object.

**Locking is S3-native** (`use_lockfile = true`): the lock is a
`terraform.tfstate.tflock` object written with a conditional put next to the
state. It replaced a DynamoDB table, which Terraform has deprecated for this
purpose. Plans run with `-lock=false`, so only apply ever takes the lock.

**The OIDC subject claim is not the documented format.** GitHub issues it with
immutable numeric IDs embedded:

```text
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
| `TF_GITHUB_TOKEN` | secret | **environment** `plan`, `plan-code` and `production` | classic PAT (`repo`, `admin:org`) |
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

Creates the S3 state bucket (versioned, encrypted, TLS-only, locking
S3-native), the GitHub OIDC provider, both CI roles, the
`platform-engineering` team, the app-owning teams listed in
`app_owner_teams`, this repository's branch protection, and the three Actions
environments (`plan`, `plan-code`, `production`).

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

Copy the outputs into `terraform/versions.tf` (backend block) and into the
repository variables `AWS_PLAN_ROLE_ARN` and `AWS_APPLY_ROLE_ARN`.

`TF_GITHUB_TOKEN` must be set as an **environment** secret on `plan`,
`plan-code` and `production` — never as a repository secret, which every job
could read, including one a pull request rewrote:

```bash
for env in plan plan-code production; do
  gh secret set TF_GITHUB_TOKEN --env "$env" -R <org>/<repo>   # prompts for the value
done
```

### 2. Install the apps

Install each app on the org and set it to **"Only select repositories"**. An
installation set to *All repositories* exposes no per-repo scope, so there is
nothing for Terraform to govern — `checks.tf` fails the plan if it finds one.

### 3. Record installation IDs

Read them straight from the API — before the first `terraform apply`, because
until the catalogue holds the right IDs the apply would act on the wrong
installations (the installation-ID precondition refuses it, but the point is
not to get there):

```bash
gh api orgs/<your-org>/installations \
  --jq '.installations[] | "\(.app_slug)\t\(.id)\t\(.repository_selection)"'
```

Copy each app's slug and ID into `catalogue.auto.tfvars`, together with an
owning team (which must exist — see `app_owner_teams` in bootstrap), a purpose,
a justification and a `review_by` date no more than a year away.

This ordering is unavoidable: an app must already be installed before its
access can be managed, and Terraform cannot install apps (see *Limitations*).

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
   curl -H "Authorization: Bearer $GITHUB_TOKEN" \
     https://api.github.com/user/installations/164801077/repositories \
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

This repository's own controls (branch protection, environments, secrets,
CODEOWNERS):

```bash
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
| Expiry | precondition, `app_access.tf` | An app past its `review_by` date (unless `decommissioning = true`) |
| Review horizon | precondition, `app_access.tf` | A `review_by` more than `max_review_days` (366) away — an opt-out from review |
| Installation ID | precondition, `app_access.tf` | An `installation_id` that is not the installed ID for that app's slug — Terraform would otherwise re-point the resource at another app's installation |
| Decommissioning shape | validation, `variables.tf` | `decommissioning = true` with anything other than exactly the quarantine repository; the quarantine repository used by any other app |
| Required fields | validation, `variables.tf` | Empty `owner`, `purpose`, `justification`, empty repository list, malformed dates |
| Tombstone clash | validation, `variables.tf` | An app both catalogued and tombstoned |
| External repository | postcondition, `data.tf` | A repository name that does not exist in the org (with the name in the error) |
| Destroy guard | `scripts/plan-guard.sh` | Releasing an app not yet quarantined; deleting a repository |

**Warning** — shown on every plan and in the PR comment summary, raised as an
issue by the weekly reconciler, but never blocks an unrelated change:

| Check | Detects |
| --- | --- |
| `installations_are_declared` | An app installed but neither catalogued nor tombstoned — *the app nobody remembers installing*; and a catalogued app set to *All repositories*, which cannot be governed |
| `catalogue_matches_installations` | A catalogued app that is no longer installed |
| `tombstones_are_uninstalled` | A decommissioned app that is still — or again — installed, with the reason it was removed |
| `owners_are_real_teams` | An `owner` that is not an existing team — how ownership silently rots in a reorg |
| `no_suspended_installations` | A catalogued app suspended outside the runbook; suspension keeps every grant |
| `reviews_are_due_soon` | An entry within `review_warning_days` (30) of expiry |

Weekly, `reconcile.yml` additionally runs `scripts/verify-repo-controls.sh`,
which checks the controls `bootstrap/` put on *this* repository.

The split is the point. **A defect introduced by the pull request blocks that
pull request**, because the author can fix it. **Something that happened
elsewhere in the org — an orphan, a deleted team — warns**, because halting
everyone's work until it is resolved would just teach people to bypass the
pipeline. Expiry is the one exception, and a deliberate one: a review date
that never stops anything is decoration. With one state file it blocks every
apply, not only the owner's; per-team state is the fix at scale
(docs/GOVERNANCE.md §7).

Time-based conditions use `plantimestamp()` rather than `timestamp()`: the
latter is unknown at plan time, so the condition would only evaluate during
apply — after review rather than during it.

**How these were verified.** The live configuration plans clean against the
test org with every check passing. Each blocking control and each warning was
then exercised by planning against the same org with a deliberately broken
catalogue (a `-var-file` override, plan only, Terraform 1.16.4): all
thirteen cases — including one that tries to override `max_review_days` and
`github_org` from a catalogue file — failed or warned with the expected
message, and the guard was run against the resulting saved plans. Expiry blocking and the reconciler issue flow were exercised in
CI (issue #3). To see the orphan path end to end, install any app without
cataloguing it and run `gh workflow run reconcile.yml`.

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
| `bootstrap/variables.tf` | `platform_team_members`, `app_owner_teams` | Team members review catalogue changes and approve code plans |
| `bootstrap/main.tf` and `terraform/versions.tf` | `backend "s3"` `bucket`, `region` | Same values as above, in both files |
| `.github/workflows/*.yml` | `AWS_REGION` | Must match the backend region |
| Repository settings | variables `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`; secret `TF_GITHUB_TOKEN` in **all three** environments | Role ARNs are bootstrap outputs. Never a repository-level secret |
| `terraform/settings.tf` | `github_org` | A local, not a variable — see *The trust boundary* |
| `terraform/catalogue.auto.tfvars` | `repositories`, every `installation_id` and `owner` | IDs are per installation and never carry over — see *Setup* step 3 |
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

All actions run on Node.js 24; none is on a deprecated runtime. `.terraform/`
is never committed; lock files always are.

---

## Limitations

**Terraform cannot install, suspend or uninstall a GitHub App.** It manages
only the repository scope of an installation that already exists. For an org
owner, installing, suspending and uninstalling a third-party app are UI actions
(org **Settings → GitHub Apps → Configure**); the REST endpoints for suspend
and uninstall require the app's *own* credentials (a JWT), which you do not
hold for somebody else's app. This shapes the decommissioning runbook:
Terraform narrows access to the quarantine repository and then releases the
app, a human removes the installation.

**Installation IDs are discovered, not derived.** They must be copied into the
catalogue. `gh api orgs/<org>/installations` and the `org_installations`
output make that a lookup rather than a hunt, and a precondition refuses an ID
that does not belong to the named app.

**The access resource is authoritative.** Applying it removes any repository
access not in the catalogue. That is the point, but the first apply against an
existing org will revoke undeclared access — plan before applying to a live
organisation.

**An installation cannot be reduced to zero repositories.** GitHub forbids
removing an installation's last repository, and the provider (v6.13.0 source,
`resource_github_app_installation_repositories.go`) handles that by silently
**skipping all removals** when the list is empty: `terraform apply` reports
success, nothing changes, and every later plan shows the same pending diff
forever. Its destroy is subtler still — it removes every repository **except
one arbitrary one**.

So: `variables.tf` rejects empty lists; the `app-quarantine` repository exists
so revocation is expressible; the provider adds before it removes, so moving
an app onto the quarantine repository is safe (also verified by applying it
against this org and confirming the follow-up plan is clean); and `scripts/plan-guard.sh`
refuses to release an app that is not already quarantined, because the
arbitrary survivor could be `payments-api`. The provider also *errors* when
reading an installation that no longer exists, which is why the runbook
releases an app from Terraform **before** it is uninstalled.

**A human-owned PAT is the root credential.** Discussed under *Authentication*.

**`bootstrap/` is not GitOps.** It is applied by hand, with administrator
credentials, into its own state — deliberately, so the pipeline cannot rewrite
the controls that constrain it. The cost is that no plan ever looks at it.
The weekly reconciler compensates by *verifying* the resulting controls on
this repository (`scripts/verify-repo-controls.sh`); it detects weakening but
does not repair it.

**The test org is on the GitHub Free plan**, so the managed repositories are
**public** — branch protection is unavailable on private repositories on Free.
On a paid plan, set `visibility = "private"` in `repositories.tf`.

**A single-account organisation cannot satisfy its own review requirement.**
`main` requires one approving CODEOWNER review, but in this test org the only
member of `@Delta-SK/platform-engineering` is also the only author — and GitHub
does not permit self-approval. Merges here therefore use the org-owner bypass.
The control is correctly configured and would function normally with a second
engineer; it simply cannot be *demonstrated* satisfying itself. Adding one more
account to the org is the only real fix. The same account also approves its
own `plan-code` runs; with a real team, set `prevent_self_review = true` on
that environment in `bootstrap/github.tf`.

**Code changes are planned only after an approval.** Catalogue pull requests
plan automatically, but a pull request that changes Terraform code, scripts,
workflows or the Terraform version gets its *own* plan only once a platform
engineer approves the `plan-code` run. That is the price of never running
unreviewed code next to an admin credential. Such pull requests are rare and
come from the platform team, who can also plan them locally.

**`terraform-plan` is a `pull_request_target` workflow.** It is safe because
it never runs pull request code — and it stays safe only while that remains
true. A future edit that checks out and runs anything from the pull request
would hand the admin credential to every branch. The file says so at the top,
and CODEOWNERS routes every change to it to the platform team.

**Organisation owners can bypass branch protection** (`enforce_admins` is
false), so a determined admin can push to `main` without a plan. That mirrors
how most organisations run — owners retain break-glass access — but it does
mean branch protection is a guardrail here, not a hard boundary. Turning on
`enforce_admins` closes it, at the cost of needing a documented break-glass
procedure for the case where CI itself is broken (docs/OPERATIONS.md has the
procedure as it stands).

**Expiry blocks org-wide.** A resource precondition failure aborts the whole
plan, so with one state file one team's lapsed app blocks every team's change
until it is renewed or quarantined. Deliberate, bounded by per-team state at
scale (docs/GOVERNANCE.md §7).

**Nothing removes access automatically.** Expiry blocks the plan and the
reconciler raises an issue naming the owner; a human still has to open the
renewal or quarantine pull request. The auto-generated quarantine PR in the
escalation ladder is designed, not built.

**A quarantined app is not chased.** Once an app is quarantined it is exempt
from expiry, and nothing warns if it sits there beyond the soak period. The
exposure is small — it reaches one empty repository — but it is a loose end.

**One catalogue, one state.** The per-team split described in
`docs/GOVERNANCE.md` is a design, not an implementation. At two apps it would
be premature; the point at which it stops being premature is discussed there.
App access is already decoupled from repository management: an app can
reference repositories this configuration does not create, and a
postcondition fails the plan — naming the repository — if one does not
exist. The remaining coupling is one state file, not one resource graph.

---

## Intentionally omitted

In rough order of what I would add next:

- **Policy-as-code** (OPA/Conftest) for rules the type system cannot express —
  e.g. "no app may reach `payments-api` without a security review label".
- **Automated quarantine pull request** — opened by the reconciler once an app
  passes expiry, so the default outcome is removal rather than a blocked
  pipeline.
- **A machine user for the PAT.** The credential is currently tied to a human
  account and carries `admin:org` across every organisation that account
  belongs to. A dedicated machine user with org-owner rights and nothing else
  would bound the blast radius. Environment gating limits *who can use* the
  credential; it does nothing about *how much it can reach*.
- **Per-team catalogue and state split**, with CODEOWNERS routing each team's
  file to that team.
- **Permission-change detection.** This governs which repositories an app can
  reach, not what it can do there. An app version bump that widens its
  permission set is invisible to this configuration — see `docs/GOVERNANCE.md`
  §6, point 4. The installations data source already exposes `permissions`;
  snapshotting it into the catalogue and checking for widening is the next
  step.
