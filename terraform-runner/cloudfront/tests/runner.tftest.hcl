# The runner against typical site values, with mocked providers (no credentials).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:us-east-1:111111111111:certificate/test" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { arn = "arn:aws:cloudfront::111111111111:distribution/TEST", domain_name = "d1234.cloudfront.net" }
  }
}

mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = { id = "zone123" }
  }
}

# What the platform publishes (infrastructure global/dns-cloudflare).
override_data {
  target = data.aws_ssm_parameters_by_path.platform
  values = {
    names  = ["/jonomait/production/platform/zone", "/jonomait/production/platform/regions"]
    values = ["joshuel.com.br", "us-east-1,sa-east-1"]
  }
}

variables {
  environment = "production"
  runtime     = "cloudfront"
  name        = "web-app"
  hosts       = ["app.joshuel.com.br"]
}

run "site_and_its_name" {
  command = plan

  assert {
    condition     = one(output.public_hosts) == "app.joshuel.com.br"
    error_message = "The site's public name is created by the deploy, pointing at its distribution."
  }
}

run "other_runtime_is_rejected" {
  command = plan

  variables {
    runtime = "ecs"
  }

  expect_failures = [var.runtime]
}

run "zone_comes_from_the_platform" {
  command = plan

  assert {
    condition     = local.zone == "joshuel.com.br"
    error_message = "The zone comes from the platform's parameters, not from the site's files."
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
