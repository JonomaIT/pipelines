# The data-access policy: least privilege, built from what the app declared. The app's own
# resources get the access their role implies (tables and buckets read-write, topics publish,
# queues consume and send); another app's resources get only what uses asks for.

locals {
  grants = concat(
    [for t, _ in var.tables : { kind = "table", physical = "${local.prefix}-${t}", access = "read-write" }],
    [for t in var.topics : { kind = "topic", physical = "${local.prefix}-${t}", access = "write" }],
    [for q, _ in var.queues : { kind = "queue", physical = "${local.prefix}-${q}", access = "read-write" }],
    [for b, _ in var.buckets : { kind = "bucket", physical = "${local.prefix}-${b}", access = "read-write" }],
    [for u in local.uses : { kind = u.kind, physical = u.physical, access = u.access }],
  )

  # What "read" and "write" mean for each kind. Scan is left out on purpose: apps read by key.
  actions = {
    table = {
      read  = ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:ConditionCheckItem", "dynamodb:DescribeTable"]
      write = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:BatchWriteItem"]
    }
    topic = {
      read  = ["sns:GetTopicAttributes"]
      write = ["sns:Publish"]
    }
    queue = {
      read  = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
      write = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
    }
    bucket = {
      read  = ["s3:GetObject"]
      write = ["s3:PutObject", "s3:DeleteObject"]
    }
  }

  # ARNs of a resource in every region of the app.
  arns = {
    for g in local.grants : "${g.kind}|${g.physical}" => flatten([
      for r in var.regions : (
        g.kind == "table" ? ["arn:aws:dynamodb:${r}:${local.account}:table/${g.physical}", "arn:aws:dynamodb:${r}:${local.account}:table/${g.physical}/index/*"] :
        g.kind == "topic" ? ["arn:aws:sns:${r}:${local.account}:${g.physical}"] :
        g.kind == "queue" ? ["arn:aws:sqs:${r}:${local.account}:${g.physical}"] :
        ["arn:aws:s3:::${g.physical}-${r}/*"]
      )
    ])
  }

  # One statement per kind and level ("TableRead", "QueueWrite", ...), only when something needs it.
  statements = merge(
    {
      for pair in setproduct(keys(local.actions), ["read", "write"]) : "${title(pair[0])}${title(pair[1])}" => {
        actions   = local.actions[pair[0]][pair[1]]
        resources = flatten([for g in local.grants : local.arns["${g.kind}|${g.physical}"] if g.kind == pair[0] && strcontains(g.access, pair[1])])
      }
      if length([for g in local.grants : g if g.kind == pair[0] && strcontains(g.access, pair[1])]) > 0
    },
    # Listing a bucket is an action on the bucket, not on its objects.
    length([for g in local.grants : g if g.kind == "bucket" && strcontains(g.access, "read")]) == 0 ? {} : {
      BucketList = {
        actions   = ["s3:ListBucket"]
        resources = flatten([for g in local.grants : [for r in var.regions : "arn:aws:s3:::${g.physical}-${r}"] if g.kind == "bucket" && strcontains(g.access, "read")])
      }
    },
  )
}

data "aws_iam_policy_document" "data_access" {
  count = length(local.statements) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = local.statements

    content {
      sid       = statement.key
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_policy" "data_access" {
  count = length(local.statements) > 0 ? 1 : 0

  name        = "${local.prefix}-data-access"
  description = "Data of ${var.name} in ${var.environment} (deploy/data.hcl, ADR-011): attached to its task role by the ECS runner"
  policy      = data.aws_iam_policy_document.data_access[0].json
}
