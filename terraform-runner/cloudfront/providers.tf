# CloudFront is global but only uses ACM certificates (and is managed) from us-east-1.
provider "aws" {
  region = "us-east-1"

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
