# Generic root for every ECS app: the app only brings values (deploy/app.hcl + env tfvars), the
# pipeline adds environment, region and image, and this calls the ecs-service pattern.
#
#   terraform init -backend-config=<account backend> -backend-config=key=<env>/<region>/apps/<name>
#   terraform apply -var-file=app.hcl -var-file=<env>.tfvars \
#     -var environment=<env> -var region=<region> -var image=<image>

check "region_is_listed" {
  assert {
    condition     = contains(var.regions, var.region)
    error_message = "region ${var.region} is not in the app's regions ${jsonencode(var.regions)}."
  }
}

check "production_has_slo" {
  assert {
    condition     = var.environment != "production" || var.slo != null
    error_message = "production apps must declare slo in deploy/app.hcl."
  }
}

# Secrets are referenced by name; a missing one fails the plan with a clear error.
data "aws_secretsmanager_secret" "app" {
  for_each = toset(var.secrets)
  name     = "jonomait/${var.environment}/${var.name}/${each.value}"
}

module "app" {
  source = "git::https://github.com/JonomaIT/terraform-modules.git//ecs-service?ref=v0.7.0"

  name        = var.name
  environment = var.environment
  image       = var.image
  port        = var.port
  hosts       = var.hosts

  cpu               = var.cpu
  memory            = var.memory
  min_capacity      = var.min_capacity
  max_capacity      = var.max_capacity
  cpu_target        = var.cpu_target
  health_check_path = var.health_check_path

  environment_variables = var.env
  secrets               = { for s, d in data.aws_secretsmanager_secret.app : upper(replace(s, "-", "_")) => d.arn }

  # Cheaper interruptible capacity outside production.
  capacity_provider = var.environment == "production" ? "FARGATE" : "FARGATE_SPOT"
}

# The app's public names (ADR-010): proxied CNAMEs to the environment's entry, created and removed
# with the app. DNS is global, so only the run of the primary region (the first in regions) owns
# them; the other regions only add the host rule on their own ALB.
locals {
  env_short = { staging = "stg", production = "prd" }[var.environment]
  ingress   = var.environment == "production" ? "ingress.${var.zone}" : "ingress-${local.env_short}.${var.zone}"
  dns_owner = var.region == var.regions[0] && length(var.hosts) > 0
}

module "dns" {
  source = "git::https://github.com/JonomaIT/terraform-modules.git//app-dns?ref=v0.7.0"
  count  = local.dns_owner ? 1 : 0

  zone   = var.zone
  hosts  = var.hosts
  target = local.ingress
  owner  = var.name
}
