terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # Bucket of the account being deployed; key <env>/<region>/apps/<name>, both passed at init.
  backend "s3" {
    use_lockfile = true
  }
}
