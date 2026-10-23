# The runner against typical app values, with a mocked AWS provider (no credentials).

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  # No deploy/data.hcl: nothing published for the app.
  mock_data "aws_ssm_parameters_by_path" {
    defaults = { names = [], values = [], arns = [], types = [] }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-12345678", cidr_block = "10.10.0.0/16" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-1", "subnet-2"] }
  }
  mock_data "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/app/x/1", security_groups = ["sg-alb"] }
  }
  mock_data "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener/app/x/1/2" }
  }
  mock_data "aws_ecs_cluster" {
    defaults = {
      arn                      = "arn:aws:ecs:us-east-1:111111111111:cluster/jonomait-stg-ecs"
      cluster_name             = "jonomait-stg-ecs"
      service_connect_defaults = [{ namespace = "arn:aws:servicediscovery:us-east-1:111111111111:namespace/ns-1" }]
    }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:jonomait/staging/svc-hello/api-AbCdEf" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/x/1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/test" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/test:1" }
  }
}

mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = { id = "zone123" }
  }
}

variables {
  # pipeline
  environment = "staging"
  region      = "us-east-1"
  image       = "traefik/whoami:v1.10.3"
  # deploy/app.hcl
  runtime = "ecs"
  name    = "svc-hello"
  port    = 80
  secrets = ["api"]
  # deploy/env/staging.tfvars
  hosts        = ["hello-stg.joshuel.com.br"]
  cpu          = 256
  memory       = 512
  min_capacity = 1
  max_capacity = 2
}

run "staging_app" {
  command = plan

  assert {
    condition     = one(output.public_hosts) == "hello-stg.joshuel.com.br" && output.internal_url == "http://svc-hello.jonomait.internal:80"
    error_message = "Public and internal names must follow the convention."
  }

  assert {
    condition     = length(module.dns) == 1 && one(module.dns[0].names) == "hello-stg.joshuel.com.br"
    error_message = "The primary region's run creates the app's public names."
  }
}

run "secondary_region_does_not_touch_dns" {
  command = plan

  variables {
    environment  = "production"
    region       = "sa-east-1"
    regions      = ["us-east-1", "sa-east-1"]
    hosts        = ["hello.joshuel.com.br"]
    min_capacity = 2
    slo          = { disponibilidade = 99.5, latencia_p95_ms = 500 }
  }

  assert {
    condition     = length(module.dns) == 0
    error_message = "Only the primary region's run owns the DNS names (they are global)."
  }
}

run "data_is_injected_and_granted" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.data_env
    values = {
      names  = ["/jonomait/staging/svc-hello/env/TABLE_PEDIDOS", "/jonomait/staging/svc-hello/env/QUEUE_PEDIDOS"]
      values = ["jonomait-stg-svc-hello-pedidos", "https://sqs.us-east-1.amazonaws.com/111111111111/jonomait-stg-svc-hello-pedidos"]
    }
  }

  override_data {
    target = data.aws_ssm_parameters_by_path.data_iam
    values = {
      names  = ["/jonomait/staging/svc-hello/iam/data-access"]
      values = ["arn:aws:iam::111111111111:policy/jonomait-stg-svc-hello-data-access"]
    }
  }

  assert {
    condition     = local.data_env["TABLE_PEDIDOS"] == "jonomait-stg-svc-hello-pedidos" && length(local.data_env) == 2
    error_message = "Every parameter under /jonomait/<env>/<app>/env becomes an environment variable."
  }

  assert {
    condition     = length(local.data_policies) == 1 && contains(local.data_policies, "arn:aws:iam::111111111111:policy/jonomait-stg-svc-hello-data-access")
    error_message = "The data-access policy goes to the task role."
  }
}

run "app_env_cannot_shadow_platform_variables" {
  command = plan

  variables {
    env = { REGION_STATE_PARAMETER = "/somewhere/else" }
  }

  expect_failures = [terraform_data.env_contract]
}

run "production_needs_two_tasks" {
  command = plan

  variables {
    environment  = "production"
    min_capacity = 1
    slo          = { disponibilidade = 99.5, latencia_p95_ms = 500 }
  }

  expect_failures = [var.min_capacity]
}

run "production_needs_an_slo" {
  command = plan

  variables {
    environment  = "production"
    min_capacity = 2
  }

  expect_failures = [var.slo]
}

run "region_must_be_listed" {
  command = plan

  variables {
    region  = "sa-east-1"
    regions = ["us-east-1"]
  }

  expect_failures = [var.region]
}

run "other_runtime_is_rejected" {
  command = plan

  variables {
    runtime = "lambda"
  }

  expect_failures = [var.runtime]
}
