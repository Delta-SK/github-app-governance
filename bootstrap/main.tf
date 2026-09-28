terraform {
  # Exact version pinned in /.terraform-version; see ../terraform/versions.tf.
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # On a fresh account: comment out for the first apply, then restore and
  # `terraform init -migrate-state` (README, Setup step 1).
  backend "s3" {
    bucket       = "delta-sk-tfstate-751569314116"
    key          = "github-app-governance/bootstrap.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
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

# Refuse plaintext requests.
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

# ---------------------------------------------------------------------------
# GitHub Actions OIDC federation — no long-lived AWS keys in GitHub secrets
# ---------------------------------------------------------------------------

# No thumbprint_list: AWS ignores it for GitHub, and a pinned one goes stale.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # GitHub's subject claim embeds immutable IDs; see variables.tf.
  subject_prefix = "repo:${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}"
}

# Plans read state without locking; only apply, from main, writes it.

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

    # A job's `environment:` replaces the ref in the subject claim, so which
    # refs may assume the role is decided by the environments' policies.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.subject_prefix}:environment:plan",
        "${local.subject_prefix}:environment:plan-code",
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

    # Nothing that runs on a pull request may reach write access to state.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.subject_prefix}:environment:production"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "github-app-governance-plan"
  description        = "Read-only state access for plans and the reconciler."
  assume_role_policy = data.aws_iam_policy_document.assume_plan.json
}

resource "aws_iam_role" "apply" {
  name               = "github-app-governance-apply"
  description        = "Read-write state access for applies from main."
  assume_role_policy = data.aws_iam_policy_document.assume_apply.json
}

# Scoped to the main state key: bootstrap.tfstate stays out of CI's reach.
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

  # No s3:DeleteObject on state: versioning makes a bad write recoverable.
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [local.main_state_arn]
  }

  # The S3-native lock object: created and deleted by apply.
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.main_state_arn}.tflock"]
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

# ---------------------------------------------------------------------------
# Audit role: read-only plan of this configuration by the weekly reconciler
# (docs/decisions/0006). Actions are those a bootstrap plan was observed to
# call in CloudTrail.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_audit" {
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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.subject_prefix}:environment:production"]
    }
  }
}

resource "aws_iam_role" "audit" {
  name               = "github-app-governance-audit"
  description        = "Read-only plan of bootstrap/ for drift detection, from main."
  assume_role_policy = data.aws_iam_policy_document.assume_audit.json
}

data "aws_iam_policy_document" "audit_read" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/github-app-governance/bootstrap.tfstate"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListTagsForResource",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketLogging",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketVersioning",
      "s3:GetBucketWebsite",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
    ]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
    ]
    resources = [aws_iam_role.plan.arn, aws_iam_role.apply.arn, aws_iam_role.audit.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = [aws_iam_openid_connect_provider.github.arn]
  }
}

resource "aws_iam_role_policy" "audit_read" {
  name   = "bootstrap-plan-read"
  role   = aws_iam_role.audit.id
  policy = data.aws_iam_policy_document.audit_read.json
}
