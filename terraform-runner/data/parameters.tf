# How the app finds its data without knowing a name, a URL or an ARN: one parameter per resource
# and region, /jonomait/<env>/<app>/env/<KIND>_<NAME>, with that region's value. The ECS runner
# reads them by path and injects them as environment variables; the app reads os.environ.
#
#   table  sales          → TABLE_SALES            = table name (the same in every region)
#   topic  sales-created  → TOPIC_SALES_CREATED    = topic ARN of the region
#   queue  sales-process  → QUEUE_SALES_PROCESS    = queue URL of the region
#   bucket offload        → BUCKET_OFFLOAD         = bucket name of the region

locals {
  # A table and a queue may share a logical name (TABLE_X and QUEUE_X).
  env_name = { for n in distinct(concat(keys(var.tables), var.topics, keys(var.queues), keys(var.buckets))) : n => upper(replace(n, "-", "_")) }

  # Every variable the app gets, own and used, before merging (duplicates fail the contract).
  env_keys = concat(
    [for t, _ in var.tables : "TABLE_${local.env_name[t]}"],
    [for t in var.topics : "TOPIC_${local.env_name[t]}"],
    [for q, _ in var.queues : "QUEUE_${local.env_name[q]}"],
    [for b, _ in var.buckets : "BUCKET_${local.env_name[b]}"],
    [for u in local.uses : "${upper(u.kind)}_${upper(replace(u.logical, "-", "_"))}"],
  )

  # Variable => region => value.
  env = merge(
    { for t, _ in var.tables : "TABLE_${local.env_name[t]}" => { for r in var.regions : r => module.table[t].name } },
    { for t in var.topics : "TOPIC_${local.env_name[t]}" => module.topic[t].arns },
    { for q, _ in var.queues : "QUEUE_${local.env_name[q]}" => module.queue[q].urls },
    { for b, _ in var.buckets : "BUCKET_${local.env_name[b]}" => module.bucket[b].names },
    {
      for u in local.uses : "${upper(u.kind)}_${upper(replace(u.logical, "-", "_"))}" => {
        for r in var.regions : r => (
          u.kind == "table" ? u.physical :
          u.kind == "topic" ? "arn:aws:sns:${r}:${local.account}:${u.physical}" :
          u.kind == "queue" ? "https://sqs.${r}.amazonaws.com/${local.account}/${u.physical}" :
          "${u.physical}-${r}"
        )
      }
    },
  )
}

resource "aws_ssm_parameter" "env" {
  for_each = { for pair in setproduct(keys(local.env), var.regions) : "${pair[1]}/${pair[0]}" => { region = pair[1], key = pair[0] } }

  region         = each.value.region
  name           = "${local.parameters}/env/${each.value.key}"
  description    = "Injected into ${var.name} as ${each.value.key} (data runner, ADR-011)"
  type           = "String"
  insecure_value = local.env[each.value.key][each.value.region] # not a secret: readable in plans
}

# The ECS runner attaches this policy to the task role in every region.
resource "aws_ssm_parameter" "data_access" {
  for_each = length(local.statements) > 0 ? toset(var.regions) : toset([])

  region         = each.value
  name           = "${local.parameters}/iam/data-access"
  description    = "Data-access policy of ${var.name}, attached to its task role by the ECS runner (ADR-011)"
  type           = "String"
  insecure_value = aws_iam_policy.data_access[0].arn
}
