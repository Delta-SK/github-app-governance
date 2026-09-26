# Working with GitHub App governance — day-to-day guide

This guide is for people who have never used this repository. It has two
parts:

- **[Part 1 — App owners and requesters](#part-1--app-owners-and-requesters):**
  you want an app installed, want it to reach another repository, got a
  "review due" message, or want to remove an app.
- **[Part 2 — Platform team (support)](#part-2--platform-team-support):** you
  review catalogue changes, approve the occasional code plan, triage the
  weekly reconciliation issue, and keep the pipeline itself healthy.

Why the system exists and how it is designed: [README](../README.md) and
[GOVERNANCE.md](GOVERNANCE.md). This page only covers *how to do things*.

---

## The ten words you need

| Term | Meaning |
| --- | --- |
| **Catalogue** | `terraform/catalogue.auto.tfvars`. The list of every app allowed in the org, who owns it, why, until when, and which repositories it may reach. If it is not in the catalogue, it is not allowed. |
| **Installation** | An app installed on the org. Each has a numeric **installation ID**. |
| **Slug** | The app's short name in URLs, e.g. `renovate`. Catalogue entries are keyed by slug. |
| **Owner** | A GitHub **team** (never a person) that answers for the app. |
| **`review_by`** | The date the access stops being assumed good. After it, every plan fails until the owner renews or removes the app. At most one year ahead. |
| **Plan** | Terraform's preview of what a change will do. Posted as a comment on every pull request. |
| **Apply** | Terraform making the change for real. Runs automatically after merge to `main`. |
| **Quarantine** | The empty repository `app-quarantine`. An app being removed is pointed here, so it can reach nothing real while still installed. |
| **Tombstone** | A record in `terraform/decommissioned.auto.tfvars` of an app that was removed: when, by whom, why. |
| **Reconciliation issue** | A GitHub issue labelled `reconciliation`, opened every Monday by an automated check when anything in the org does not match the catalogue. It closes itself once everything matches. |

**The one rule:** app access is never changed in the GitHub UI. Every change is
a pull request to this repository. A change made in the UI is found by the
Monday check and undone by the next apply.

---

## Part 1 — App owners and requesters

You need: membership of the org, and permission to open pull requests on
`Delta-SK/github-app-governance`. You do **not** need Terraform, AWS, or any
token. Everything below can be done in the GitHub web interface.

### How any change works

Every change you make follows the same five steps.

1. **Edit** `terraform/catalogue.auto.tfvars` in the GitHub web editor (open
   the file → pencil icon). When saving, choose **"Create a new branch for
   this commit and start a pull request"**.
2. **Fill in the pull request template** — what changes, why, ticket number.
3. **Wait two minutes for the plan.** Nothing needs approving: two checks
   start by themselves — `validate` (formatting and syntax) and
   `terraform-plan`. A comment titled **Terraform plan — catalogue** appears
   with a summary table and the full plan.
4. **Read the plan comment.** The table should say `success` for plan and
   destroy guard, and both checks should be green. Expand *Show plan* and
   check it shows what you meant — lines with `+` are added, `-` removed.
5. **Get a review and merge.** A member of `@Delta-SK/platform-engineering`
   other than you approves — the rules on `main` require an approval of your
   latest push from someone who did not make it, and apply to everyone,
   administrators included. Merge with **Squash and merge** (the only method
   allowed). The `terraform-apply` workflow (Actions tab) runs automatically
   and applies the change within minutes.

If the plan fails, the comment and the red `terraform-plan` check say why —
see [When your plan fails](#when-your-plan-fails). A red `validate` check
means formatting or syntax: its log shows the exact line.

### Request a new app

1. **Open a request.** Issues → New issue → **Request a GitHub App**. Fill in
   every field. Be specific about repositories: "All repositories" is never
   granted.
2. **Wait for approval.** The platform team checks the vendor, the
   permissions the app asks for, and your justification, and replies on the
   issue.
3. **An org owner installs it.** Once approved, a platform engineer installs
   the app choosing **"Only select repositories"** and a single repository
   from your list. From this moment until step 5 is merged, the app shows as
   *undeclared* in plans — that is expected; keep the gap short.
4. **Get the installation ID and permissions.** The platform engineer posts
   both on the issue. (The ID is the number at the end of the app's Configure
   page URL, `github.com/organizations/Delta-SK/settings/installations/<ID>`;
   the permissions are listed on the same page.)
5. **Open the catalogue pull request.** Add an entry under `app_catalogue`:

   ```hcl
   stale = {
     installation_id = "123456789"          # from step 4, in quotes
     owner           = "web-team"           # an existing GitHub team
     purpose         = "Closes inactive issues and pull requests"
     justification   = "Keeps the backlog triaged without manual sweeps; replaces a cron script."
     review_by       = "2027-06-30"         # at most one year from today
     repositories = [
       "web-frontend",
     ]
     permissions = {                         # exactly as posted in step 4
       issues        = "write"
       metadata      = "read"
       pull_requests = "write"
     }
   }
   ```

   Link the request issue in the pull request. Follow
   [How any change works](#how-any-change-works). When the apply finishes,
   the app reaches exactly the listed repositories.

### Give an app access to another repository

1. Add the repository name to the app's `repositories` list.
2. In the pull request, say why the app needs this repository.
3. Follow [How any change works](#how-any-change-works). The plan shows the
   repository with a `+`.

The repository can be one this configuration creates (listed under
`repositories =` at the top of the catalogue) or any other existing
repository in the org — just use its exact name. A misspelled name fails the
plan with a message naming it.

### Remove an app's access to one repository

1. Delete the repository from the app's `repositories` list. At least one
   repository must remain — to remove the app entirely, see
   [Remove an app completely](#remove-an-app-completely).
2. Follow [How any change works](#how-any-change-works). The plan shows the
   repository with a `-`.

### Renew a review

Every plan starts warning 30 days before an app's `review_by` date:
*"App(s) due for review within 30 days: …"*.

1. Check the app is still needed, still used, and still needs every
   repository it has. Remove any it does not.
2. Check its permissions are still what the org approved. If they have
   changed, every plan already says so (*"Installed permissions differ from
   the catalogue"*); decide whether the app still deserves them, and update
   its `permissions` in the same pull request, saying why.
3. Set `review_by` to a new date — at most one year from today; sooner for
   apps with write access to sensitive repositories.
4. Follow [How any change works](#how-any-change-works). In the pull request,
   write who confirmed the app is still needed.

**If you miss the date,** every plan in the org fails with
*"App '…' passed its review_by date"* — nobody can change any app until
yours is renewed or quarantined. The weekly reconciliation issue will name
your team.

### Remove an app completely

Removal happens in stages, so every step until the last can be undone.
Allow two to three weeks end to end.

**Stage 1 — Quarantine (pull request 1).** Point the app at the quarantine
repository and flag it:

```hcl
imgbot = {
  installation_id = "164802659"
  owner           = "web-team"
  purpose         = "..."
  justification   = "..."
  review_by       = "2027-01-31"
  decommissioning = true
  repositories = [
    "app-quarantine",
  ]
}
```

This works even if the review date has already passed. The app is still
installed but reaches nothing real. If something breaks, revert the pull
request and access returns.

**Stage 2 — Wait 7–14 days.** Watch for anything that stops working. If
something does, revert pull request 1 and talk to the platform team.

**Stage 3 — Release and tombstone (pull request 2).** Delete the app's entry
from `catalogue.auto.tfvars` and add a tombstone to
`terraform/decommissioned.auto.tfvars`:

```hcl
decommissioned_apps = {
  imgbot = {
    removed_on       = "2026-11-14"
    owner_at_removal = "web-team"
    reason           = "Replaced by image optimisation in the build pipeline."
    ticket           = "PLAT-2291"
  }
}
```

The plan shows the app's access resource being destroyed; that is expected.
If the plan comment shows **destroy guard: failure**, stage 1 has not been
merged yet — the guard refuses to release an app that still reaches real
repositories.

**Stage 4 — Ask the platform team to uninstall it.** Uninstalling is a UI
action only an org owner can take. Until it is done, plans show *"Decommissioned
app(s) still installed"* — the reminder clears itself afterwards.

### Change an app's owning team

Edit `owner` to the new team's slug (as in `github.com/orgs/Delta-SK/teams/<slug>`).
Both teams should agree in the pull request. If the plan warns *"owner
team(s) that do not exist"*, the slug is wrong or the team has not been
created.

### When your plan fails

| Message contains | What it means | What to do |
| --- | --- | --- |
| `passed its review_by date` | An app's review has lapsed — possibly **not yours** | If it is yours: [renew](#renew-a-review) or [quarantine](#remove-an-app-completely). If not: tell the owner named in the message, and the platform team |
| `more than 366 days away` | Your `review_by` is too far out | Pick a date within a year |
| `must retain at least one repository` | An empty `repositories` list | To remove the app entirely, use the quarantine stage |
| `must list exactly the quarantine repository` | `decommissioning = true` with real repositories, or `app-quarantine` on a normal app | Quarantine means `["app-quarantine"]` and nothing else |
| `installation_id must be the numeric ID` / `the '…' installation in the org is …` | Wrong or placeholder installation ID | Copy the ID the message suggests, or ask the platform team |
| `does not exist in Delta-SK` | A repository name is misspelled | Fix the name |
| `needs a purpose and a justification` / `named owning team` | A field is empty | Fill it in |
| `both catalogued and tombstoned` | The app is in both files | Remove it from one |
| `destroy guard` failure | You removed an app that is not quarantined yet | Do stage 1 first |
| `validate` failed at *terraform fmt* | Formatting | The log shows the expected layout; copy the indentation of the entries around yours, or ask a platform engineer to run `terraform fmt` |
| Warning `Value for undeclared variable` | The file sets something that is not catalogue data, such as `max_review_days` | Remove it. Policy settings live in `terraform/settings.tf` and change through the platform team |

Warnings (⚠️ under *governance checks* in the plan comment) never block your
pull request. They usually describe something elsewhere in the org, and the
platform team handles them.

---

## Part 2 — Platform team (support)

### Access you need

| What | Why | How to get it |
| --- | --- | --- |
| Member of `@Delta-SK/platform-engineering` | CODEOWNER reviews — the one approval every change needs | An org owner adds you to `platform_team_members` in `bootstrap/variables.tf` (as `member`) and re-applies bootstrap. You receive an organisation invitation; you can review once you accept it |
| Org owner | Installing, suspending and uninstalling apps; break-glass | Org owners only |
| `gh` CLI, logged in | Every command below | `gh auth login` |
| Terraform at the version in `.terraform-version` (`tfenv install` / `mise install` read it), AWS read access to the state bucket, the classic PAT | Only for local inspection, bootstrap, and rare state operations | Ask the credential owner. **Never paste the PAT into chat, a ticket, or a terminal that is being shared** |

Most of the job needs nothing but the GitHub web interface and `gh`.

### Daily — 5 minutes

1. **Review pull requests.** Nothing waits for you before review: every pull
   request is planned automatically, and the plans are on it when you open
   it. Use the reviewer checklist in the pull request template. In
   particular:
   - The **Terraform plan — catalogue** comment shows only the change
     described, *destroy guard* is `success`, and the checks are green.
   - If that comment carries the ⚠️ *also changes code* note, it does not
     show the code change. Read the second comment, **Terraform plan — this
     pull request's code**: it plans the pull request's own code (with a
     read-only token, not refreshed against live GitHub). And read every line
     under `.github/`, `scripts/` and every `*.tf` change — look for anything
     that sends data anywhere, runs extra programs, or adds providers. After
     merge that code runs on `main` with the admin token; your approval is
     what allows it.
   - New app or new repository: the app's permissions (org **Settings →
     GitHub Apps → app → Configure**) are proportionate to the repositories
     it gains. `contents: write` on `payments-api` deserves a second look.
   - The owner is a real team that has agreed, and `review_by` is sensible
     for the risk.
2. **Merge** with **Squash and merge**, then glance at the `terraform-apply`
   run: *plan of record* shows what was applied, *Show resulting access
   matrix* the result.
3. **App requests.** Issues labelled `app-request`: review, reply, and if
   approved install the app (see [Install an approved app](#install-an-approved-app)).

### Weekly — Monday, after 07:00 UTC

The `reconcile` workflow runs at 07:00 UTC. Then:

- **No open issue labelled `reconciliation`** → everything matches. Done.
- **An open issue** → triage each bullet in its newest comment with the table
  below. Fix, then run the check again: `gh workflow run reconcile.yml
  -R Delta-SK/github-app-governance`. The issue closes itself when clean.

#### Triage a reconciliation issue

| Finding | What it means | What to do |
| --- | --- | --- |
| **The plan failed** + `passed its review_by date` | An app's review lapsed. **All catalogue changes are blocked** until fixed | Contact the owning team named in the message today. They renew or quarantine. If they are unreachable, open the quarantine pull request yourself |
| **The plan failed**, other error | Credential expired, API outage, or broken configuration | Open the workflow log. `401 Bad credentials` → [rotate the token](#rotate-the-github-token). Anything else → fix via pull request |
| **Drift** | Access was changed in the GitHub UI | Find out who and why. If the change was right, codify it in a pull request. If not, revert it: Actions → `terraform-apply` → **Run workflow** |
| `check.installations_are_declared` — *Undeclared* | An app nobody catalogued: someone installed it outside the process | [Handle an orphan](#handle-an-orphan) |
| `check.installations_are_declared` — *repository_selection=all* | A catalogued app was switched to "All repositories" in the UI | Switch it back (app → Configure → Only select repositories, any one repository), then run `terraform-apply` to restore the exact list |
| `check.catalogue_matches_installations` | A catalogued app was uninstalled by hand | If intended, tombstone it (stage 3 of removal, without stage 1). Otherwise reinstall and update its `installation_id` |
| `check.tombstones_are_uninstalled` | A removed app is still — or again — installed. The message says why it was removed | Just after a stage-3 merge: finish the uninstall. Otherwise: someone reinstalled it; talk to them, then uninstall or re-catalogue it via pull request |
| `check.owners_are_real_teams` | An owner team was deleted or renamed | Find the successor team; open a pull request changing `owner` |
| `check.no_suspended_installations` | A catalogued app was suspended outside the removal process | Find out why. Either unsuspend or start its removal |
| `check.permissions_match_catalogue` | An app's live permissions differ from its approved `permissions` — usually an owner accepted an app update asking for more | Find who accepted it (org audit log on Enterprise; otherwise ask the owners). Then either a pull request recording the new permissions, with the reason, approved by the owning team — or quarantine the app |
| `check.reviews_are_due_soon` | Reviews due within 30 days | Nudge the owning teams; nothing to fix yet |
| **This repository's own controls were weakened** | Someone changed the ruleset on `main`, an environment, secret scanning, private vulnerability reporting, secrets or CODEOWNERS in the UI — or a break-glass bypass was never removed | Re-apply bootstrap (see [Change bootstrap](#change-bootstrap-teams-reviewers-rules-on-main)); find out who and why |

#### Handle an orphan

1. Find the app: org **Settings → GitHub Apps**. Note which repositories it
   reaches and what permissions it holds.
2. Find who installed it and when. On GitHub Enterprise Cloud the org audit
   log records it (`action:integration_installation.create`). On lower plans
   provenance may be unrecoverable — ask in engineering channels.
3. Decide:
   - **Someone needs it** → they file an app request; catalogue it as a new
     app (the installation already exists — skip the install step).
   - **Nobody claims it and it reaches nothing important** → suspend it, wait
     a week, uninstall it.
   - **Nobody claims it but it is active on important repositories** → the
     dangerous case. Catalogue it with `decommissioning = true` and
     `repositories = ["app-quarantine"]` under your own team, then follow the
     normal removal stages. This gives you the reversible path.

### Monthly

1. **Upcoming reviews:**

   ```bash
   gh api repos/Delta-SK/github-app-governance/contents/terraform/catalogue.auto.tfvars \
     --jq .content | base64 -d \
     | sed -n '/^app_catalogue/,$p' | grep -E '^\s+[a-z0-9-]+ = \{|review_by'
   ```

   Contact owners with dates in the next 60 days.
2. **Stalled removals:** any app with `decommissioning = true` for more than
   a month should be released (stage 3) or have a reason in its pull request.
3. **Token expiry:** check both tokens' expiry dates (the owner's
   **Settings → Developer settings → Personal access tokens**, classic and
   fine-grained). Rotate at least two weeks before either expires — an
   expired read-only token fails every code plan, an expired admin token
   fails every plan and apply.
4. **Versions Dependabot does not manage** (the rest arrive as Dependabot
   pull requests every Monday — review them like any code change):
   - Terraform CLI: compare `.terraform-version` with the latest release
     (`gh api repos/hashicorp/terraform/releases/latest --jq .tag_name`). To
     upgrade, see [Upgrade Terraform](#upgrade-terraform).
   - Runner image: every workflow uses `ubuntu-24.04`. When GitHub announces
     its deprecation, move all workflows to the next LTS image in one pull
     request. Never use `ubuntu-latest`.
   - OpenSSF Scorecard: open the badge's report. A drop in
     *Pinned-Dependencies*, *Token-Permissions* or *Dangerous-Workflow* means
     a workflow change weakened the supply chain — fix it that month.
   - Run log warnings: open the latest `terraform-apply` run and check the
     annotations. Any deprecation notice (an action runtime, a provider
     argument, a Terraform feature) gets a pull request that month, not
     when it breaks.

### Install an approved app

1. Open the app's install page (Marketplace or the vendor's link) → install
   on **Delta-SK**.
2. Choose **Only select repositories** and pick **one** repository from the
   approved list — the least sensitive. Terraform sets the full list later.
3. Open org **Settings → GitHub Apps → the app → Configure** and copy the
   number at the end of the URL. That is the installation ID. Or, for the ID
   and the exact permissions in catalogue form:

   ```bash
   gh api orgs/Delta-SK/installations \
     --jq '.installations[] | select(.app_slug == "<slug>") | {id, permissions}'
   ```

4. Post the ID and permissions on the request issue. The requester (or you)
   opens the catalogue pull request.

Until that pull request is merged, the app is an orphan in every plan. Merge
it the same day.

### Uninstall an app (removal stage 4)

Only after the stage-3 (release) pull request is merged and applied.

1. Org **Settings → GitHub Apps → the app → Configure**.
2. Optional: **Suspend**, wait a day, confirm nothing broke.
3. **Uninstall**.
4. Revoke anything the app issued (deploy keys, webhooks, tokens in the
   vendor's dashboard).
5. `gh workflow run reconcile.yml -R Delta-SK/github-app-governance` — the
   *still installed* warning should be gone.

Never uninstall an app that is still in the catalogue: Terraform cannot read
an installation that no longer exists, and every plan in the org fails until
state is repaired by hand.

### Rotate the GitHub token

The pipeline uses two tokens, each an **environment** secret, never a
repository secret:

| Secret | Kind | Environments | Scopes |
| --- | --- | --- | --- |
| `TF_GITHUB_TOKEN` | classic PAT | `plan`, `production` | exactly `repo`, `admin:org` |
| `TF_GITHUB_READ_TOKEN` | fine-grained PAT, owner = the org | `plan-code` | all repositories; organisation *Administration: read*, *Members: read*; nothing else |

**Never** put `TF_GITHUB_TOKEN` in `plan-code`: that environment runs pull
request code with no approval. The weekly controls check fails if it is there.

1. The token's owner creates the replacement with exactly the scopes above
   and an expiry date.
2. Store it:

   ```bash
   R=Delta-SK/github-app-governance
   # the admin token
   for env in plan production; do gh secret set TF_GITHUB_TOKEN --env "$env" -R $R; done
   # or the read-only token
   gh secret set TF_GITHUB_READ_TOKEN --env plan-code -R $R
   ```

   (`gh` prompts for the value, so it never lands in shell history.)
3. Verify: `gh workflow run reconcile.yml -R Delta-SK/github-app-governance`
   and check it succeeds.
4. Delete the old token.

If the token may have leaked: do all of the above **immediately**, then check
the org audit log and this repository's Actions history for runs you do not
recognise.

### When an apply fails

1. Actions → the failed `terraform-apply` run → read the failing step.
2. Common causes:

   | Step | Cause | Fix |
   | --- | --- | --- |
   | plan (plan of record) | Something changed between the PR plan and merge — usually an expired review | Fix via a new pull request |
   | plan guard | The merged change releases an un-quarantined app or deletes a repository | Revert the merge; follow the removal stages |
   | apply, `401` | Token expired or revoked | [Rotate the token](#rotate-the-github-token), then re-run |
   | apply, `Error acquiring the state lock` | Another apply is running, or one crashed | Wait for any running apply. If none is running, see below |

3. Re-run once the cause is fixed: Actions → `terraform-apply` → **Run
   workflow** on `main`. The apply is safe to re-run; it recomputes the plan.

**Stuck state lock** (only when you are certain no apply is running — the
workflow never runs two at once):

```bash
cd terraform
terraform init
terraform force-unlock <LOCK_ID>     # the ID is printed in the error message
```

The lock is an object next to the state:
`s3://delta-sk-tfstate-751569314116/github-app-governance/terraform.tfstate.tflock`.
`force-unlock` deletes it; never delete it by hand while an apply might be
running.

### Upgrade Terraform

Terraform is pinned to one exact version in `.terraform-version`, which every
workflow and every engineer's version manager reads.

1. Read the release notes between the current and the target version, looking
   for backend, state or language changes.
2. In a branch: change `.terraform-version`. If the minor version changes
   (1.16 → 1.17), change `required_version` in `terraform/versions.tf` and
   `bootstrap/main.tf` to match (`~> 1.17.0`).
3. Locally, with the new version: `terraform init -upgrade` and
   `terraform validate` in both directories; `terraform plan` in
   `terraform/` must show no changes.
4. Open the pull request. It is a code change, so check its
   **Terraform plan — this pull request's code** comment shows no changes
   too.
5. Merge. The next apply writes state with the new version; from then on
   older binaries refuse it, so tell the team to upgrade.

### Stop managing a repository

The destroy guard refuses any plan that deletes a repository, by design. To
take a repository out of Terraform without deleting it:

1. Make sure no app lists it in the catalogue.
2. Locally, with state access, remove it from state (this changes nothing in
   GitHub):

   ```bash
   cd terraform && terraform init
   terraform state rm 'github_repository.this["old-repo"]' \
     'github_branch_protection.main["old-repo"]' \
     'github_repository_vulnerability_alerts.this["old-repo"]'
   ```

3. Immediately open and merge the pull request removing it from
   `repositories`. The plan should show no changes for it.

This is one of the few operations outside the pull request flow; record it
in the pull request description.

### Change bootstrap (teams, reviewers, rules on main)

`bootstrap/` holds the controls on this repository itself: its settings
(merge methods, secret scanning, push protection, private vulnerability
reporting), the ruleset on `main`, the `platform-engineering` team and its
members, app-owning teams created for the demo, the environments and their
reviewers, the automation labels, and the AWS state backend and roles. CI
never applies it — the pipeline must not be able to rewrite the rules that
constrain it.

1. Open a pull request with the change. CI checks formatting and validation
   only; it does not plan bootstrap.
2. After review and merge, an org owner with AWS administrator access applies
   it from their machine, with the Terraform version from `.terraform-version`:

   ```bash
   cd bootstrap
   terraform init
   terraform plan      # read it carefully — this is the control plane
   terraform apply
   ```

3. Verify: `gh workflow run reconcile.yml -R Delta-SK/github-app-governance`.
   The *repository controls* part must be clean.

### Break-glass

For when the pipeline cannot be used and waiting is worse than bypassing it.
Every use is followed, the same day, by a pull request that makes the
catalogue match reality — otherwise the next apply silently undoes it.

| Situation | Immediate action (org owner, UI) | Follow-up pull request |
| --- | --- | --- |
| An app is compromised or misbehaving | **Suspend** it: Settings → GitHub Apps → app → Configure → Suspend. Takes effect at once, reversible | Quarantine it (removal stage 1) |
| An app must lose one repository right now | App → Configure → remove the repository | Remove it from the catalogue. **Until merged, any apply puts it back** |
| CI itself is broken and a fix must merge | Nobody can bypass the rules on `main`. Open a temporary bypass — see below | The fix itself, then close the bypass |

**Opening a temporary bypass on `main`** (org owner, with bootstrap
credentials). The ruleset deliberately has no standing bypass actors, so
break-glass is a code change, visible in the ruleset's history:

1. In `bootstrap/github.tf`, add to `github_repository_ruleset.governance_main`:

   ```hcl
   bypass_actors {
     actor_type  = "OrganizationAdmin" # no actor_id for this type
     bypass_mode = "pull_request"      # merge a PR past the rules; no direct pushes
   }
   ```

2. `cd bootstrap && terraform apply`, merge the fix, then remove the block and
   apply again — the same day.
3. Commit both edits through a normal pull request afterwards, so the history
   records the window.

Until the bypass is removed, the weekly controls check reports it.

After any break-glass action, run `gh workflow run reconcile.yml
-R Delta-SK/github-app-governance` and make sure the resulting issue reflects
exactly what you did — then close it out through the follow-up pull request.

### Useful commands

```bash
R=Delta-SK/github-app-governance

gh workflow run reconcile.yml -R $R                 # run the full check now
gh issue list -R $R --label reconciliation          # open findings
gh run list -R $R --workflow terraform-apply.yml    # recent applies
gh api orgs/Delta-SK/installations \
  --jq '.installations[] | "\(.app_slug)\t\(.id)\t\(.repository_selection)"'   # what is installed

# Needs the classic PAT in $GITHUB_TOKEN and state access:
cd terraform && terraform init
terraform output app_access_matrix                  # what Terraform intends
terraform output org_installations                  # what is installed, declared or not
GH_TOKEN=$GITHUB_TOKEN ../scripts/verify-repo-controls.sh $R
```
