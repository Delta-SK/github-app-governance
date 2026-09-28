# 0001 — A classic PAT drives installation access, until an Enterprise App can

Accepted, 2026-09-25.

## Context

`github_app_installation_repositories` calls user-to-server endpoints:

```text
GET    /user/installations/{installation_id}/repositories
PUT    /user/installations/{installation_id}/repositories/{repository_id}
DELETE /user/installations/{installation_id}/repositories/{repository_id}
```

Tested against the test organisation:

| Credential | Result |
| --- | --- |
| GitHub App installation token, Actions `GITHUB_TOKEN` | Cannot call `/user/...` at all |
| Fine-grained PAT, *Administration* read/write at repository and organisation level | `200` on `/orgs/{org}/installations`; `403 Resource not accessible by personal access token` on both installation-repository endpoints — no fine-grained support exists |
| Classic PAT (`repo`, `admin:org`) of an organisation owner | `204` on `PUT` and `DELETE` |

A trap: `GET /user/installations` (all installations) rejects classic PATs
with a 403 that suggests PATs are unusable. The provider never calls it.

## Decision

Use a classic PAT with exactly `repo` and `admin:org`, held only in the
environments where `main`'s code runs (0002). Use a read-only fine-grained
token wherever reading is enough.

## Consequences

- The strongest credential is human-owned, long-lived, and reaches every
  organisation its owner belongs to. Its exposure is limited by *where it is
  reachable*, not by its scope. A dedicated machine user is the minimum
  production improvement.
- Enabling the organisation policy that restricts classic PATs — the natural
  answer to "what about PATs?" — would cut this pipeline off.
- **Production path, on GitHub Enterprise Cloud:** an enterprise-owned GitHub
  App with *Enterprise organization installation repositories* (read/write)
  can manage any installation's repositories server-to-server through
  `/enterprises/{e}/apps/organizations/{org}/installations/{id}/repositories`
  (`add`, `remove`), across every organisation in the enterprise; with
  *Enterprise organization installations* it can also install and uninstall.
  `integrations/github` 6.13 has no resource for these endpoints; migrating
  means a thin adapter over them (or an upstream resource) behind the same
  catalogue, checks and workflows, and retiring the PAT. Not buildable on the
  Free-plan test organisation.
