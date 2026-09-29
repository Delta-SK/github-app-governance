# The catalogue: every GitHub App allowed in the organisation, who owns it,
# why, until when, what it may do and which repositories it may reach.
# Change it only through a pull request (docs/OPERATIONS.md).

repositories = {
  payments-api = {
    description = "Payment processing service"
    topics      = ["service", "payments"]
  }

  web-frontend = {
    description = "Customer-facing web application"
    topics      = ["frontend"]
  }

  # Deliberately empty: where revoked apps point (docs/decisions/0003).
  app-quarantine = {
    description = "Intentionally empty. Apps pending decommissioning are pointed here to strip their effective access."
    topics      = ["governance"]
  }
}

app_catalogue = {
  renovate = {
    owner         = "platform-engineering"
    purpose       = "Automated dependency update pull requests"
    justification = "Keeps transitive dependencies patched without manual tracking; required by the supply-chain policy."
    review_by     = "2026-12-15"
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
    owner         = "web-team"
    purpose       = "Lossless image compression pull requests"
    justification = "Reduces page weight on the marketing site. Only meaningful where images are served."
    review_by     = "2027-01-31"
    repositories = [
      "web-frontend",
    ]
    permissions = {
      contents      = "write"
      metadata      = "read"
      pull_requests = "write"
    }
  }

  render = {
    owner         = "web-team"
    purpose       = "Temporary governance demonstration"
    justification = "Test installation used to demonstrate controlled GitHub App onboarding."
    review_by     = "2026-12-15"

    repositories = [
      "web-frontend",
    ]

    permissions = {
      contents             = "read"
      metadata             = "read"
      actions              = "write"
      checks               = "write"
      deployments          = "write"
      environments         = "write"
      issues               = "write"
      pull_requests        = "write"
      repository_hooks     = "write"
      statuses             = "write"
      vulnerability_alerts = "read"
      workflows            = "write"
    }
  }

  codefactor-io = {
    owner         = "payments-team"
    purpose       = "Temporary governance demonstration"
    justification = "Test installation used to demonstrate controlled GitHub App onboarding."
    review_by     = "2026-12-15"

    repositories = [
      "payments-api",
    ]

    permissions = {
      administration              = "read"
      checks                      = "write"
      contents                    = "write"
      issues                      = "write"
      members                     = "read"
      metadata                    = "read"
      organization_administration = "read"
      pull_requests               = "write"
      repository_hooks            = "write"
      statuses                    = "write"
    }

  }
}
