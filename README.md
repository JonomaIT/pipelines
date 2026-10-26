# pipelines

What turns an app's values into a running app. Apps never write Terraform: they bring `deploy/app.hcl` and `deploy/env/<account>.tfvars` (and `deploy/data.hcl` when they keep data), and the runners do the rest.

```
pipelines/
├── .github/workflows/
│   ├── terraform-ci.yml       reusable: fmt, validate, terraform test of every root
│   ├── terraform-deploy.yml   reusable: plan (PR) / apply (main, manual) per component × account × region
│   ├── build-push.yml         reusable: app image build + Trivy scan (PR); also push to ECR (main)
│   └── ci.yml                 this repo's own checks (actionlint + terraform-ci)
└── terraform-runner/
    ├── ecs/                   generic root for every ECS app: ecs-service + app-dns
    ├── cloudfront/            generic root for every static site: cloudfront-site + app-dns
    └── data/                  generic root for every app's data (deploy/data.hcl): tables, topics, queues, buckets
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
| apps with an image (`svc-*`) | `build-push` (then `deploy-ecs`, next) |
| static sites (`web-*`) | `deploy-static` (next) |

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
| `v2.0.0` | **Contract v2: every field in English** (breaking). In `deploy/app.hcl`: `slo = { availability, latency_p95_ms }` (was `disponibilidade`, `latencia_p95_ms`), `min_coverage` (was `cobertura_minima`); in `deploy/env/<account>.tfvars`: `off_hours` (was `fora_do_horario`). The old names are refused at plan time with a message giving the new one; they leave in `v3`. `slo` needs both objectives. |
| `v1.4.3` | ECS runner: "production needs an `slo`" and "the region must be in `regions`" now **stop the plan** (variable validations). They were `check` blocks, which Terraform only reports as warnings, so a deploy breaking them went through. Tests prove both refusals. |
| `v1.4.2` | `terraform-deploy`: the apply and drift jobs use `!cancelled()` instead of `always()`, so a cancelled run no longer leaves apply jobs waiting at the approval gate (they blocked the next run through `concurrency`). |
| `v1.4.1` | Data runner: parameters written as `insecure_value` (they are names, URLs and ARNs, not secrets), so plans show what the app will receive. |
| `v1.4.0` | **ADR-011, the app declares its data.** New data runner (`terraform-runner/data`, `deploy/data.hcl`). ECS runner: injects the app's data parameters as environment variables, attaches its data-access policy, passes `REGION_STATE_PARAMETER` (ADR-012) and refuses an `env` that shadows them; modules `v0.9.0`. |
| `v1.3.1` | `terraform-deploy`: with a single target, the downloaded plan was extracted without its folder, so the PR comment came out empty and the apply planned again instead of applying the reviewed plan. Plans now live in a folder named after the target. |
| `v1.3.0` | `build-push` reusable workflow; CloudFront runner; ECS runner pulls the image from its own region's replica; modules `v0.8.0`. |
| `v1.2.0` | ECS runner: the app creates its own public names (ADR-010, `app-dns`), only in the primary region's run; modules `v0.7.0`. |
| `v1.1.2` | `terraform-deploy`: a target with no state file yet (never applied) no longer stops the plan step. |
| `v1.1.1` | `terraform-deploy`: a plan with changes is no longer reported as failed (bash `-e` vs `-detailed-exitcode`); a never-deployed target that cannot be planned alone is **blocked**, not failed, and is planned at apply time. |
| `v1.1.0` | `terraform-ci`: `security scan` job (gitleaks, TFLint, Trivy). `terraform-deploy`: plan of everything first, **one approval per account** looking at the saved plans, apply of those plans; PR comment and `Plan result` check; `drift` mode with an issue. Needs the plan role trusting `main` (organization bootstrap). |
| `v1.0.0` | `terraform-ci` and `terraform-deploy` reusable workflows; ECS runner. |

## ECS runner

```bash
cd terraform-runner/ecs
export AWS_PROFILE=jonomait-production
terraform init -reconfigure \
  -backend-config=bucket=jonomait-production-tfstate -backend-config=region=us-east-1 \
  -backend-config=key=production/us-east-1/apps/svc-sales-api
terraform plan \
  -var-file=../../../svc-sales-api/deploy/app.hcl \
  -var-file=../../../svc-sales-api/deploy/env/production.tfvars \
  -var environment=production -var region=us-east-1 \
  -var image=<image>
