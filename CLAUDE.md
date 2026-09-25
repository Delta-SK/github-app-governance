# GitHub App Governance — DevOps Homework

## Objective

Build a working GitOps-managed system for governing GitHub App
installation repository access across a GitHub organization.

This is a DevOps Engineer II take-home assignment.

## Acceptance criteria

The implementation must demonstrate:

1. Terraform manages GitHub App installation repository access.
2. Use the official Terraform GitHub provider.
3. Repository configuration relevant to the solution is managed as code.
4. GitHub Actions runs:
   - terraform fmt/validate/plan on pull requests
   - terraform apply after merge to main
5. At least two GitHub Apps are represented.
6. At least two repositories are represented.
7. App access can be added, removed, or narrowed through a PR.
8. README documents:
   - architecture
   - prerequisites
   - authentication
   - setup
   - how to inspect the state
   - how changes flow through GitOps
   - limitations
9. Governance documentation covers:
   - ownership
   - purpose
   - review/expiry
   - detecting forgotten/unowned Apps
   - safe decommissioning

## Constraints

This is an 8-hour homework assignment.

Prefer a small, working implementation over an over-engineered
production platform.

The implementation must actually work against a throwaway/test
GitHub organization.

Do not solve everything only with documentation.

## Engineering principles

- Infrastructure as Code first.
- Avoid manual GitHub UI configuration where Terraform can manage it.
- Prefer reusable Terraform structures such as for_each.
- Keep secrets out of Git.
- Use least privilege.
- Make the GitOps workflow explicit.
- Keep the implementation easy to demonstrate in a 30-minute
  show-and-tell.
- Clearly document anything intentionally omitted.

## Important provider considerations

Before implementing a Terraform resource, verify that the current
GitHub Terraform provider supports the required operation.

Do not invent Terraform resources or arguments.

Pay particular attention to:
- GitHub App installation IDs
- selected repository access
- provider authentication
- repository settings
- branch protection
- limitations of managing GitHub App installations themselves

## Workflow

Before making significant changes:

1. Inspect the existing repository.
2. Explain the proposed approach.
3. Implement incrementally.
4. Run terraform fmt.
5. Run terraform validate.
6. Run terraform plan where credentials/configuration permit.
7. Inspect git diff.
8. Fix errors rather than hiding them.
9. Keep README synchronized with the implementation.

## Security

Never print or commit:
- GitHub tokens
- API keys
- private keys
- secrets
- credentials

Never push changes automatically unless explicitly requested.

## Interview awareness

The final implementation should make it easy to explain:

- why the architecture was chosen
- Terraform/provider limitations
- authentication choices
- GitOps flow
- governance at 500+ Apps
- ownership and expiry
- detection of orphaned Apps
- safe decommissioning
- security improvements for enterprise scale
