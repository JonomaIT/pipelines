# CloudFront is global but only uses ACM certificates (and is managed) from us-east-1: an AWS rule,
# the same for every platform, so it is not a variable.
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      "${var.prefix}:env"        = var.environment
      "${var.prefix}:app"        = var.name
      "${var.prefix}:repo"       = var.name
      "${var.prefix}:component"  = "apps/${var.name}"
      "${var.prefix}:managed-by" = "terraform"
    }
  }
}

# Token from CLOUDFLARE_API_TOKEN: in the app pipeline, a token that can only edit DNS records.
provider "cloudflare" {}
