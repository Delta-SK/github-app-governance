<!--
  Catalogue changes: fill in the section that matches your change and delete the rest.
  Step-by-step help: docs/OPERATIONS.md
-->
<!-- markdownlint-disable-file MD041 -- a pull request body has no title heading -->

## What changes

<!-- One line, e.g. "Grant Renovate access to web-frontend" -->

**Type:** new app / add access / narrow access / review renewal / decommission (quarantine) / decommission (release) / other

**App(s):**
**Owning team:**
**Ticket:**

## Why

<!-- New app or wider access: what problem it solves, and why these repositories and no others. -->
<!-- Review renewal: who confirmed the access is still needed, and how. -->
<!-- Decommission: why it is being removed; what replaces it, if anything. -->

## Author checklist

- [ ] The owning team is a real GitHub team and has agreed to own this app
- [ ] `review_by` is no more than 12 months out
- [ ] Every listed repository is actually needed — not "might be useful"
- [ ] For a release: the app has been in quarantine for the whole soak period (7–14 days) with nothing breaking

## Reviewer checklist

- [ ] `validate` and `terraform-plan` are green
- [ ] The **Terraform plan — catalogue** comment shows only the changes described above, and `destroy guard` is `success`
- [ ] If that comment says the PR **also changes code**: every line under `.github/`, `scripts/` and `*.tf` has been read before approving the `terraform-plan-code` run, and its plan matches the intent
- [ ] The app's permissions (org Settings → GitHub Apps → the app) are appropriate for the repositories it gains
