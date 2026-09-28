terraform {
  # Exact version: /.terraform-version (read by CI and version managers).
  required_version = "~> 1.16.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # Literals: Terraform allows no variables here. Created by ../bootstrap.
  backend "s3" {
    bucket = "delta-sk-tfstate-751569314116"
    key    = "github-app-governance/terraform.tfstate"
    region = "eu-central-1"

    # S3-native lock object; plans never lock.
    use_lockfile = true
    encrypt      = true
  }
}

provider "github" {
  owner = local.github_org
  # GITHUB_TOKEN: classic PAT for apply, read-only token for code plans
  # (docs/decisions/0001, 0002).
}
