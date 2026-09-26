// Policy settings: the rules that judge the catalogue, and where it applies.
//
// Deliberately locals, not variables. Every *.tfvars file is data that pull
// requests change and that terraform-plan.yml plans automatically with the
// organisation-admin credential. If these were variables, a catalogue pull
// request could quietly add `max_review_days = 99999` or point the whole plan
// at another organisation. As locals they can only change through a code
// change, which CODEOWNERS routes to the platform team and which is planned by
// the approval-gated terraform-plan-code.yml.

locals {
  # GitHub organisation being governed. The only org-specific value in this
  # directory apart from the backend block and the catalogue itself.
  github_org = "Delta-SK"

  # How long before review_by to start warning on every plan. Expiry itself
  # blocks (app_access.tf); this is the advance notice.
  review_warning_days = 30

  # Furthest a review_by date may be set in the future. Without a ceiling,
  # `review_by = "2099-12-31"` quietly opts an app out of review.
  max_review_days = 366

  # Repository that apps being decommissioned are narrowed to. GitHub will not
  # let an installation drop its last repository, so "revoke all access" has
  # to be expressed as "point it at a repository containing nothing".
  quarantine_repository = "app-quarantine"
}
