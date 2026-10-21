# Generic root for every static site (runtime = "cloudfront"): the app only brings values
# (deploy/app.hcl + env tfvars), the pipeline adds the environment, and this creates the
# distribution (cloudfront-site) and the site's public names pointing at it (app-dns, ADR-010).
# CloudFront is global: one run per account, state key <env>/global/apps/<name>.
#
#   terraform init -backend-config=<account backend> -backend-config=key=<env>/global/apps/<name>
#   terraform apply -var-file=app.hcl -var-file=<env>.tfvars -var environment=<env>
#
# The files are uploaded afterwards (aws s3 sync to the output bucket + invalidation).

module "site" {
  source = "git::https://github.com/JonomaIT/terraform-modules.git//cloudfront-site?ref=v0.9.0"

  name          = var.name
  environment   = var.environment
  zone          = var.zone
  hosts         = var.hosts
  spa           = var.spa
  force_destroy = var.environment != "production"
}

module "dns" {
  source = "git::https://github.com/JonomaIT/terraform-modules.git//app-dns?ref=v0.9.0"

  zone   = var.zone
  hosts  = var.hosts
  target = module.site.domain_name
  owner  = var.name
}
