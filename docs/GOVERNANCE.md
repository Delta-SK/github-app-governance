# Governing GitHub Apps at scale

How an organisation with hundreds of installed GitHub Apps tracks ownership,
reviews access, finds apps nobody remembers installing, and removes them
safely.

The implementation in this repository demonstrates the mechanism on two apps
and two repositories. This document describes the operating model it is a
scale model of.

---

## 1. The failure mode

Nobody sets out to install two hundred GitHub Apps. It happens like this:

- An engineer installs an app to try it. It works. They move on.
- A vendor's onboarding flow installs an app as a side effect of signing up.
- A team adopts a CI tool; the app gets org-wide access because that was the
  default and narrowing it looked like extra work.
- The engineer who installed it leaves.

Each step is individually reasonable. The aggregate is an organisation where
dozens of third parties hold read or write access to source code, and no
current employee can say why.

Three properties make this hard to fix reactively:

- **No ownership record.** GitHub records *who installed* an app, but only in
  the audit log, and only for a retention window. It never records *who is
  accountable for it now*.
- **No expiry.** An installation persists until somebody deliberately removes
  it. There is no natural moment at which anyone reconsiders.
- **Removal is risky.** Uninstalling an app that turns out to be load-bearing
  breaks pipelines, and the blast radius is unknown before you try.

The fix therefore cannot be a cleanup project. It has to be a control that
makes the problem structurally unable to recur.

---

## 2. Ownership

**The catalogue is the authorisation record.** An installation that is not in
`catalogue.auto.tfvars` is unauthorised by definition — not "undocumented", not
"pending review". Unauthorised.

Every entry carries:

| Field | Why it exists |
| --- | --- |
| `owner` | A **team**, never a person. People leave; teams are reassigned |
| `purpose` | What it does, in one line, for someone who has never heard of it |
| `justification` | Why the org accepts the risk. The field a security reviewer reads |
| `review_by` | The date this stops being assumed-good |
| `repositories` | The access itself — enforced, not documented |
| `permissions` | What the app may do there, as approved — compared with the live installation on every plan |

`owner` being a team rather than an individual is the single highest-value
constraint here. Individual ownership decays silently the moment someone
changes role; team ownership decays visibly, because the team still exists to
be asked.

**Enforcement.** `variables.tf` rejects an empty `owner`, `purpose` or
`justification` and a malformed `review_by` at plan time. The
`owners_are_real_teams` check compares every `owner` with the teams that
actually exist in the org, so a team deleted in a reorg is flagged on the next
plan instead of quietly leaving its apps unowned. CODEOWNERS routes catalogue
changes to the platform team. The access change and its justification arrive
in the same diff, so approving the access means approving the reason.

### At scale

One file becomes `catalogue/<team>.auto.tfvars`, one per owning team, with
CODEOWNERS granting each team write over its own file. Review distributes;
the schema does not change. A central team retains ownership of `checks.tf`
and the workflows — the controls themselves stay centrally governed even as
the entries federate.

---

## 3. Review and expiry

Every entry carries `review_by`. The precondition in `app_access.tf` fails on
every plan once that date passes, naming the app and its owning team.

The escalation ladder — increasing pressure, never a surprise:

| When | What happens | Status |
| --- | --- | --- |
| `review_by` − 30 days | Warning surfaces on every plan | **Implemented** — `reviews_are_due_soon` in `checks.tf` |
| `review_by` | Plan **fails**; no change to any app can be applied until the entry is reconciled | **Implemented** — resource precondition in `app_access.tf` |
| weekly, regardless | Reconciler raises an issue naming the app and owner | **Implemented** — `reconcile.yml` |
| `review_by` + 30 days | Automated PR narrowing the app to the quarantine repository | Designed, not implemented |
| PR merged or overridden | Owner either defends the access or it lapses | Follows from the above |

A `review_by` date can be at most `max_review_days` (366) away — enforced by a
precondition — so "renew once for ten years" is not available as a way out of
review.

