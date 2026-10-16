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

output "dns_names" {
  description = "Public names created by this run (only the primary region's run creates them)"
  value       = one(module.dns[*].names)
}
