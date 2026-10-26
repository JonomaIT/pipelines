# Every field a static site may declare (Contrato da app, runtime cloudfront).

# ------------------------------------------------------- from the pipeline
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
  description = "Public names of the site (<label>.<zone>)"
}
