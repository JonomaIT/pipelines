terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0" # per-resource region
    }
  }

  # Bucket of the account being deployed; key <env>/cross-region/data/<name>, both passed at init.
  backend "s3" {
    use_lockfile = true
  }
}
