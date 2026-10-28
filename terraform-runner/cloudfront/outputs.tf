output "bucket" {
  description = "Bucket the site files are uploaded to"
  value       = one(module.site[*].bucket)
}

output "failover_bucket" {
  description = "Copy of the site in the platform's other region: the files go here too (null with one region)"
  value       = one(module.site[*].failover_bucket)
}

output "distribution_id" {
  description = "Distribution whose cache is invalidated after an upload"
  value       = one(module.site[*].distribution_id)
}

output "public_hosts" {
  description = "Public names of the site"
  value       = one(module.dns[*].names)
}
