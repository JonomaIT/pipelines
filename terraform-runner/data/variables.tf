# The data contract (deploy/data.hcl, ADR-011): what an app keeps, by logical name. The runner
# turns each entry into the resource in every region of the app, with protections, the
# least-privilege policy and the parameters the app reads them by.

# ------------------------------------------------------- from the pipeline
variable "environment" {
  type        = string
  description = "Account being deployed (from the GitHub Environment)"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "name" {
  type        = string
  description = "App name = repo name (ADR-005)"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase letters, digits and hyphens."
  }
}

variable "regions" {
  type        = list(string)
  description = "Regions of the app in this account, primary first (regions in deploy/env/<account>.tfvars)"

  validation {
    condition     = length(var.regions) >= 1 && length(distinct(var.regions)) == length(var.regions)
    error_message = "regions must list at least one region, without repeats."
  }
}

# ----------------------------------------------------------- deploy/data.hcl
variable "tables" {
  type = map(object({
    hash_key       = string
    hash_key_type  = optional(string, "S")
    range_key      = optional(string)
    range_key_type = optional(string, "S")
    ttl_attribute  = optional(string)
  }))
  description = "DynamoDB tables (global: a copy in every region of the app)"
  default     = {}
}

variable "topics" {
  type        = list(string)
  description = "SNS topics the app publishes to (one per region)"
  default     = []
}

variable "queues" {
  type = map(object({
    subscribe          = optional(list(string), [])
    visibility_timeout = optional(number, 60)
    retention_days     = optional(number, 4)
    max_receive_count  = optional(number, 5)
    standby            = optional(bool, false)
  }))
  description = "SQS queues the app consumes (one per region, with a dead-letter queue). subscribe: topics as \"<topic>\" (own) or \"<app>/<topic>\"; every region's queue gets every region's topic. standby (several regions): each region's queue gets only its own region's topic and <queue>-standby the other regions' copies (ADR-013)"
  default     = {}
}

variable "buckets" {
  type = map(object({
    replicate       = optional(bool, true)
    noncurrent_days = optional(number, 30)
  }))
  description = "S3 buckets (one per region, replicated both ways by default)"
  default     = {}
}

variable "uses" {
  type        = map(string)
  description = "Resources of other apps: \"<app>/<table|topic|queue|bucket>/<name>\" = \"read\" | \"write\" | \"read-write\""
  default     = {}

  validation {
    condition = alltrue([
      for k, access in var.uses : can(regex("^[a-z][a-z0-9-]+/(table|topic|queue|bucket)/[a-zA-Z0-9_-]+$", k)) && contains(["read", "write", "read-write"], access)
    ])
    error_message = "uses entries are \"<app>/<table|topic|queue|bucket>/<name>\" = \"read\" | \"write\" | \"read-write\"."
  }
}

variable "shares" {
  type        = map(map(string))
  description = "Who may use this app's resources (ADR-014): \"<table|topic|queue|bucket>/<name>\" = { \"<app>\" = \"read\" | \"write\" | \"read-write\" }. Another app's uses (and its queues' subscribe) work only with a matching share"
  default     = {}

  validation {
    condition = alltrue(flatten([
      for k, apps in var.shares : [
        for app, level in apps : can(regex("^(table|topic|queue|bucket)/[a-z0-9][a-z0-9-]*[a-z0-9]$", k)) && can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", app)) && contains(["read", "write", "read-write"], level)
      ]
    ]))
    error_message = "shares entries are \"<table|topic|queue|bucket>/<name>\" = { \"<app>\" = \"read\" | \"write\" | \"read-write\" }."
  }
}
