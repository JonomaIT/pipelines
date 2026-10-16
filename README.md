# pipelines

What turns an app's values into a running app. Apps never write Terraform: they bring `deploy/app.hcl` and `deploy/env/<account>.tfvars`, and the runner of their `runtime` does the rest.

```
pipelines/
├── .github/workflows/
│   ├── terraform-ci.yml       reusable: fmt, validate, terraform test of every root
│   ├── terraform-deploy.yml   reusable: plan (PR) / apply (main, manual) per component × account × region
│   └── ci.yml                 this repo's own checks (actionlint + terraform-ci)
└── terraform-runner/
    └── ecs/                   generic root for every ECS app: calls the ecs-service pattern
```

**All the logic lives here.** Other repos keep a caller of a few lines that says *when* to run and passes data (like the apply order), always pinned to a tag of this repo:

```yaml
jobs:
  terraform:
    uses: JonomaIT/pipelines/.github/workflows/terraform-ci.yml@v1.0.0
```

| Repo | Calls |
|---|---|
| `terraform-modules`, `organization` | `terraform-ci` |
| `infrastructure` | `terraform-ci` + `terraform-deploy` |
| apps (`svc-*`) | `deploy-ecs` (next) |

## terraform-ci

Two jobs, no cloud access:

| Job | Does |
|---|---|
| `fmt · validate · test` | every folder with a `versions.tf` is a root: `terraform fmt -check`, `init -backend=false`, `validate` and, when it has `tests/`, `terraform test` (mocked providers), once per `env/**/*.tfvars` when there are any |
| `security scan` | **gitleaks** (secrets in the code and the history), **TFLint** (Terraform mistakes), **Trivy** (insecure configuration, HIGH and CRITICAL) |

An accepted finding is an exception **annotated in the code, with the reason**, right above the resource: `#trivy:ignore:<id>` or `# tflint-ignore: <rule>`. Scanner images are pinned by version.

## terraform-deploy

One job per **component × account × region**, found from the tfvars:

| tfvars | Type | State key |
|---|---|---|
| `<component>/env/<account>/<region>.tfvars` | regional | `<account>/<region>/<component>` |
| `global/<name>/env/<account>.tfvars` | global | `<account>/global/<name>` |
| `cross-region/<name>/env/<account>.tfvars` | cross-region | `<account>/cross-region/<name>` |

| Event | What runs |
|---|---|
| pull request | `plan` of what changed, in parallel, with the read-only role; the plans become **one PR comment** (updated on every push); **`Plan result`** fails if any plan fails: make it a required check |
| push to `main` | 1. `plan` of what changed, in parallel (read-only role), shown in the run summary · 2. **one approval per account** (its GitHub Environment), looking at those plans · 3. `apply` of **exactly those saved plans**, in `order` |
| manual | the same for a component, a tfvars or everything; `destroy: true` runs the reverse order |
| `drift: true` (schedule) | `plan` of everything **deployed** (empty states are skipped); changes or failures open or update the **"Terraform drift detected"** issue, a clean run closes it; never applies |

A target never deployed that cannot be planned alone (it reads something an earlier target creates) is **blocked** on pull requests and on `main`: not an error, it is planned at apply time. On `main`, a target whose plan needed an earlier target of the same run (e.g. `ecs-cluster` before its VPC exists) cannot be planned up front: it is planned at apply time, and that plan is written to the summary. Every other target applies the reviewed plan; if the state changed since, Terraform refuses it.

Roles: `github-actions-<repo>-plan` (read-only; pull requests and `main`) for plans and drift; `github-actions-<repo>` (write) only in the apply job, inside the account's GitHub Environment. Plan files are kept as artifacts for 1 day, only by runs that apply (never on pull requests).

*What changed*: a tfvars runs itself; a change in a component's code runs every tfvars of it; a change in `backends/<account>.tfbackend` runs everything in that account. Within a component the primary region goes first (its ACM validation record serves the other regions).

Needs: `backends/<account>.tfbackend` in the caller, the **`AWS_ACCOUNT_IDS`** org variable (`{"production": "…"}`; accounts not listed are skipped) and a GitHub Environment per account. Components with Cloudflare receive `CLOUDFLARE_API_TOKEN`.

## Versions

| Tag | Change |
|---|---|
| `v1.2.0` | ECS runner: the app creates its own public names (ADR-010, `app-dns`), only in the primary region's run; modules `v0.7.0`. |
| `v1.1.2` | `terraform-deploy`: a target with no state file yet (never applied) no longer stops the plan step. |
| `v1.1.1` | `terraform-deploy`: a plan with changes is no longer reported as failed (bash `-e` vs `-detailed-exitcode`); a never-deployed target that cannot be planned alone is **blocked**, not failed, and is planned at apply time. |
| `v1.1.0` | `terraform-ci`: `security scan` job (gitleaks, TFLint, Trivy). `terraform-deploy`: plan of everything first, **one approval per account** looking at the saved plans, apply of those plans; PR comment and `Plan result` check; `drift` mode with an issue. Needs the plan role trusting `main` (organization bootstrap). |
| `v1.0.0` | `terraform-ci` and `terraform-deploy` reusable workflows; ECS runner. |

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

**Public names (ADR-010):** the run of the primary region (first in `regions`) creates each `hosts` entry as a proxied CNAME to the environment's entry (`ingress.<zone>` in production, `ingress-<env>.<zone>` elsewhere), with the `app-dns` pattern: owner in the record comment, reserved names and names owned by another app refused. Needs `CLOUDFLARE_API_TOKEN` (in the app pipeline: a token that can only edit DNS).

Checks at plan time: `runtime = "ecs"`, production with `min_capacity >= 2` and an `slo`, the region listed in `regions`, every secret existing in Secrets Manager (`jonomait/<env>/<name>/<secret>`). Staging runs on Fargate Spot, production on Fargate.

State key: `<env>/<region>/apps/<name>`, in the bucket of the account being deployed.

## Next

- App workflows: `build-push.yml` (image to ECR in shared-services), `deploy-ecs.yml` (the ECS runner, one job per region in `regions`, production after approval), `rollback-ecs.yml`. They need the ECR component and a deploy role per app in the bootstrap.
- Regions in parallel in `terraform-deploy` (today one target at a time per account, in order).
- Infracost (cost of each PR): needs a free Infracost API key.
- The kit of workflows each app repo receives (`callers/ecs`).
- Runners for `lambda`, `cloudfront` and `eks`.
