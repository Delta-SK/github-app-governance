terraform {
  required_version = "~> 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # Bootstrap creates the backend that everything else uses, so the first
  # apply against a fresh account necessarily runs with local state. Once the
  # bucket exists, bootstrap's own state is migrated into it with
  # `terraform init -migrate-state`, which removes the unbacked-up local file.
  #
  # Against a brand new account, comment this block out for the first apply,
  # then restore it and migrate. See README "Bootstrap the backend".
  backend "s3" {
    bucket         = "delta-sk-tfstate-751569314116"
    key            = "github-app-governance/bootstrap.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "delta-sk-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# State storage
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket

  # Losing this bucket means losing the record of every governed app.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning and encryption do not stop a plaintext request. Refuse them.
data "aws_iam_policy_document" "state_bucket" {
  statement {
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC federation — no long-lived AWS keys in GitHub secrets
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  # GitHub issues the subject claim as
  #   repo:<org>@<org_id>/<repo>@<repo_id>:...
  # Trust policies written in the documented repo:<org>/<repo>:... form
  # silently fail to match. Pinning the numeric IDs also stops a deleted and
  # recreated org or repo of the same name from inheriting this trust.
  subject_prefix = "repo:${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}"
}

# Two roles, split by trust boundary.
#
# Pull request code is UNTRUSTED: for pull_request events GitHub runs the
# workflow definition from the PR head, so anyone who can push a branch can
# rewrite the plan job. That job must therefore never hold credentials capable
# of mutating state. Plan reads state and runs with -lock=false, so read-only
# S3 access is sufficient and no DynamoDB access is needed at all.
#
# Code on main is TRUSTED: it has been through review and merge.

data "aws_iam_policy_document" "assume_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Declaring `environment:` on a job REPLACES the :pull_request / :ref:...
    # portion of the subject claim with :environment:<name>. A trust policy
    # written against the ref-based claims stops matching the moment a job is
    # moved into an environment.
    #
    # This is an improvement, not just a quirk: the environment carries its own
    # deployment branch policy, so "which branches may assume this role" is
    # enforced by the environment rather than duplicated in IAM.
    #
    # plan       -> untrusted PR code, read-only state
    # production -> trusted main-only code; the reconciler runs here and also
    #               takes this read-only role, which costs nothing.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.subject_prefix}:environment:plan",
        "${local.subject_prefix}:environment:production",
      ]
    }
  }
}

data "aws_iam_policy_document" "assume_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the production environment, which is itself restricted to protected
    # branches. The plan environment is deliberately absent: untrusted pull
    # request code must never reach a credential that can mutate state.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.subject_prefix}:environment:production"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "github-app-governance-plan"
  description        = "Read-only state access for PR-triggered plans. Assumed by untrusted PR code."
  assume_role_policy = data.aws_iam_policy_document.assume_plan.json
}

resource "aws_iam_role" "apply" {
  name               = "github-app-governance-apply"
  description        = "Read-write state access for applies from main."
  assume_role_policy = data.aws_iam_policy_document.assume_apply.json
}

# CI only ever touches the main configuration's state. Scoping to that exact
# key keeps bootstrap.tfstate — which holds the OIDC roles, the branch
# protection and the reviewing team — out of reach of the pipeline those
# controls govern. Granting bucket/* would let a compromised apply rewrite the
# controls that are supposed to constrain it.
locals {
  main_state_arn = "${aws_s3_bucket.state.arn}/github-app-governance/terraform.tfstate"
}

data "aws_iam_policy_document" "state_read" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["github-app-governance/*"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.main_state_arn]
  }
}

data "aws_iam_policy_document" "state_write" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["github-app-governance/*"]
    }
  }

  # No s3:DeleteObject — Terraform never needs to delete its own state, and
  # versioning means a destructive write is recoverable while a delete is
  # one step closer to not being.
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [local.main_state_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.lock.arn]
  }
}

resource "aws_iam_role_policy" "plan_state_read" {
  name   = "terraform-state-read"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_read.json
}

resource "aws_iam_role_policy" "apply_state_write" {
  name   = "terraform-state-write"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.state_write.json
}
