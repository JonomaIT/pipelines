# One provider, in the primary region: every resource that lives elsewhere says its own region
# (AWS provider v6), so the whole multi-region resource sits in one state.
provider "aws" {
  region = var.regions[0]

  default_tags {
    tags = {
      "jonomait:env"        = var.environment
      "jonomait:app"        = var.name
      "jonomait:repo"       = var.name
      "jonomait:component"  = "data/${var.name}"
      "jonomait:managed-by" = "terraform"
    }
  }
}
