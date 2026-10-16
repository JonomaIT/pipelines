provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "jonomait:env"        = var.environment
      "jonomait:app"        = var.name
      "jonomait:repo"       = var.name
      "jonomait:component"  = "apps/${var.name}"
      "jonomait:managed-by" = "terraform"
    }
  }
}

# Token from CLOUDFLARE_API_TOKEN: in the app pipeline, a token that can only edit DNS records.
provider "cloudflare" {}
