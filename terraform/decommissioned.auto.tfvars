# ---------------------------------------------------------------------------
# TOMBSTONES — apps this organisation has removed, and why.
#
# An app moves here from catalogue.auto.tfvars in the pull request that
# releases it from Terraform (docs/OPERATIONS.md, "Decommission an app").
# Entries are never deleted: six months from now somebody will ask "did we
# ever use X, and why did we stop?", and this file answers it.
#
# If a tombstoned app is found installed again, every plan and the weekly
# reconciler name it together with the reason below.
#
# Example:
#
#   imgbot = {
#     removed_on       = "2026-11-14"
#     owner_at_removal = "web-team"
#     reason           = "Replaced by image optimisation in the build pipeline."
#     ticket           = "PLAT-2291"
#   }
# ---------------------------------------------------------------------------

decommissioned_apps = {}