```

| From | Fields |
|---|---|
| the pipeline | `environment` (GitHub Environment), `region` (one job per region in `regions`), `image` (built once, promoted) |
| `deploy/app.hcl` | `runtime`, `name`, `port`, `health_check_path`, `env`, `secrets`, `slo` (`availability`, `latency_p95_ms`), `min_coverage` |
| the data runner | the app's data variables and data-access policy (when it has `deploy/data.hcl`) |
| `deploy/env/<account>.tfvars` | `regions`, `hosts`, `cpu`, `memory`, `min_capacity`, `max_capacity`, `cpu_target`, `off_hours` |

**Public names (ADR-010):** the run of the primary region (first in `regions`) creates each `hosts` entry as a proxied CNAME to the environment's entry (`ingress.<zone>` in production, `ingress-<env>.<zone>` elsewhere), with the `app-dns` pattern: owner in the record comment, reserved names and names owned by another app refused. Needs `CLOUDFLARE_API_TOKEN` (in the app pipeline: a token that can only edit DNS).

Checks at plan time: `runtime = "ecs"`, production with `min_capacity >= 2` and an `slo`, the region listed in `regions`, every secret existing in Secrets Manager (`jonomait/<env>/<name>/<secret>`), `env` not shadowing a variable the platform injects. Staging runs on Fargate Spot, production on Fargate.

**What the app receives besides its own `env`:**

| Variable | From |
|---|---|
| `TABLE_*`, `TOPIC_*`, `QUEUE_*`, `BUCKET_*` | its data, published by the data runner in this region (`/jonomait/<env>/<name>/env/*`); the task role gets the `…-data-access` policy (`/jonomait/<env>/<name>/iam/*`) |
| `REGION_STATE_PARAMETER` | the platform: parameter holding `ACTIVE` or `PASSIVE` for this region (ADR-012); the task role may read it |

State key: `<env>/<region>/apps/<name>`, in the bucket of the account being deployed.

## Data runner

`terraform-runner/data`: the data an app keeps, declared in `deploy/data.hcl` by logical name (ADR-011). One state per app and account, **apart from the app's** (`<env>/cross-region/data/<name>`): recreating or removing the app never touches its data. Every resource is created in every region of the app by the data modules of `terraform-modules`, replication included.

```hcl
# deploy/data.hcl of a worker
tables = {
  idempotency = { hash_key = "id", ttl_attribute = "expires_at" }
}
queues = {
  pedidos = { subscribe = ["svc-pedidos/pedido-criado"] } # another app's topic, every region
}
buckets = {
  notas = {} # replicated both ways
}
uses = {
  "svc-pedidos/table/pedidos" = "read-write" # another app's table
}
```

```bash
cd terraform-runner/data
terraform init -backend-config=<account backend> -backend-config=key=production/cross-region/data/svc-faturamento
terraform plan -var-file=../../../svc-faturamento/deploy/data.hcl \
  -var environment=production -var name=svc-faturamento -var 'regions=["us-east-1","sa-east-1"]'
```

| The app declares | It gets, in every region | Access |
|---|---|---|
| `tables` | DynamoDB global table, on demand, PITR, deletion protection | read-write |
| `topics` | SNS topic | publish |
| `queues` | SQS queue + DLQ, subscribed to `subscribe` (own `"<topic>"` or `"<app>/<topic>"`) of every region | consume and send |
| `buckets` | S3 bucket `<name>-<region>`, replicated both ways | read-write |
| `uses` | nothing new: access to another app's resource, which must exist | `read`, `write` or `read-write` |

Names are `jonomait-<env>-<app>-<logical name>`. The **`…-data-access`** policy lists only those actions on those ARNs (no wildcards, no `Scan`), and the plan shows it in the `permissions` output. Each resource is published as `/jonomait/<env>/<app>/env/<KIND>_<NAME>` and injected by the ECS runner (`TABLE_IDEMPOTENCY`, `QUEUE_PEDIDOS`, `BUCKET_NOTAS`, `TABLE_PEDIDOS`).

Refused at plan time, with a message saying what to fix: two resources giving the same variable, a queue subscribing to an own topic not in `topics`, `uses` naming the app itself or a resource that does not exist, malformed names.

`allow_destroy` (labs only, set by the platform): turns deletion protection off and lets buckets with objects be destroyed. Order: the data of an app before the app; a producer's data before its consumers'; on destroy, the reverse.

## build-push

Builds the repo's `Dockerfile`, scans the image with **Trivy** (HIGH/CRITICAL with a fix fail) and, on `main`, pushes it to the platform registry (ECR in shared-services, created by `infrastructure/ecr`) as `<registry>/<repo>:<sha>` with the `github-actions-ecr-push` role. Pull requests only build and scan. The registry replicates every image to the other regions; the ECS runner swaps the region in the image address, so each region pulls from its own copy.

## CloudFront runner

`terraform-runner/cloudfront`: static sites (`runtime = "cloudfront"`). Creates the private bucket and the distribution (`cloudfront-site`) and the site's public names pointing at it (`app-dns`). Global: one run per account, in us-east-1, state key `<env>/global/apps/<name>`. The files are uploaded afterwards (S3 sync with long cache, HTML/CSS/JS with `no-cache`, CloudFront invalidation).

## Next

- App workflows: `build-push.yml` (image to ECR in shared-services), `deploy-ecs.yml` (the ECS runner, one job per region in `regions`, production after approval), `rollback-ecs.yml`. They need the ECR component and a deploy role per app in the bootstrap.
- Regions in parallel in `terraform-deploy` (today one target at a time per account, in order).
- Infracost (cost of each PR): needs a free Infracost API key.
- The kit of workflows each app repo receives (`callers/ecs`).
- Runners for `lambda`, `cloudfront` and `eks`.
