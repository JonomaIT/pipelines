output "bucket" {
  description = "Bucket the site files are uploaded to"
  value       = one(module.site[*].bucket)
}

output "distribution_id" {
  description = "Distribution whose cache is invalidated after an upload"
  value       = one(module.site[*].distribution_id)
}

output "public_hosts" {
  description = "Public names of the site"
  value       = one(module.dns[*].names)
}
