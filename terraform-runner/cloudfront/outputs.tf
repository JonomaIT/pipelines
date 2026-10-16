output "bucket" {
  description = "Bucket the site files are uploaded to"
  value       = module.site.bucket
}

output "distribution_id" {
  description = "Distribution whose cache is invalidated after an upload"
  value       = module.site.distribution_id
}

output "public_hosts" {
  description = "Public names of the site"
  value       = module.dns.names
}
