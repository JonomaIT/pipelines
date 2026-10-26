# Every field an app may declare (Contrato da app), even the ones this runner does not use yet:
# loading deploy/app.hcl and deploy/env/<account>.tfvars with -var-file fails on undeclared variables.

# ------------------------------------------------------- from the pipeline
variable "environment" {
  type        = string
  description = "Account being deployed (from the GitHub Environment)"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "region" {
  type        = string
  description = "Region of this run (the pipeline runs one job per region in var.regions)"

  validation {
    condition     = contains(var.regions, var.region)
    error_message = "region ${var.region} is not in the app's regions (deploy/env/<account>.tfvars): ${jsonencode(var.regions)}."
  }
}

variable "image" {
  type        = string
  description = "Image built once and promoted: <shared-services>.dkr.ecr.us-east-1.amazonaws.com/<name>:<sha>"
}

variable "zone" {
  type        = string
  description = "Cloudflare zone of the platform; the app's hosts live under it"
  default     = "joshuel.com.br"
}

# ----------------------------------------------------------- deploy/app.hcl
# tflint-ignore: terraform_unused_declarations # part of the app contract
variable "runtime" {
  type        = string
  description = "Runner selector; this one is ecs"

  validation {
    condition     = var.runtime == "ecs"
    error_message = "This is the ecs runner: runtime must be ecs."
  }
}

variable "name" {
  type        = string
  description = "App name = repo name (ADR-005)"
}

variable "port" {
  type        = number
  description = "Container port"
}

variable "health_check_path" {
  type        = string
  description = "Health endpoint, answers 200 without depending on a database or another service"
  default     = "/health"
}

variable "env" {
  type        = map(string)
  description = "Non-sensitive environment variables"
  default     = {}
}

variable "secrets" {
  type        = list(string)
  description = "Secret names in Secrets Manager (jonomait/<environment>/<name>/<secret>), injected as SECRET_NAME variables"
  default     = []
}

# tflint-ignore: terraform_unused_declarations # part of the app contract; only validated until the alerts exist
variable "slo" {
  # The contract v1 keys (disponibilidade, latencia_p95_ms) are still recognized, only to be refused
  # with the new names; they leave in v3.
  type = object({
    availability    = optional(number)
    latency_p95_ms  = optional(number)
    disponibilidade = optional(number)
    latencia_p95_ms = optional(number)
  })
  description = "Availability (%) and p95 latency (ms) objectives; required in production (alerts come later, see Observabilidade)"
  default     = null

  validation {
    condition     = var.slo == null || try(var.slo.disponibilidade == null && var.slo.latencia_p95_ms == null, true)
    error_message = "slo keys were renamed in contract v2: disponibilidade -> availability, latencia_p95_ms -> latency_p95_ms."
  }

  validation {
    condition     = var.slo == null || try(var.slo.availability != null && var.slo.latency_p95_ms != null, false)
    error_message = "slo needs availability and latency_p95_ms, e.g. slo = { availability = 99.5, latency_p95_ms = 500 }."
  }

  validation {
    condition     = var.environment != "production" || var.slo != null
    error_message = "production apps must declare slo in deploy/app.hcl, e.g. slo = { availability = 99.5, latency_p95_ms = 500 }."
  }
}

# tflint-ignore: terraform_unused_declarations # part of the app contract
variable "min_coverage" {
  type        = number
  description = "Minimum coverage (%) on the lines a pull request changes (used by pr-check, not here)"
  default     = 80
}

# tflint-ignore: terraform_unused_declarations # contract v1 name, refused with the new one; leaves in v3
variable "cobertura_minima" {
  type        = number
  description = "Renamed to min_coverage in contract v2"
  default     = null

  validation {
    condition     = var.cobertura_minima == null
    error_message = "cobertura_minima was renamed to min_coverage in contract v2 (deploy/app.hcl)."
  }
}

# --------------------------------------------- deploy/env/<account>.tfvars
variable "regions" {
  type        = list(string)
  description = "Regions the app runs in, in this account (ADR-008); the first one is the primary"
  default     = ["us-east-1"]
}

variable "hosts" {
  type        = list(string)
  description = "Public names (must exist in dns-cloudflare); empty = internal app"
  default     = []
}

variable "cpu" {
  type        = number
  description = "CPU units per task (256 = 0.25 vCPU)"
}

variable "memory" {
  type        = number
  description = "Memory per task (MiB)"
}

variable "min_capacity" {
  type        = number
  description = "Minimum tasks; at least 2 in production (high availability)"

  validation {
    condition     = var.environment != "production" || var.min_capacity >= 2
    error_message = "production needs min_capacity >= 2."
  }
}

variable "max_capacity" {
  type        = number
  description = "Maximum tasks (autoscaling)"
}

variable "cpu_target" {
  type        = number
  description = "Average CPU (%) that triggers autoscaling"
  default     = 70
}

# tflint-ignore: terraform_unused_declarations # part of the app contract
variable "off_hours" {
  type        = bool
  description = "Scale staging to zero off-hours (not implemented yet)"
  default     = null
}

# tflint-ignore: terraform_unused_declarations # contract v1 name, refused with the new one; leaves in v3
variable "fora_do_horario" {
  type        = bool
  description = "Renamed to off_hours in contract v2"
  default     = null

  validation {
    condition     = var.fora_do_horario == null
    error_message = "fora_do_horario was renamed to off_hours in contract v2 (deploy/env/<account>.tfvars)."
  }
}
