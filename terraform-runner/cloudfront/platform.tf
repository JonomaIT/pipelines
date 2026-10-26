# What the platform decides (ADR-014), read from its parameters (infrastructure
# global/dns-cloudflare), never from the site's files: the zone of its public names.

data "aws_ssm_parameters_by_path" "platform" {
  path = "/jonomait/${var.environment}/platform"
}

locals {
  platform = { for i, n in data.aws_ssm_parameters_by_path.platform.names : basename(n) => nonsensitive(data.aws_ssm_parameters_by_path.platform.values[i]) }
  zone     = lookup(local.platform, "zone", "")
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