Expiry is a **blocking** condition rather than a warning, and that choice is
deliberate. A `check` block would let an expired app keep being applied
indefinitely, which makes the review date decorative — the failure mode it is
supposed to prevent. A resource precondition stops the plan.

Note the asymmetry with orphan detection, which only warns. Stale data you own
should block your own apply. An installation somebody else added should not
block your unrelated change — that would teach people to route around the
pipeline, which is worse than the orphan.

The important inversion is at the bottom of the ladder: **the default outcome
should be removal.** An owner who wants to keep access must act; in the common
failure mode — the owning team no longer exists, or no longer cares — nobody
acts, and the access disappears.

Be precise about how much of that is built. Today the default outcome of
inaction is a **blocked pipeline and an open issue naming the owner** — the
access itself stays until somebody opens the quarantine pull request. That is
already far better than silence: nobody can change *any* app until the lapsed
one is dealt with, so it cannot be ignored for long. Closing the gap — the
reconciler opening the quarantine PR itself — is the next thing to build.

Without the inversion, expiry dates are decoration. With it, the org's attack
surface shrinks by default and grows only deliberately.

Review cadence should follow risk, not a uniform calendar: an app with `write`
on the payments repository deserves quarterly review; an app with `read` on a
docs repo deserves annual. Cadence derives from the permissions the app holds
and the sensitivity of the repositories it reaches.

---

## 4. Detecting the app nobody remembers installing

Memory is not a control. **Reconciliation is.**

Two sources of truth, continuously compared:

- **Intent** — the catalogue, in Git.
- **Reality** — `GET /orgs/{org}/installations`, exposed in Terraform as
  `data.github_organization_app_installations`.

Anything in reality but not in intent is an orphan. That is the entire
detection mechanism, and it is implemented in `checks.tf`:

```hcl
orphans = setsubtract(local.installed_slugs, setunion(local.catalogued, local.tombstoned))
```

Non-empty means somebody installed something outside the process. Tombstoned
apps are excluded because they get a more specific message of their own
(§5). The reverse comparison matters too: a catalogued app that is no longer
installed, or whose `installation_id` belongs to a different app, is flagged
— the second one blocks, since Terraform would otherwise act on the wrong
installation.

It runs in two places, and it needs both:

- **On every plan**, so an orphan surfaces the moment anyone touches the
  configuration, in the pull request where they will see it.
- **Weekly, on a schedule** (`reconcile.yml`), because detection cannot depend
  on somebody happening to open a pull request. A quiet repository is exactly
  where an orphan survives longest. The scheduled run opens a GitHub issue and
  closes it automatically once the organisation matches the catalogue again.

One trap here cost a real bug: a failing `check` block is a **warning**, and
`terraform plan -detailed-exitcode` still exits 0. A reconciler keyed on the
exit code never reports an orphan at all — and would close an open issue
while the orphan is still installed. The reconciler therefore reads check
results out of the saved plan (`terraform show -json` → `.checks[]`), which
was verified against a plan with a failing check.

### Triage

Detection gives you a name. Deciding what to do needs more:

| Question | Source |
| --- | --- |
| Who installed it, and when? | `GET /orgs/{org}/audit-log` (**Enterprise Cloud only**) |
| Is it still being used? | No direct signal: GitHub does not expose per-installation usage to org owners. On Enterprise Cloud the audit log attributes API activity to the integration; otherwise ask the vendor, check the app's webhook deliveries, and let the quarantine soak (§5) answer it empirically |
| What could it reach? | `permissions` and `repository_selection` from the data source |
| How much damage could it do? | Permissions × sensitivity of reachable repos |

`created_at` from the installations API gives a lower bound on age even without
the audit log — useful on lower GitHub tiers, where the audit log is
unavailable and provenance may be genuinely unrecoverable.

The triage split that matters:

- **Forgotten and inactive** — no activity you can find in 90 days. Low risk,
  remove on the standard path.
