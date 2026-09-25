terraform {
  required_version = "~> 1.9.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # Backend values are literals by design — Terraform forbids variables here.
  # Created by ../bootstrap. Override with -backend-config to target another
  # account; see README "Pointing at a different org".
  backend "s3" {
    bucket = "delta-sk-tfstate-751569314116"
    key    = "github-app-governance/terraform.tfstate"
    region = "eu-central-1"

    # Terraform 1.9 predates S3 native locking (use_lockfile, added in 1.10),
    # so a DynamoDB table carries the lock.
    dynamodb_table = "delta-sk-tfstate-lock"
    encrypt        = true
  }
}

provider "github" {
  owner = var.github_org
  # Token is read from GITHUB_TOKEN. Must be a classic PAT with repo +
  # admin:org — see README "Why a classic PAT".
}
