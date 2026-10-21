# Generic root for the data of every app (ADR-011): the app declares what it keeps in
# deploy/data.hcl, by logical name, and this builds it in every region of the app, in a state of
# its own, apart from the app's (recreating or removing the app never touches its data).
#
#   terraform init -backend-config=<account backend> -backend-config=key=<env>/cross-region/data/<name>
#   terraform apply -var-file=deploy/data.hcl \
#     -var environment=<env> -var name=<name> -var 'regions=["us-east-1","sa-east-1"]'
#
# What the app gets, without writing Terraform or IAM:
#   - every resource in every region, named jonomait-<env>-<app>-<logical name>, with the
#     protections of the data modules (encryption, TLS only, backups, deletion protection);
#   - one IAM policy, <prefix>-data-access, with only the actions it needs, only on its resources
#     and on the ones it declared in uses: the ECS runner attaches it to the app's task role;
#   - one parameter per resource and region, /jonomait/<env>/<app>/env/<KIND>_<NAME>, that the ECS
#     runner injects as an environment variable (TABLE_SALES, QUEUE_SALES_PROCESSING, ...).

locals {
  env_short  = { staging = "stg", production = "prd" }[var.environment]
  prefix     = "jonomait-${local.env_short}-${var.name}" # jonomait-prd-svc-vendas
  parameters = "/jonomait/${var.environment}/${var.name}"
  account    = data.aws_caller_identity.current.account_id

  # Resources of other apps: "<app>/<kind>/<name>" = access.
  uses = {
    for k, access in var.uses : k => {
      app      = split("/", k)[0]
      kind     = split("/", k)[1]
      logical  = split("/", k)[2]
      physical = "jonomait-${local.env_short}-${split("/", k)[0]}-${split("/", k)[2]}"
      access   = access
    }
  }

  # Topics the queues subscribe to: "<topic>" is this app's, "<app>/<topic>" another app's.
  subscribe_refs = distinct(flatten([for q in var.queues : q.subscribe]))
  foreign_topics = {
    for pair in setproduct([for s in local.subscribe_refs : s if strcontains(s, "/")], var.regions) : "${pair[0]}|${pair[1]}" => {
      physical = "jonomait-${local.env_short}-${replace(pair[0], "/", "-")}"
      region   = pair[1]
    }
  }
}

data "aws_caller_identity" "current" {}

# Mistakes in deploy/data.hcl fail the plan with a message that says what to fix. The resources in
# uses are looked up first: one that does not exist fails here, before anything is created.
resource "terraform_data" "contract" {
  input = {
    app = var.name
    uses = concat(
      [for d in data.aws_dynamodb_table.used : d.arn],
      [for d in data.aws_sns_topic.used : d.arn],
      [for d in data.aws_sqs_queue.used : d.arn],
      [for d in data.aws_s3_bucket.used : d.arn],
    )
  }

  lifecycle {
    precondition {
      condition     = length(local.env_keys) == length(distinct(local.env_keys))
      error_message = "Two resources give the same environment variable (${join(", ", local.env_keys)}): rename one of them in deploy/data.hcl."
    }

    precondition {
      condition     = alltrue([for s in local.subscribe_refs : strcontains(s, "/") || contains(var.topics, s)])
      error_message = "A queue subscribes to a topic of this app that is not in topics: use \"<topic>\" for the app's own topics and \"<app>/<topic>\" for another app's."
    }

    precondition {
      condition     = alltrue([for u in local.uses : u.app != var.name])
      error_message = "uses lists resources of other apps; the app's own resources are already granted."
    }

    precondition {
      condition = alltrue([
        for n in concat(keys(var.tables), var.topics, keys(var.queues), keys(var.buckets)) : can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", n))
      ])
      error_message = "Logical names are lowercase letters, digits and hyphens (e.g. sales-created)."
    }
  }
}

# ------------------------------------------------------------------ resources
module "table" {
  source   = "git::https://github.com/JonomaIT/terraform-modules.git//dynamodb-table?ref=v0.9.0"
  for_each = var.tables

  name                = "${local.prefix}-${each.key}"
  regions             = var.regions
  hash_key            = each.value.hash_key
  hash_key_type       = each.value.hash_key_type
  range_key           = each.value.range_key
  range_key_type      = each.value.range_key_type
  ttl_attribute       = each.value.ttl_attribute
  deletion_protection = !var.allow_destroy
}

module "topic" {
  source   = "git::https://github.com/JonomaIT/terraform-modules.git//sns-topic?ref=v0.9.0"
  for_each = toset(var.topics)

  name    = "${local.prefix}-${each.key}"
  regions = var.regions
}

# Another app's topic must already exist in every region: its data is deployed first.
data "aws_sns_topic" "subscribed" {
  for_each = local.foreign_topics

  region = each.value.region
  name   = each.value.physical
}

module "queue" {
  source   = "git::https://github.com/JonomaIT/terraform-modules.git//sqs-queue?ref=v0.9.0"
  for_each = var.queues

  name               = "${local.prefix}-${each.key}"
  regions            = var.regions
  visibility_timeout = each.value.visibility_timeout
  retention_days     = each.value.retention_days
  max_receive_count  = each.value.max_receive_count

  # Every region's queue gets the topic of every region. An undeclared own topic is left out
  # here and reported by the contract.
  subscribe_topic_arns = distinct(flatten([
    for s in each.value.subscribe : strcontains(s, "/")
    ? [for r in var.regions : data.aws_sns_topic.subscribed["${s}|${r}"].arn]
    : [for r in var.regions : module.topic[s].arns[r] if contains(var.topics, s)]
  ]))

  depends_on = [terraform_data.contract]
}

module "bucket" {
  source   = "git::https://github.com/JonomaIT/terraform-modules.git//s3-bucket?ref=v0.9.0"
  for_each = var.buckets

  name            = "${local.prefix}-${each.key}"
  regions         = var.regions
  replicate       = each.value.replicate
  noncurrent_days = each.value.noncurrent_days
  force_destroy   = var.allow_destroy
}

# Resources of other apps must exist (checked in the primary region) before they can be granted.
data "aws_dynamodb_table" "used" {
  for_each = { for k, u in local.uses : k => u if u.kind == "table" }

  region = var.regions[0]
  name   = each.value.physical
}

data "aws_sns_topic" "used" {
  for_each = { for k, u in local.uses : k => u if u.kind == "topic" }

  region = var.regions[0]
  name   = each.value.physical
}

data "aws_sqs_queue" "used" {
  for_each = { for k, u in local.uses : k => u if u.kind == "queue" }

  region = var.regions[0]
  name   = each.value.physical
}

data "aws_s3_bucket" "used" {
  for_each = { for k, u in local.uses : k => u if u.kind == "bucket" }

  region = var.regions[0]
  bucket = "${each.value.physical}-${var.regions[0]}"
}
