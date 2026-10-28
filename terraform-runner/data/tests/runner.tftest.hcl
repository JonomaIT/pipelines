# The data runner against typical deploy/data.hcl values, with a mocked AWS provider.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111111111111:jonomait-prd-svc-pedidos-pedido-criado" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:111111111111:table/test" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111111111111:test" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:us-east-1:111111111111:test"
      url = "https://sqs.us-east-1.amazonaws.com/111111111111/test"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/test" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::111111111111:policy/test" }
  }
}

# What the platform publishes (infrastructure global/dns-cloudflare): the regions it runs, no lab.
override_data {
  target = data.aws_ssm_parameters_by_path.platform
  values = {
    names  = ["/jonomait/production/platform/zone", "/jonomait/production/platform/regions", "/jonomait/production/platform/allow-destroy"]
    values = ["joshuel.com.br", "us-east-1,sa-east-1", "false"]
  }
}

# What svc-pedidos shares with svc-faturamento (its own data runner publishes it).
override_data {
  target = data.aws_ssm_parameters_by_path.shares
  values = {
    names  = ["/jonomait/production/svc-pedidos/shares/topic/pedido-criado/svc-faturamento", "/jonomait/production/svc-pedidos/shares/table/pedidos/svc-faturamento"]
    values = ["read", "read-write"]
  }
}

# A worker: consumes another app's topic, keeps an idempotency table and a replicated bucket, and
# updates the other app's table.
variables {
  environment = "production"
  name        = "svc-faturamento"
  regions     = ["us-east-1", "sa-east-1"]

  tables = {
    idempotency = { hash_key = "id", ttl_attribute = "expires_at" }
  }
  queues = {
    pedidos = { subscribe = ["svc-pedidos/pedido-criado"] }
  }
  buckets = {
    notas = {}
  }
  uses = {
    "svc-pedidos/table/pedidos" = "read-write"
  }
}

run "worker_gets_its_data_by_environment_variable" {
  command = plan

  assert {
    condition     = toset(keys(output.environment_variables)) == toset(["TABLE_IDEMPOTENCY", "QUEUE_PEDIDOS", "BUCKET_NOTAS", "TABLE_PEDIDOS"])
    error_message = "One variable per resource, own and used: <KIND>_<NAME>."
  }

  assert {
    condition = (
      output.environment_variables["BUCKET_NOTAS"]["sa-east-1"] == "jonomait-prd-svc-faturamento-notas-sa-east-1" &&
      output.environment_variables["TABLE_PEDIDOS"]["us-east-1"] == "jonomait-prd-svc-pedidos-pedidos"
    )
    error_message = "Values are the region's resource, named jonomait-<env>-<app>-<name>."
  }

  assert {
    condition     = length(aws_ssm_parameter.env) == 8 && aws_ssm_parameter.env["sa-east-1/QUEUE_PEDIDOS"].name == "/jonomait/production/svc-faturamento/env/QUEUE_PEDIDOS"
    error_message = "4 variables × 2 regions, under /jonomait/<env>/<app>/env/."
  }

  assert {
    condition     = length(aws_ssm_parameter.data_access) == 2 && aws_iam_policy.data_access[0].name == "jonomait-prd-svc-faturamento-data-access"
    error_message = "The data-access policy is published in every region for the ECS runner."
  }
}

run "least_privilege_from_what_was_declared" {
  command = plan

  assert {
    condition     = toset(keys(output.permissions)) == toset(["TableRead", "TableWrite", "QueueRead", "QueueWrite", "BucketRead", "BucketWrite", "BucketList"])
    error_message = "Only the kinds the app declared; a worker does not publish."
  }

  assert {
    condition = (
      contains(output.permissions["TableWrite"].resources, "arn:aws:dynamodb:sa-east-1:111111111111:table/jonomait-prd-svc-pedidos-pedidos") &&
      contains(output.permissions["BucketList"].resources, "arn:aws:s3:::jonomait-prd-svc-faturamento-notas-us-east-1") &&
      !contains(output.permissions["TableRead"].actions, "dynamodb:Scan")
    )
    error_message = "Grants cover every region of the declared resources, never a wildcard, never Scan."
  }
}

run "publisher" {
  command = plan

  variables {
    name    = "svc-pedidos"
    tables  = { pedidos = { hash_key = "id" } }
    topics  = ["pedido-criado"]
    queues  = {}
    buckets = {}
    uses    = {}
  }

  assert {
    condition     = contains(keys(output.permissions), "TopicWrite") && !contains(keys(output.permissions), "QueueRead")
    error_message = "A publisher may publish to its topics and nothing else of SNS/SQS."
  }

  assert {
    condition     = contains(keys(output.environment_variables), "TOPIC_PEDIDO_CRIADO")
    error_message = "The topic ARN is injected as TOPIC_<NAME>."
  }
}