- **Forgotten but active** — something depends on it and nobody knows what.
  This is the dangerous quadrant. An unowned app with live write access is
  both a supply-chain risk *and* a latent outage if removed carelessly.

Prioritise by `permissions × repository sensitivity`, not by count. One
forgotten app with `contents: write` on the payments service outranks fifty
read-only apps on documentation repositories.

---

## 5. Safe decommissioning

Removing an app is not one action. It is a staged descent where every early
step is reversible and the irreversible step comes last. The order below is
not a preference: it is dictated by how the provider behaves, which was read
from its source (v6.13.0, `resource_github_app_installation_repositories.go`)
rather than assumed:

| Provider operation | Behaviour | Consequence for the runbook |
| --- | --- | --- |
| update | adds new repositories, *then* removes old ones | Moving an app onto the quarantine repository is safe |
| update to `[]` | skips every removal, reports success | Empty lists are rejected in `variables.tf` |
| destroy | removes every repository **except one arbitrary one** | Release an app only once it reaches the quarantine repository alone — enforced by `scripts/plan-guard.sh` |
| read of a missing installation | errors, failing every plan | Release from Terraform **before** uninstalling |

### Stage 1 — Quarantine *(reversible: `git revert`)*

```hcl
imgbot = {
  decommissioning = true
  repositories = [
    "app-quarantine",   # was ["web-frontend"]
  ]
}
```

Merge the PR. The installation still exists but reaches only a repository that
contains nothing. If this breaks something, revert the commit and access
returns within one apply.

This is the key move: it converts an irreversible administrative action into a
reversible code change, reviewed like any other.

**Why a quarantine repository instead of an empty list.** GitHub will not let
an installation drop its last repository, and the provider responds to an
empty list by silently skipping the removals — `terraform apply` reports
success, nothing changes, and every later plan shows the same diff. This was
found by testing and then confirmed in the provider source; an earlier draft
of this runbook said "narrow to zero" and would not have worked.

**Why the `decommissioning` flag.** It lets an **expired** app be quarantined:
without it, the expiry precondition would block the change, forcing an owner
to extend the review date of an app they are trying to remove. It cannot be
abused to keep access — a validation only accepts `decommissioning = true`
together with the quarantine repository alone, and forbids any other app from
using that repository. Decommissioning apps are also exempt from the review
and suspension warnings, so following this runbook raises no alerts.

### Stage 2 — Soak *(7–14 days)*

Watch for breakage and for anything that still expects the app. Breakage
during the soak means something depended on the app and the dependency was
undocumented — revert, find the owner, and restart the review.

Two weeks covers most fortnightly and monthly batch jobs. Extend for anything
with a quarterly cycle.

### Stage 3 — Release and tombstone *(reversible: re-add the entry)*

One pull request moves the entry from `catalogue.auto.tfvars` to
`decommissioned.auto.tfvars`:

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

The plan shows the app's access resource being destroyed. Because the app
reaches only the quarantine repository, the provider's destroy leaves exactly
that repository in place — nothing real is touched. Had the app still reached
real repositories, the guard would have refused the plan, both on the pull
request and again in the apply job.

This must happen **while the app is still installed**. The provider cannot
read an installation that no longer exists, and Terraform's `removed` block
cannot target a single `for_each` instance, so an app uninstalled first would
break every plan until someone edited state by hand.

### Stage 4 — Suspend, then uninstall *(org settings UI)*

Org **Settings → GitHub Apps → the app → Configure**. Suspend first if you
want one more reversible step — suspension blocks the installation entirely,
including anything repository scoping did not cover — then uninstall.

On the plan used here, Terraform cannot do this, and neither can a script run
by an org owner: the app-level REST endpoints for suspending and deleting an
installation require the app's own credentials. It is a human action.

On **GitHub Enterprise Cloud** it need not be. An enterprise-owned GitHub App
with *Enterprise organization installations* (write) can call
`DELETE /enterprises/{e}/apps/organizations/{org}/installations/{id}` — so
stage 4 can become the last step of an automated, still staged and still
reviewed, decommissioning (README, *What this costs, and what it would cost
at scale*).

