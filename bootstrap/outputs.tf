output "state_bucket" {
  description = "Value for the backend \"s3\" bucket argument."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "Value for the backend \"s3\" dynamodb_table argument."
  value       = aws_dynamodb_table.lock.name
}

output "ci_role_arn" {
  description = "Set as the AWS_ROLE_ARN repository variable in GitHub Actions."
  value       = aws_iam_role.ci.arn
}
