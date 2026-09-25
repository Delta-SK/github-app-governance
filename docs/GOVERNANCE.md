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

`owner` being a team rather than an individual is the single highest-value
constraint here. Individual ownership decays silently the moment someone
changes role; team ownership decays visibly, because the team still exists to
be asked.

**Enforcement.** `variables.tf` rejects an empty `owner` or a malformed
`review_by` at plan time. CODEOWNERS routes catalogue changes to the platform
team. The access change and its justification arrive in the same diff, so
approving the access means approving the reason.

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
| `review_by` + 30 days | Automated PR narrowing the app to zero repositories | Designed, not implemented |
| PR merged or overridden | Owner either defends the access or it lapses | Follows from the above |

Expiry is a **blocking** condition rather than a warning, and that choice is
deliberate. A `check` block would let an expired app keep being applied
indefinitely, which makes the review date decorative — the failure mode it is
supposed to prevent. A resource precondition stops the plan.

Note the asymmetry with orphan detection, which only warns. Stale data you own
should block your own apply. An installation somebody else added should not
block your unrelated change — that would teach people to route around the
pipeline, which is worse than the orphan.

The important inversion is at the bottom: **the default outcome is removal.**
An owner who wants to keep access must act. In the common failure mode — the
owning team no longer exists, or no longer cares — nobody acts, and the access
correctly disappears.

Without that inversion, expiry dates are decoration. With it, the org's
attack surface shrinks by default and grows only deliberately.

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
setsubtract(
  toset([for i in ...live.installations : i.app_slug]),
  toset(keys(var.app_catalogue))
)
```

Non-empty means somebody installed something outside the process.

It runs in two places, and it needs both:

- **On every plan**, so an orphan surfaces the moment anyone touches the
  configuration, in the pull request where they will see it.
- **Weekly, on a schedule** (`reconcile.yml`), because detection cannot depend
  on somebody happening to open a pull request. A quiet repository is exactly
  where an orphan survives longest. The scheduled run opens a GitHub issue and
  closes it automatically once the organisation matches the catalogue again.

### Triage

Detection gives you a name. Deciding what to do needs more:

| Question | Source |
| --- | --- |
| Who installed it, and when? | `GET /orgs/{org}/audit-log` (**Enterprise Cloud only**) |
| Is it still being used? | Installation token request activity |
| What could it reach? | `permissions` and `repository_selection` from the data source |
| How much damage could it do? | Permissions × sensitivity of reachable repos |

`created_at` from the installations API gives a lower bound on age even without
the audit log — useful on lower GitHub tiers, where the audit log is
unavailable and provenance may be genuinely unrecoverable.

The triage split that matters:

- **Forgotten and inactive** — no token activity in 90 days. Low risk, remove
  on the standard path.
- **Forgotten but active** — something depends on it and nobody knows what.
  This is the dangerous quadrant. An unowned app with live write access is
  both a supply-chain risk *and* a latent outage if removed carelessly.

Prioritise by `permissions × repository sensitivity`, not by count. One
forgotten app with `contents: write` on the payments service outranks fifty
read-only apps on documentation repositories.

---

## 5. Safe decommissioning

Removing an app is not one action. It is a staged descent where every early
step is reversible and the irreversible step comes last.

### Stage 1 — Narrow to the quarantine repository *(reversible: `git revert`)*

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

**Why a quarantine repository instead of an empty list.** GitHub refuses to
remove an installation's last repository:

```
422 Cannot remove the last repository from this installation.
```

The Terraform provider does not surface that error. `terraform apply` reports
success, nothing actually changes, and every subsequent plan shows the same
pending diff — a silent permanent drift loop rather than a clean failure. This
was found by testing, not by reading; an earlier draft of this runbook said
"narrow to zero" and would not have worked.

`terraform/variables.tf` therefore rejects an empty list at plan time with a
message pointing here, and `app-quarantine` exists so that "reaches nothing
useful" is expressible at all.

The `decommissioning = true` flag is what lets an **expired** app be removed.
Without it the expiry precondition would block the change, forcing an owner to
extend the review date of an app they are trying to delete — the control
preventing the outcome it exists to encourage.

### Stage 2 — Soak *(7–14 days)*

Watch for breakage and for token activity that should no longer exist. Activity
during the soak means something still depends on the app and the dependency was
undocumented — investigate before continuing.

Two weeks covers most fortnightly and monthly batch jobs. Extend for anything
with a quarterly cycle.

### Stage 3 — Suspend *(reversible, UI or API)*

Suspending blocks the installation entirely, including any access path that
repository scoping did not cover. Stronger than zero-repos, still reversible
with one click.

### Stage 4 — Uninstall *(irreversible)*

```
DELETE /app/installations/{installation_id}
```

Terraform cannot do this — it manages installation *scope*, never installation
*existence*. A human or a separate script performs it.

Then: revoke any credentials the app issued, remove any webhooks it installed,
and replace the catalogue entry with a tombstone.

### Tombstones

Do not delete the catalogue entry. Move it to `decommissioned/` with the
removal date and reason:

```hcl
# Removed 2026-11-14. Replaced by native Dependabot.
# Owner at removal: platform-engineering. Ticket: PLAT-2291.
```

Six months later someone will ask "did we ever use X, and why did we stop?"
The tombstone answers it, and prevents the app being reinstalled by someone
solving the same problem again.

---

## 6. Making it structural

Detection and cleanup are necessary but not sufficient — they treat symptoms.
The recurrence is prevented at the org settings level:

1. **Restrict who can install apps.** Org settings → third-party application
   access. Only owners install; everyone else requests. This alone converts
   the problem from *unbounded* to *reviewed*.
2. **Make the catalogue PR the request channel.** An engineer who wants an app
   opens a PR adding a catalogue entry. Review is the approval. Merge is the
   installation authorisation. There is no other path.
3. **Default to narrow scope.** New entries name specific repositories. Org-wide
   access is available, but as a deliberate, justified, reviewed exception.
4. **Review permissions, not just repositories.** This implementation governs
   *which repositories* an app reaches. *What it can do* there is fixed by the
   app's manifest and is not Terraform-manageable — so permission changes on an
   app version bump need catching at review time, and should be part of the
   `review_by` cycle rather than assumed stable.

Point 4 is the honest gap in this design. Repository scoping bounds blast
radius; it does not bound capability. An app with `contents: write` on one
repository can still do everything `contents: write` allows on that repository.
Scope and permission are separate axes and only one of them is code here.

---

## 7. What this looks like at 500 apps

| Concern | Response |
| --- | --- |
| Review bottleneck | Per-team catalogue files, per-team CODEOWNERS |
| Plan time | Split state per team; plans stay proportional to one team's apps |
| API rate limits | The installations read is one call; per-app resources are not. Paginate, back off, and split state before this bites |
| Blast radius of a bad apply | Per-team state means a mistake affects one team |
| Signal fatigue | Orphan and expiry findings need SLAs and routing, not a wall of warnings |
| Audit evidence | Git history *is* the audit trail: who approved what access, when, and why |

That last row is the real prize. "Show me every change to third-party access
in the last year, with the approver" is a `git log` on one directory — not a
ticket to the platform team and a week of screenshots.