Between stage 3 and stage 4 the `tombstones_are_uninstalled` check warns that
the app is still installed. That warning is the reminder to finish; it clears
itself once the app is gone. Afterwards: revoke any credentials the app issued
and remove any webhooks it installed.

### Tombstones

The tombstone is not a comment — it is data the checks read. Six months later
someone will ask "did we ever use X, and why did we stop?", and
`terraform output decommissioned_apps` answers it. More importantly, if
somebody reinstalls a tombstoned app, the plan and the weekly reconciler say
so **together with the reason it was removed**, instead of reporting a
generic orphan. The org's earlier decision is surfaced at the moment someone
is about to unknowingly reverse it.

---

## 6. Making it structural

Detection and cleanup are necessary but not sufficient — they treat symptoms.
The recurrence is prevented at the org settings level:

1. **Restrict who can install and request apps.** Only organisation owners
   can install apps on an organisation; everyone else can only *request*.
   Since January 2026, **Member privileges → App access requests** also
   controls who may request — members and outside collaborators, members
   only, or nobody. Set it to *members only*, so outside collaborators cannot
   generate requests, or to *disabled* once the request form in this
   repository (`.github/ISSUE_TEMPLATE/app-request.yml`) is the one channel.
   This converts the problem from *unbounded* to *reviewed*.
2. **Make the catalogue PR the request channel.** An engineer who wants an app
   opens a PR adding a catalogue entry. Review is the approval. Merge is the
   installation authorisation. There is no other path.
3. **Default to narrow scope.** New entries name specific repositories. Org-wide
   access is available, but as a deliberate, justified, reviewed exception.
4. **Review permissions, not just repositories.** Every catalogue entry
   records the `permissions` it was approved with, and the
   `permissions_match_catalogue` check compares them with the live
   installation on every plan and every week. That matters because
   permissions change *outside* this repository: an app update asks for more,
   and an owner accepts in the UI. The next plan names the app and each
   permission that moved; the response is a pull request that either records
   the new permissions — approving them, with a reason — or starts
   decommissioning.

What remains of the gap: permissions are **detected**, not **enforced**.
Terraform cannot refuse an owner's acceptance of wider permissions; it can
only make it visible within a week and force an explicit decision. Scope and
permission are separate axes: scope is enforced as code, permission is
audited as code.

---

## 7. What this looks like at 500 apps

| Concern | Response |
| --- | --- |
| Review bottleneck | Per-team catalogue files, per-team CODEOWNERS |
| Plan time | Split state per team; plans stay proportional to one team's apps. App access already accepts repos managed elsewhere |
| API rate limits | The installations read is one call; per-app resources are not. Paginate, back off, and split state before this bites |
| Blast radius of a bad apply | Per-team state means a mistake affects one team |
| Signal fatigue | Orphan and expiry findings need SLAs and routing, not a wall of warnings. One issue per team rather than one per org |
| Plan approvals | None needed. Catalogue pull requests are planned by main's code with the admin token (data cannot execute); code pull requests by their own code with a read-only token. The only approval is the pull request review, made with both plans in view |
| Credential | On Enterprise Cloud: an enterprise-owned GitHub App with only *Enterprise organization installation repositories* — no human token at all. Elsewhere: a machine user's PAT in a secrets manager with rotation (README, *Authentication*) |
| Many organisations | The enterprise installations API lists every installation in every organisation of the enterprise: one reconciler, one inventory, orphans visible org-wide rather than per org |
| Audit evidence | Git history *is* the audit trail: who approved what access, when, and why — plus the plan of record in each apply log |

That last row is the real prize. "Show me every change to third-party access
in the last year, with the approver" is a `git log` on one directory — not a
ticket to the platform team and a week of screenshots. It holds because
nothing bypasses the rules on `main`: the ruleset has no bypass actors, so
every change carries a second person's approval, and break-glass is itself a
visible change to the ruleset.
