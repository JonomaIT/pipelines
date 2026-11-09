# Every field a static site may declare (Contrato da app, runtime cloudfront).

# ------------------------------------------------------- from the pipeline
variable "prefix" {
  type        = string
  description = "Platform prefix (PROJECT_PREFIX org variable, from the pipeline): names <prefix>-<env>-..., parameters /<prefix>/<env>/..., tags <prefix>:*"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,14}$", var.prefix))
    error_message = "prefix must be 2-15 lowercase letters and digits."
  }
}

variable "platform_region" {
  type        = string
  description = "Primary region of the platform (PRIMARY_REGION org variable, from the pipeline): where its parameters are read"
}

variable "app_dir" {
  type        = string
  description = "The app repo's root, where the api's source_dir is (from the pipeline)"
  default     = "."
}

variable "environment" {
  type        = string
  description = "Account being deployed (from the GitHub Environment)"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

# ----------------------------------------------------------- deploy/app.hcl
# tflint-ignore: terraform_unused_declarations # part of the app contract
variable "runtime" {
  type        = string
  description = "Runner selector; this one is cloudfront"

  validation {
    condition     = var.runtime == "cloudfront"
    error_message = "This is the cloudfront runner: runtime must be cloudfront."
  }
}

variable "name" {
  type        = string
  description = "App name = repo name (ADR-005)"
}

# tflint-ignore: terraform_unused_declarations # part of the app contract (used by the upload)
variable "source_dir" {
  type        = string
  description = "Folder with the built site, uploaded to the bucket"
  default     = "site"
}

variable "spa" {
  type        = bool
  description = "Single-page app: unknown paths return index.html"
  default     = false
}

# --------------------------------------------- deploy/env/<account>.tfvars
variable "hosts" {
  type        = list(string)
  description = "Public names of the site: a label (vendas → vendas.<platform zone>), or the apex or <label> of a zone the platform allows (site-zones)"
}

variable "api" {
  type = object({
    source_dir = string # folder of the function's code in the repo, e.g. api
    handler    = string # <file>.<function>, e.g. index.handler
    runtime    = optional(string, "nodejs22.x")
    memory     = optional(number, 128)
    timeout    = optional(number, 10)
  })
  description = "The site's API at /api/* (a Lambda function; its secrets in SSM under /<prefix>/<env>/<app>/secrets); null = none"
  default     = null
}
