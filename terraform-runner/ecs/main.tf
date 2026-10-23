# Generic root for every ECS app: the app only brings values (deploy/app.hcl + env tfvars), the
# pipeline adds environment, region and image, and this calls the ecs-service pattern.
#
#   terraform init -backend-config=<account backend> -backend-config=key=<env>/<region>/apps/<name>
#   terraform apply -var-file=app.hcl -var-file=<env>.tfvars \
#     -var environment=<env> -var region=<region> -var image=<image>
#
# The contract rules (region listed, production with slo and two tasks) are variable validations:
# they stop the plan. A check block would only warn and let the deploy through.

# Secrets are referenced by name; a missing one fails the plan with a clear error.
data "aws_secretsmanager_secret" "app" {
  for_each = toset(var.secrets)
  name     = "jonomait/${var.environment}/${var.name}/${each.value}"
}

# The app's data (ADR-011), published in this region by the data runner: environment variables
# (/jonomait/<env>/<name>/env/<VAR>) and the data-access policy (/jonomait/<env>/<name>/iam/*).
# An app without deploy/data.hcl has none, and gets none. Plain String parameters (names, URLs,
# ARNs), never secrets: those come from secrets.
data "aws_ssm_parameters_by_path" "data_env" {
  path = "/jonomait/${var.environment}/${var.name}/env"
}

data "aws_ssm_parameters_by_path" "data_iam" {
  path = "/jonomait/${var.environment}/${var.name}/iam"
}

locals {
  # Images from the platform registry are replicated to every region: each region pulls from its
  # own copy (DR: a region never depends on another to start its tasks).
  image = replace(var.image, ".dkr.ecr.us-east-1.amazonaws.com/", ".dkr.ecr.${var.region}.amazonaws.com/")

  data_env = {
    for i, n in data.aws_ssm_parameters_by_path.data_env.names : basename(n) => nonsensitive(data.aws_ssm_parameters_by_path.data_env.values[i])
  }
  data_policies = nonsensitive(data.aws_ssm_parameters_by_path.data_iam.values)

  # What the platform tells every app: where to read the state of its region (ADR-012).
  platform_env = {
    REGION_STATE_PARAMETER = "/jonomait/${var.environment}/platform/region-state"
  }
}

# The app's env may not shadow a variable the platform or the data runner sets.
resource "terraform_data" "env_contract" {
  input = var.name

  lifecycle {
    precondition {
      condition     = length(setintersection(keys(var.env), concat(keys(local.data_env), keys(local.platform_env)))) == 0
      error_message = "deploy/app.hcl env sets ${join(", ", setintersection(keys(var.env), concat(keys(local.data_env), keys(local.platform_env))))}, which the platform injects (data.hcl or platform): remove it from env."
    }
  }
}

module "app" {
  source = "git::https://github.com/JonomaIT/terraform-modules.git//ecs-service?ref=v0.9.0"

  name        = var.name
  environment = var.environment
  image       = local.image
  port        = var.port
  hosts       = var.hosts

  cpu               = var.cpu
  memory            = var.memory
  min_capacity      = var.min_capacity
  max_capacity      = var.max_capacity
  cpu_target        = var.cpu_target
  health_check_path = var.health_check_path

  environment_variables = merge(var.env, local.data_env, local.platform_env)
  secrets               = { for s, d in data.aws_secretsmanager_secret.app : upper(replace(s, "-", "_")) => d.arn }
  task_policy_arns      = local.data_policies

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
  source = "git::https://github.com/JonomaIT/terraform-modules.git//app-dns?ref=v0.9.0"
  count  = local.dns_owner ? 1 : 0

  zone   = var.zone
  hosts  = var.hosts
  target = local.ingress
  owner  = var.name
}
