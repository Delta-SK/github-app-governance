output "state_bucket" {
  description = "Value for the backend \"s3\" bucket argument."
  value       = aws_s3_bucket.state.id
}

output "plan_role_arn" {
  description = "Read-only state access for plans and the reconciler. Published as AWS_PLAN_ROLE_ARN by github.tf."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Read-write state access for applies from main. Published as AWS_APPLY_ROLE_ARN by github.tf."
  value       = aws_iam_role.apply.arn
}

output "audit_role_arn" {
  description = "Read-only role the reconciler uses to plan bootstrap/. Published as AWS_AUDIT_ROLE_ARN by github.tf."
  value       = aws_iam_role.audit.arn
}
