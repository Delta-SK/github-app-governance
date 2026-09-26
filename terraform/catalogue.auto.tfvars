# ---------------------------------------------------------------------------
# THE CATALOGUE — source of truth for GitHub App access in this organisation.
#
# Changing an app's `repositories` list and merging the pull request is the
# only supported way to alter what an app can reach. Nothing here is set in
# the GitHub UI.
#
# At organisation scale this file splits per owning team
# (catalogue/<team>.auto.tfvars) with CODEOWNERS routing review. The schema
# does not change; see docs/GOVERNANCE.md.
# ---------------------------------------------------------------------------

repositories = {
  payments-api = {
    description = "Payment processing service"
    topics      = ["service", "payments"]
  }

  web-frontend = {
    description = "Customer-facing web application"
    topics      = ["frontend"]
  }

  # Holding pen for apps being decommissioned. GitHub refuses to remove an
  # installation's last repository, so "revoke all access" is expressed as
  # "point it at a repository containing nothing". Deliberately empty and
  # deliberately boring.
  app-quarantine = {
    description = "Intentionally empty. Apps pending decommissioning are pointed here to strip their effective access."
    topics      = ["governance"]
  }
}

app_catalogue = {
  renovate = {
    installation_id = "164801077"
    owner           = "platform-engineering"
    purpose         = "Automated dependency update pull requests"
    justification   = "Keeps transitive dependencies patched without manual tracking; required by the supply-chain policy."
    review_by       = "2027-03-31"
    # Narrowed 2026-09-25: web-frontend pins dependencies via its own
    # lockfile workflow, so Renovate's access there was redundant.
    # Ticket: PLAT-1184
    repositories = [
      "payments-api",
    ]
    # Approved 2026-09-25 with the installation. Broad by nature: Renovate
    # edits workflow files (workflows) and reads the org to assign reviewers.
    permissions = {
      administration       = "read"
      checks               = "write"
      contents             = "write"
      issues               = "write"
      members              = "read"
      metadata             = "read"
      packages             = "read"
      pull_requests        = "write"
      statuses             = "write"
      vulnerability_alerts = "read"
      workflows            = "write"
    }
  }

  imgbot = {
    installation_id = "164802659"
    owner           = "web-team"
    purpose         = "Lossless image compression pull requests"
    justification   = "Reduces page weight on the marketing site. Only meaningful where images are served."
    review_by       = "2027-01-31"
    repositories = [
      "web-frontend",
    ]
    permissions = {
      contents      = "write"
      metadata      = "read"
      pull_requests = "write"
    }
  }
}
