# Decision records

Each significant design decision, recorded once: the situation, what was
decided, and what it costs. Code comments and the other documents point here
instead of repeating the reasoning.

| # | Decision |
| --- | --- |
| [0001](0001-classic-pat-for-installation-access.md) | A classic PAT drives installation access — until an Enterprise App can |
| [0002](0002-plan-data-and-code-separately.md) | Plan pull request data with main's code, and pull request code with a read-only token |
| [0003](0003-decommission-through-quarantine.md) | Revoke through a quarantine repository; release before uninstalling |
| [0004](0004-expiry-revokes-instead-of-blocking.md) | A lapsed review revokes access instead of blocking plans; cadence follows risk |
| [0005](0005-rules-on-main-without-bypass.md) | Rules on `main` are a ruleset with no bypass actors |
| [0006](0006-bootstrap-apart-and-drift-planned.md) | Bootstrap is applied by hand, in its own state, and drift-planned weekly |
| [0007](0007-policy-is-code-catalogue-is-data.md) | Policy settings are code; the catalogue is data |
| [0008](0008-permissions-are-audited-not-enforced.md) | App permissions are recorded and compared, not enforced |
