# Generic root for every static site (runtime = "cloudfront"): the app only brings values
# (deploy/app.hcl + env tfvars), the pipeline adds the environment, and this creates the
# distribution (cloudfront-site) and the site's public names pointing at it (app-dns, ADR-010).
# A site may have an API at /api/* (api.tf).
# CloudFront is global: one run per account, state key <env>/global/apps/<name>.
#
#   terraform init -backend-config=<account backend> -backend-config=key=<env>/global/apps/<name>
#   terraform apply -var-file=app.hcl -var-file=<env>.tfvars -var app_dir=<app repo> \
#     -var prefix=<prefix> -var platform_region=<primary region> -var environment=<env>
#
# The files are uploaded afterwards (aws s3 sync to the output buckets + invalidation). With two
# platform regions the site has a copy in the other one, read by CloudFront when the primary
# bucket fails (origin failover).

# Nothing is built without the platform's parameters: the plan stops at terraform_data.platform
# with what to do, instead of the modules failing on an empty zone.
locals {
  platform_ready = local.zone != ""
}

module "site" {
  source = "git::https://github.com/JonomaIT/terraform-modules.git//cloudfront-site?ref=v0.16.0"
  count  = local.platform_ready ? 1 : 0

  prefix          = var.prefix
  name            = var.name
  environment     = var.environment
  zone            = local.zone
  extra_zones     = local.site_zones
  zone_owners     = local.zone_owners
  hosts           = local.hosts
  spa             = var.spa
  failover_region = local.failover_region
  force_destroy   = var.environment != "production"
  api             = local.api ? { domain = module.api[0].url_domain, function_name = module.api[0].function_name } : null

  # Every edge location: users in South America are served from there, not from the US. No fixed
  # cost, only a slightly higher price per GB (the module's default, PriceClass_100, has none in
  # South America).
  price_class = "PriceClass_All"
}

module "dns" {
  source = "git::https://github.com/JonomaIT/terraform-modules.git//app-dns?ref=v0.16.0"
  count  = local.platform_ready ? 1 : 0

  zone        = local.zone
  extra_zones = local.site_zones
  zone_owners = local.zone_owners
  hosts       = local.hosts
  target      = module.site[0].domain_name
  owner       = var.name
}

# Before v2.2.0 the modules had no count.
moved {
  from = module.site
  to   = module.site[0]
}

moved {
  from = module.dns
  to   = module.dns[0]
}
