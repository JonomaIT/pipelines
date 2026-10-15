# pipelines

What turns an app's values into a running app. Apps never write Terraform: they bring `deploy/app.hcl` and `deploy/env/<account>.tfvars`, and the runner of their `runtime` does the rest.

```
pipelines/
├── terraform-runner/
│   └── ecs/            generic root for every ECS app: calls the ecs-service pattern
└── .github/workflows/  CI (reusable deploy workflows come next)
```

## ECS runner

```bash
cd terraform-runner/ecs
export AWS_PROFILE=jonomait-staging
terraform init -reconfigure \
  -backend-config=bucket=jonomait-staging-tfstate -backend-config=region=us-east-1 \
  -backend-config=key=staging/us-east-1/apps/svc-hello
terraform plan \
  -var-file=../../../svc-hello/deploy/app.hcl \
  -var-file=../../../svc-hello/deploy/env/staging.tfvars \
  -var environment=staging -var region=us-east-1 \
  -var image=<image>
```

| From | Fields |
|---|---|
| the pipeline | `environment` (GitHub Environment), `region` (one job per region in `regions`), `image` (built once, promoted) |
| `deploy/app.hcl` | `runtime`, `name`, `port`, `health_check_path`, `env`, `secrets`, `slo`, `cobertura_minima` |
| `deploy/env/<account>.tfvars` | `regions`, `hosts`, `cpu`, `memory`, `min_capacity`, `max_capacity`, `cpu_target`, `fora_do_horario` |

Checks at plan time: `runtime = "ecs"`, production with `min_capacity >= 2` and an `slo`, the region listed in `regions`, every secret existing in Secrets Manager (`jonomait/<env>/<name>/<secret>`). Staging runs on Fargate Spot, production on Fargate.

State key: `<env>/<region>/apps/<name>`, in the bucket of the account being deployed.

## Next

- Reusable workflows: `build-push.yml` (image to ECR in shared-services), `deploy-ecs.yml` (one job per region, `fail-fast: false`, production after approval), `rollback-ecs.yml`.
- The kit of workflows each app repo receives (`callers/ecs`).
- Runners for `lambda`, `cloudfront` and `eks`.
