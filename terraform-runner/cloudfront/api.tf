# The site's API (deploy/app.hcl: api = { ... }): a Lambda function at /api/* of the site's own names
# (same host: no CORS). The function gets, as environment variables:
#   - the app's data (deploy/data.hcl, built by the data runner: TABLE_<NAME>, ...), and its
#     data-access policy, exactly as the ECS runner does;
#   - SECRETS_PATH, the SSM path of the app's secrets (/<prefix>/<env>/<app>/secrets), which it may
#     read at run time. Secrets are set outside Terraform (never in the state, the repo or the
#     function's environment); who may call what, the function decides (e.g. a sign-in it checks).

locals {
  api          = var.api != null && local.platform_ready
  secrets_path = "/${var.prefix}/${var.environment}/${var.name}/secrets"
}

data "aws_ssm_parameters_by_path" "data_env" {
  count  = var.api != null ? 1 : 0
  region = var.platform_region
  path   = "/${var.prefix}/${var.environment}/${var.name}/env"
}

data "aws_ssm_parameters_by_path" "data_iam" {
  count  = var.api != null ? 1 : 0
  region = var.platform_region
  path   = "/${var.prefix}/${var.environment}/${var.name}/iam"
}

locals {
  data_env = var.api == null ? {} : {
    for i, n in data.aws_ssm_parameters_by_path.data_env[0].names : basename(n) => nonsensitive(data.aws_ssm_parameters_by_path.data_env[0].values[i])
  }
  data_policies = var.api == null ? [] : nonsensitive(data.aws_ssm_parameters_by_path.data_iam[0].values)
}

module "api" {
  source = "git::https://github.com/JonomaIT/terraform-modules.git//lambda-function?ref=v0.15.0"
  count  = local.api ? 1 : 0

  prefix          = var.prefix
  environment     = var.environment
  name            = var.name
  source_dir      = "${var.app_dir}/${var.api.source_dir}"
  handler         = var.api.handler
  runtime         = var.api.runtime
  memory          = var.api.memory
  timeout         = var.api.timeout
  policy_arns     = local.data_policies
  parameter_paths = [local.secrets_path]

  environment_variables = merge(local.data_env, { SECRETS_PATH = local.secrets_path })
}
