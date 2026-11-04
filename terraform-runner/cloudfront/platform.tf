# What the platform decides (ADR-014), read from its parameters (infrastructure global/platform),
# never from the site's files:
#   - the zone of its public names, and the other zones a site may have names in (site-zones: a
#     customer's own domain, which gets the site's own certificate);
#   - the region of the copy of the site (origin failover): the platform's first region other
#     than CloudFront's own (us-east-1, an AWS rule, not a choice), when it runs more than one.
#
# Read in the platform's primary region, wherever that is: CloudFront itself is managed from
# us-east-1, the platform may not run there.

data "aws_ssm_parameters_by_path" "platform" {
  region = var.platform_region
  path   = "/${var.prefix}/${var.environment}/platform"
}

locals {
  platform = { for i, n in data.aws_ssm_parameters_by_path.platform.names : basename(n) => nonsensitive(data.aws_ssm_parameters_by_path.platform.values[i]) }
  zone     = lookup(local.platform, "zone", "")

  site_zones = compact(split(",", lookup(local.platform, "site-zones", "")))

  # Public names: a label is a name under the platform's zone (vendas → vendas.<zone>), so a site
  # never writes the domain; a full name stays as it is (a customer's domain, site-zones).
  hosts = [for h in var.hosts : strcontains(h, ".") ? h : "${h}.${local.zone}"]

  failover_region = try([for r in split(",", lookup(local.platform, "regions", "")) : r if r != "" && r != "us-east-1"][0], null)
}

resource "terraform_data" "platform" {
  input = var.name

  lifecycle {
    precondition {
      condition     = local.zone != ""
      error_message = "The platform parameters (/${var.prefix}/${var.environment}/platform/*) are missing in ${var.platform_region}: apply infrastructure global/platform first."
    }
  }
}
