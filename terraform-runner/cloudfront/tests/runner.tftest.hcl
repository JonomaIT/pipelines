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
  prefix          = "jonomait"
  platform_region = "us-east-1"
  environment     = "production"
  runtime         = "cloudfront"
  name            = "web-app"
  hosts           = ["app.joshuel.com.br"]
}

run "site_and_its_name" {
  command = plan

  assert {
    condition     = one(output.public_hosts) == "app.joshuel.com.br"
    error_message = "The site's public name is created by the deploy, pointing at its distribution."
  }
}

run "copy_in_the_other_platform_region" {
  command = plan

  assert {
    condition     = local.failover_region == "sa-east-1"
    error_message = "With two platform regions the site gets a copy in the one that is not us-east-1."
  }
}

run "one_region_one_bucket" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.platform
    values = {
      names  = ["/jonomait/production/platform/zone", "/jonomait/production/platform/regions"]
      values = ["joshuel.com.br", "us-east-1"]
    }
  }

  assert {
    condition     = local.failover_region == null && output.failover_bucket == null
    error_message = "One platform region: no copy."
  }
}

run "customer_domain_in_an_allowed_zone" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.platform
    values = {
      names  = ["/jonomait/production/platform/zone", "/jonomait/production/platform/regions", "/jonomait/production/platform/site-zones"]
      values = ["joshuel.com.br", "us-east-1,sa-east-1", "cliente.com.br"]
    }
  }

  variables {
    hosts = ["cliente.com.br"]
  }

  assert {
    condition     = length(local.site_zones) == 1 && contains(local.site_zones, "cliente.com.br") && one(output.public_hosts) == "cliente.com.br"
    error_message = "A site may use the apex of a zone the platform allows (site-zones)."
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

run "a_label_is_a_name_under_the_platform_zone" {
  command = plan

  variables {
    hosts = ["app"]
  }

  assert {
    condition     = local.hosts == ["app.joshuel.com.br"] && one(output.public_hosts) == "app.joshuel.com.br"
    error_message = "A host without a dot is a label under the platform's zone."
  }
}

run "platform_read_in_its_primary_region" {
  command = plan

  variables {
    platform_region = "sa-east-1"
  }

  assert {
    condition     = data.aws_ssm_parameters_by_path.platform.region == "sa-east-1"
    error_message = "The platform's parameters are read in its primary region, not in CloudFront's."
  }
}

run "the_apex_goes_to_the_app_that_owns_it" {
  command = plan

  override_data {
    target = data.aws_ssm_parameters_by_path.platform
    values = {
      names  = ["/jonomait/production/platform/zone", "/jonomait/production/platform/regions", "/jonomait/production/platform/zone-owners"]
      values = ["joshuel.com.br", "us-east-1", "joshuel.com.br=web-app,cliente.com.br=web-cliente"]
    }
  }

  variables {
    hosts = ["joshuel.com.br"]
  }

  assert {
    condition     = local.zone_owners["joshuel.com.br"] == "web-app" && local.zone_owners["cliente.com.br"] == "web-cliente" && one(output.public_hosts) == "joshuel.com.br"
    error_message = "zone-owners reaches the modules: the owner of the platform zone's apex gets it."
  }
}

# The refusal of another app's apex is tested in the modules (app-dns, cloudfront-site): a test
# here cannot expect a failure inside a module.
