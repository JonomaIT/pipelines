# The runner against typical app values, with a mocked AWS provider (no credentials).

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
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

run "other_runtime_is_rejected" {
  command = plan

  variables {
    runtime = "lambda"
  }

  expect_failures = [var.runtime]
}
