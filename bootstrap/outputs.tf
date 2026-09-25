output "state_bucket" {
  description = "Value for the backend \"s3\" bucket argument."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "Value for the backend \"s3\" dynamodb_table argument."
  value       = aws_dynamodb_table.lock.name
}

output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository variable. Read-only state access for untrusted PR code."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the AWS_APPLY_ROLE_ARN repository variable. Read-write state access for applies from main."
  value       = aws_iam_role.apply.arn
}
