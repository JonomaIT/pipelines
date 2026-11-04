provider "aws" {
  region = var.region

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
