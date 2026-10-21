output "environment_variables" {
  description = "What the app receives in each region (variable => region => value)"
  value       = local.env
}

output "permissions" {
  description = "The data-access policy, statement by statement: what the app may do, and on what"
  value       = local.statements
}

output "data_access_policy" {
  description = "Data-access policy attached to the app's task role (null when the app has no data)"
  value       = one(aws_iam_policy.data_access[*].arn)
}
