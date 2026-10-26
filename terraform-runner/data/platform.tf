# What the platform decides (ADR-014), read from its parameters (infrastructure/global/dns-cloudflare)
# and from the limits policy of this repo, never from deploy/data.hcl: an app cannot turn its data
# protections off, use a region the platform does not run, or grow past the limits.

data "aws_ssm_parameters_by_path" "platform" {
  region = var.regions[0]
  path   = "/jonomait/${var.environment}/platform"
}

locals {
  platform         = { for i, n in data.aws_ssm_parameters_by_path.platform.names : basename(n) => nonsensitive(data.aws_ssm_parameters_by_path.platform.values[i]) }
  platform_regions = compact(split(",", lookup(local.platform, "regions", "")))

  # Labs only: data without deletion protection, so a teardown can remove it.
  allow_destroy = lookup(local.platform, "allow-destroy", "false") == "true"

  policy    = jsondecode(file("${path.module}/../../policies/limits.json"))
  exception = try(local.policy.exceptions[var.name], null)
  limits    = merge(local.policy.defaults[var.environment], try(local.exception[var.environment], {}))
}

resource "terraform_data" "platform" {
  input = var.name

  lifecycle {
    precondition {
      condition     = length(local.platform_regions) > 0
      error_message = "The platform parameters (/jonomait/${var.environment}/platform/*) are missing in ${var.regions[0]}: apply infrastructure global/dns-cloudflare first."
    }

    precondition {
      condition     = length(setsubtract(var.regions, local.platform_regions)) == 0
      error_message = "regions ${jsonencode(var.regions)} include a region the platform does not run in ${var.environment} (it runs ${jsonencode(local.platform_regions)})."
    }

    precondition {
      condition = alltrue([
        for n in [length(var.tables), length(var.topics), length(var.queues), length(var.buckets)] : n <= local.limits.data_resources_per_kind
      ])
      error_message = "deploy/data.hcl declares more than ${local.limits.data_resources_per_kind} resources of one kind: split the app, or ask the platform team for an exception in pipelines/policies/limits.json (ADR-014)."
    }

    precondition {
      condition     = local.exception == null || timecmp(plantimestamp(), "${try(local.exception.review_by, "1970-01-01")}T00:00:00Z") < 0
      error_message = "The exception of ${var.name} in pipelines/policies/limits.json is past its review date: the platform team renews or removes it."
    }
  }
}
