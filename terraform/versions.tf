terraform {
  # The exact version is pinned once, in /.terraform-version, which CI and
  # version managers (tfenv, tfswitch, mise) all read. This constraint only
  # stops an incompatible binary from touching the state.
  required_version = "~> 1.16.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # Backend values are literals by design — Terraform forbids variables here.
  # Created by ../bootstrap. See README "Pointing at a different organisation".
  backend "s3" {
    bucket = "delta-sk-tfstate-751569314116"
    key    = "github-app-governance/terraform.tfstate"
    region = "eu-central-1"

    # S3-native locking: a conditional write of <key>.tflock next to the
    # state. Replaces the DynamoDB lock table, which Terraform has deprecated.
    use_lockfile = true
    encrypt      = true
  }
}

provider "github" {
  owner = local.github_org
  # Token is read from GITHUB_TOKEN. Must be a classic PAT with repo +
  # admin:org — see README "Why a classic PAT".
}
