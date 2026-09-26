#!/usr/bin/env bash
# Replace this checkout's catalogue data with a pull request's — and nothing
# else. Used by terraform-plan.yml, which runs main's code with the
# organisation-admin credential and therefore must never run pull request
# code.
#
# Usage (from the repository root, GH_TOKEN set):
#   scripts/take-pr-catalogue.sh <owner/repo> <pr-number> <head-sha>
#
# What it takes: the files Terraform loads automatically from terraform/ —
# terraform.tfvars, *.auto.tfvars and their .json forms — exactly as they are
# at <head-sha>. Variable definition files are pure data: HCL forbids function
# calls and references in them, so they cannot execute anything. Policy knobs
# are locals in terraform/settings.tf, not variables, so these files cannot
# change the rules either.
#
# Why the contents API rather than `git checkout`: it is pinned to the exact
# commit (no race with a later push), it reports symlinks as symlinks (a
# symlink named x.auto.tfvars pointing at /proc/self/environ must not be
# followed), and it needs no git credentials persisted on disk.
#
# Writes code_changes.txt: every changed file in the pull request that is not
# catalogue data or documentation. Non-empty means the plan, which uses main's
# code, does not show what this pull request's code would do.

set -euo pipefail

repo=${1:?usage: take-pr-catalogue.sh <owner/repo> <pr-number> <head-sha>}
pr=${2:?usage: take-pr-catalogue.sh <owner/repo> <pr-number> <head-sha>}
sha=${3:?usage: take-pr-catalogue.sh <owner/repo> <pr-number> <head-sha>}

auto_loaded='^(terraform\.tfvars(\.json)?|[A-Za-z0-9._-]+\.auto\.tfvars(\.json)?)$'

# Start from main's data removed, so a file the pull request deletes is
# deleted here too.
find terraform -maxdepth 1 -type f -regextype posix-extended \
  -regex "terraform/(terraform\.tfvars(\.json)?|.*\.auto\.tfvars(\.json)?)" -delete

gh api "repos/$repo/contents/terraform?ref=$sha" \
  --jq '.[] | [.type, .name] | @tsv' |
  while IFS=$'\t' read -r type name; do
    [[ $name =~ $auto_loaded ]] || continue
    if [ "$type" != file ]; then
      echo "::error title=catalogue data::terraform/$name is a $type, not a regular file. Refusing to plan it." >&2
      exit 1
    fi
    gh api -H "Accept: application/vnd.github.raw" \
      "repos/$repo/contents/terraform/$name?ref=$sha" >"terraform/$name"
    echo "taken from the pull request: terraform/$name"
  done

gh api --paginate "repos/$repo/pulls/$pr/files" --jq '.[].filename' |
  grep -Ev '^terraform/(terraform\.tfvars(\.json)?|[^/]+\.auto\.tfvars(\.json)?)$|\.md$|^\.github/ISSUE_TEMPLATE/' \
    >code_changes.txt || true

if [ -s code_changes.txt ]; then
  echo "pull request also changes code:"
  sed 's/^/  /' code_changes.txt
fi
