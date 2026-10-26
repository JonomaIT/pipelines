# Data of another app is used only with its owner's consent (ADR-014): the owner lists who may use
# each resource in `shares`, and this app's `uses` (and its queues' `subscribe`) must match a share
# with at least the access asked for. Consumer asks, owner agrees, both in reviewed files.

locals {
  # This app's resources, as "<kind>/<name>" (what its shares may list).
  own_resources = concat(
    [for t, _ in var.tables : "table/${t}"],
    [for t in var.topics : "topic/${t}"],
    [for q, _ in var.queues : "queue/${q}"],
    [for b, _ in var.buckets : "bucket/${b}"],
  )

  # What this app asks of other apps: "<app>/<kind>/<name>" = access. Subscribing to a topic reads it.
  requests = merge(
    { for s in local.subscribe_refs : "${split("/", s)[0]}/topic/${split("/", s)[1]}" => "read" if strcontains(s, "/") },
    var.uses,
  )
  producers = distinct([for k, _ in local.requests : split("/", k)[0]])

  # What each owner shares: "<app>/<kind>/<name>/<consumer>" = access (from its data runner).
  granted = merge([
    for app, found in data.aws_ssm_parameters_by_path.shares : {
      for i, n in found.names : "${app}/${trimprefix(n, "/jonomait/${var.environment}/${app}/shares/")}" => nonsensitive(found.values[i])
    }
  ]...)

  covers   = { "read" = ["read"], "write" = ["write"], "read-write" = ["read", "write", "read-write"] }
  unshared = [for k, access in local.requests : k if !contains(lookup(local.covers, lookup(local.granted, "${k}/${var.name}", "none"), []), access)]
}

data "aws_ssm_parameters_by_path" "shares" {
  for_each = toset(local.producers)

  region    = var.regions[0]
  path      = "/jonomait/${var.environment}/${each.key}/shares"
  recursive = true
}

resource "terraform_data" "shares" {
  input = var.name

  lifecycle {
    precondition {
      condition     = alltrue([for k, _ in var.shares : contains(local.own_resources, k)])
      error_message = "shares lists \"<kind>/<name>\" of this app's own resources (declared in tables, topics, queues or buckets)."
    }

    precondition {
      condition     = length(local.unshared) == 0
      error_message = "Not shared with ${var.name}: ${join(", ", [for k in local.unshared : "${k} (${local.requests[k]})"])}. The owner adds it to its deploy/data.hcl, e.g. shares = { \"<kind>/<name>\" = { \"${var.name}\" = \"<access>\" } }, and deploys its data first."
    }
  }
}

# This app's shares, published where the consumers' data runners read them, in every region.
resource "aws_ssm_parameter" "share" {
  for_each = {
    for item in flatten([
      for k, apps in var.shares : [for app, access in apps : [for r in var.regions : { id = "${r}/${k}/${app}", region = r, path = "${k}/${app}", access = access }]]
    ]) : item.id => item
  }

  region         = each.value.region
  name           = "${local.parameters}/shares/${each.value.path}"
  description    = "${var.name} lets ${basename(each.value.path)} use ${dirname(each.value.path)} (ADR-014)"
  type           = "String"
  insecure_value = each.value.access
}