run "no_data_no_policy" {
  command = plan

  variables {
    tables  = {}
    queues  = {}
    buckets = {}
    uses    = {}
  }

  assert {
    condition     = length(aws_iam_policy.data_access) == 0 && length(aws_ssm_parameter.env) == 0 && output.data_access_policy == null
    error_message = "An app without data gets nothing."
  }
}

run "standby_queue_for_active_active" {
  command = plan

  variables {
    queues = {
      pedidos = { subscribe = ["svc-pedidos/pedido-criado"], standby = true }
    }
  }

  assert {
    condition     = contains(keys(output.environment_variables), "QUEUE_PEDIDOS_STANDBY") && length(output.environment_variables["QUEUE_PEDIDOS_STANDBY"]) == 2
    error_message = "With standby the app also gets QUEUE_<NAME>_STANDBY in every region."
  }

  assert {
    condition     = contains(output.permissions["QueueRead"].resources, "arn:aws:sqs:sa-east-1:111111111111:jonomait-prd-svc-faturamento-pedidos-standby")
    error_message = "The app may consume its standby queue."
  }
}

run "table_and_queue_may_share_a_name" {
  command = plan

  variables {
    tables = { notas = { hash_key = "id" } }
    uses   = {}
  }

  assert {
    condition     = contains(keys(output.environment_variables), "TABLE_NOTAS") && contains(keys(output.environment_variables), "BUCKET_NOTAS")
    error_message = "Different kinds give different variables (TABLE_X, BUCKET_X)."
  }
}

run "same_variable_twice_is_rejected" {
  command = plan

  variables {
    tables = {
      idempotency = { hash_key = "id" }
      pedidos     = { hash_key = "id" }
    }
  }

  expect_failures = [terraform_data.contract]
}

run "undeclared_own_topic_is_rejected" {
  command = plan

  variables {
    queues = { pedidos = { subscribe = ["pedido-criado"] } }
  }

  expect_failures = [terraform_data.contract]
}

run "malformed_uses_is_rejected" {
  command = plan

  variables {
    uses = { "svc-pedidos/database/pedidos" = "read" }
  }

  expect_failures = [var.uses]
}

# ------------------------------------------------------------- ADR-014 guardrails

run "data_protection_follows_the_platform" {
  command = plan

  assert {
    condition     = local.allow_destroy == false
    error_message = "Outside a lab, app data keeps deletion protection; deploy/data.hcl cannot change it."
  }
}

run "lab_platform_may_allow_destroy" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.platform
    values = {
      names  = ["/jonomait/production/platform/regions", "/jonomait/production/platform/allow-destroy"]
      values = ["us-east-1,sa-east-1", "true"]
    }
  }

  assert {
    condition     = local.allow_destroy == true
    error_message = "Only the platform's parameter turns deletion protection off (labs)."
  }
}

run "missing_platform_parameters_are_refused" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.platform
    values = { names = [], values = [] }
  }

  expect_failures = [terraform_data.platform]
}

run "region_the_platform_does_not_run_is_refused" {
  command = plan

  variables {
    regions = ["us-east-1", "eu-west-1"]
  }

  expect_failures = [terraform_data.platform]
}

run "too_many_resources_need_an_exception" {
  command = plan

  variables {
    topics = [for i in range(11) : "topico-${i}"]
  }

  expect_failures = [terraform_data.platform]
}

run "using_unshared_data_is_refused" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.shares
    values = { names = [], values = [] }
  }

  expect_failures = [terraform_data.shares]
}

run "share_with_less_access_is_refused" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.shares
    values = {
      names  = ["/jonomait/production/svc-pedidos/shares/topic/pedido-criado/svc-faturamento", "/jonomait/production/svc-pedidos/shares/table/pedidos/svc-faturamento"]
      values = ["read", "read"]
    }
  }

  expect_failures = [terraform_data.shares]
}

run "owner_publishes_its_shares" {
  command = plan

  variables {
    name    = "svc-pedidos"
    tables  = { pedidos = { hash_key = "id" } }
    topics  = ["pedido-criado"]
    queues  = {}
    buckets = {}
    uses    = {}
    shares = {
      "table/pedidos"       = { "svc-faturamento" = "read-write" }
      "topic/pedido-criado" = { "svc-faturamento" = "read" }
    }
  }

  assert {
    condition = (
      length(aws_ssm_parameter.share) == 4 &&
      aws_ssm_parameter.share["sa-east-1/table/pedidos/svc-faturamento"].name == "/jonomait/production/svc-pedidos/shares/table/pedidos/svc-faturamento" &&
      aws_ssm_parameter.share["sa-east-1/table/pedidos/svc-faturamento"].insecure_value == "read-write"
    )
    error_message = "Each share is published in every region, where the consumer's data runner reads it."
  }
}

run "sharing_what_the_app_does_not_own_is_refused" {
  command = plan

  variables {
    shares = { "table/nao-existe" = { "svc-pedidos" = "read" } }
  }

  expect_failures = [terraform_data.shares]
}
