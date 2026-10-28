# What the platform decides (ADR-014), read from its parameters (infrastructure
# global/dns-cloudflare), never from the site's files: the zone of its public names, and the
# region of the copy of the site (origin failover): the platform's first region other than
# CloudFront's own (us-east-1), when it runs more than one.

data "aws_ssm_parameters_by_path" "platform" {
  path = "/jonomait/${var.environment}/platform"
}

locals {
  platform = { for i, n in data.aws_ssm_parameters_by_path.platform.names : basename(n) => nonsensitive(data.aws_ssm_parameters_by_path.platform.values[i]) }
  zone     = lookup(local.platform, "zone", "")

  failover_region = try([for r in split(",", lookup(local.platform, "regions", "")) : r if r != "" && r != "us-east-1"][0], null)
}

resource "terraform_data" "platform" {
  input = var.name

  lifecycle {
    precondition {
      condition     = local.zone != ""
      error_message = "The platform parameters (/jonomait/${var.environment}/platform/*) are missing in us-east-1: apply infrastructure global/dns-cloudflare first."
    }
  }
}
