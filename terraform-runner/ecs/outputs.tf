output "service_name" {
  description = "ECS service"
  value       = module.app.service_name
}

output "internal_url" {
  description = "Service-to-service address"
  value       = module.app.internal_url
}

output "public_hosts" {
  description = "Public names"
  value       = module.app.public_hosts
}

output "log_group" {
  description = "CloudWatch Logs group"
  value       = module.app.log_group
}
