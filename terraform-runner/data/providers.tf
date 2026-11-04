# One provider, in the primary region: every resource that lives elsewhere says its own region
# (AWS provider v6), so the whole multi-region resource sits in one state.
provider "aws" {
  region = var.regions[0]

  default_tags {
    tags = {
      "${var.prefix}:env"        = var.environment
      "${var.prefix}:app"        = var.name
      "${var.prefix}:repo"       = var.name
      "${var.prefix}:component"  = "data/${var.name}"
      "${var.prefix}:managed-by" = "terraform"
    }
  }
}
