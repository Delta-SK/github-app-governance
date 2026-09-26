# Security policy

This repository controls which repositories third-party GitHub Apps can
reach, and its CI holds an organisation-admin token. A weakness here is a
weakness in every repository the organisation owns, so reports are welcome
and treated as urgent.

## Reporting a vulnerability

**Do not open a public issue or pull request.** Report privately through
GitHub's private vulnerability reporting:

<https://github.com/Delta-SK/github-app-governance/security/advisories/new>

Please include what you found, how to reproduce it, and what an attacker
could gain. You do not need a fix.

## What to expect

| Step | Within |
| --- | --- |
| Acknowledgement | 3 business days |
| Assessment and severity | 7 days |
| Fix, or a documented decision not to fix | 30 days; sooner for anything exposing the credential |
| Public disclosure | Coordinated with you, after the fix is applied |

## In scope

- The workflows under `.github/workflows/`, especially anything that could
  run pull request code next to `TF_GITHUB_TOKEN` (see README, *The trust
  boundary*)
- The scripts under `scripts/`, and the Terraform under `terraform/` and
  `bootstrap/`
- Anything that lets a GitHub App gain repository access without a reviewed
  pull request

## Leaked credentials

If you believe `TF_GITHUB_TOKEN` or any other credential has leaked, report
it immediately through the link above. The platform team rotates it using
[docs/OPERATIONS.md, *Rotate the GitHub token*](docs/OPERATIONS.md#rotate-the-github-token)
before anything else.

## Supported versions

Only `main` is supported. There are no releases.
