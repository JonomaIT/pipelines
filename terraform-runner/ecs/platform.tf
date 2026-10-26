# What the platform decides (ADR-014), read from its parameters in this region
# (infrastructure global/dns-cloudflare) and from the limits policy of this repo, never from the
# app's files: an app cannot change the zone of its names, use a region the platform does not run,
# or grow past the limits of its environment.

data "aws_ssm_parameters_by_path" "platform" {
  path = "/jonomait/${var.environment}/platform"
}

locals {
  platform         = { for i, n in data.aws_ssm_parameters_by_path.platform.names : basename(n) => nonsensitive(data.aws_ssm_parameters_by_path.platform.values[i]) }
  platform_regions = compact(split(",", lookup(local.platform, "regions", "")))
  zone             = lookup(local.platform, "zone", "")

  policy    = jsondecode(file("${path.module}/../../policies/limits.json"))
  exception = try(local.policy.exceptions[var.name], null)
  limits    = merge(local.policy.defaults[var.environment], try(local.exception[var.environment], {}))
  ask       = "use less, or ask the platform team for an exception in pipelines/policies/limits.json (ADR-014)"
}

resource "terraform_data" "platform" {
  input = var.name

  lifecycle {
    precondition {
      condition     = local.zone != "" && length(local.platform_regions) > 0
      error_message = "The platform parameters (/jonomait/${var.environment}/platform/*) are missing in ${var.region}: apply infrastructure global/dns-cloudflare first."
    }

    precondition {
      condition     = length(setsubtract(var.regions, local.platform_regions)) == 0
      error_message = "regions ${jsonencode(var.regions)} include a region the platform does not run in ${var.environment} (it runs ${jsonencode(local.platform_regions)})."
    }

    precondition {
      condition     = var.cpu <= local.limits.cpu
      error_message = "cpu ${var.cpu} is above the ${var.environment} limit of ${local.limits.cpu} per task: ${local.ask}."
    }

    precondition {
      condition     = var.memory <= local.limits.memory
      error_message = "memory ${var.memory} is above the ${var.environment} limit of ${local.limits.memory} MiB per task: ${local.ask}."
    }

    precondition {
      condition     = var.max_capacity <= local.limits.max_capacity
      error_message = "max_capacity ${var.max_capacity} is above the ${var.environment} limit of ${local.limits.max_capacity} tasks: ${local.ask}."
    }

    precondition {
      condition     = local.exception == null || timecmp(plantimestamp(), "${try(local.exception.review_by, "1970-01-01")}T00:00:00Z") < 0
      error_message = "The exception of ${var.name} in pipelines/policies/limits.json is past its review date: the platform team renews or removes it."
    }
  }
}
