// Live installation inventory, read from GET /orgs/{org}/installations.
//
// Declared at top level rather than scoped inside the check block so the
// org_installations output can expose it too. The trade-off: if this read
// fails the whole plan fails, where a scoped data source would only fail its
// check. Acceptable here because the same credential already drives every
// other resource — if this call fails, nothing else would work either.
data "github_organization_app_installations" "audit" {}

// Real teams in the org. An `owner` field that names a team which does not
// exist is precisely how an app becomes unowned — the team is deleted or
// renamed during a reorg and the catalogue quietly keeps pointing at a ghost.
data "github_organization_teams" "all" {
  summary_only = true
}
