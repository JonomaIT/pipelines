#!/usr/bin/env bash
# Deploys (or destroys) an app in one account with this repo's runners, from the app's deploy/
# files (see action.yml). Every Terraform step is: init, plan, the plan in the run summary, apply
# of exactly that plan.
#
#   ecs          data (deploy/data.hcl) → the app in each region, primary first → smoke tests
#   cloudfront   the site's infrastructure → the built files → CloudFront invalidation
#   destroy      the reverse: regions last to first, data last
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" # this repo, at the action's tag
RUNNERS="$ROOT/terraform-runner"
APP_DIR="$PWD"
: "${ENVIRONMENT:?}" "${GITHUB_STEP_SUMMARY:=/dev/stdout}"
# The platform's identity (org variables PROJECT_PREFIX, STATE_REGION, PRIMARY_REGION).
: "${PREFIX:?org variable PROJECT_PREFIX}" "${STATE_REGION:?org variable STATE_REGION}" "${PRIMARY_REGION:?org variable PRIMARY_REGION}"
export PRIMARY_REGION # the contract's default region
DESTROY="${DESTROY:-false}"
HURL_IMAGE="ghcr.io/orange-opensource/hurl:6.1.1" # the .deb depends on the runner's libxml2

app=$(python3 "$ROOT/contract/app.py" --environment "$ENVIRONMENT" "$APP_DIR")
runtime=$(jq -r .runtime <<<"$app")
name=$(jq -r .name <<<"$app")
regions_json=$(jq -c .regions <<<"$app")
mapfile -t regions < <(jq -r '.regions[]' <<<"$app")
mapfile -t hosts < <(jq -r '.hosts[]' <<<"$app")
mapfile -t smoke_files < <(jq -r '.smoke[]' <<<"$app")
source_dir=$(jq -r .source_dir <<<"$app")

# A host without a dot is a label under the platform's zone (vendas → vendas.<zone>): the same rule
# as the runners, here for the summary and the smoke tests.
zone=""
for i in "${!hosts[@]}"; do
  if [[ "${hosts[$i]}" != *.* ]]; then
    if [ -z "$zone" ]; then
      zone=$(aws ssm get-parameter --region "$PRIMARY_REGION" --name "/$PREFIX/$ENVIRONMENT/platform/zone" --query Parameter.Value --output text)
    fi
    hosts[i]="${hosts[$i]}.$zone"
  fi
done

if [ "$DESTROY" = true ]; then mode=Destroy; else mode=Deploy; fi
{
  echo "### $mode of \`$name\` in $ENVIRONMENT"
  echo
  echo "Runtime \`$runtime\` · regions ${regions[*]} · hosts ${hosts[*]:-none}"
  echo
} >>"$GITHUB_STEP_SUMMARY"

# init <runner> <state key>: the runner's directory, on the state of this app in this account.
init() {
  terraform -chdir="$RUNNERS/$1" init -reconfigure -input=false -no-color \
    -backend-config="bucket=$PREFIX-$ENVIRONMENT-tfstate" -backend-config="region=$STATE_REGION" \
    -backend-config="key=$2"
}

# step <runner> <state key> <title> [terraform variables...]
step() {
  local runner=$1 key=$2 title=$3 mode=()
  shift 3
  if [ "$DESTROY" = true ]; then mode=(-destroy); fi
  echo "::group::$title"
  init "$runner" "$key"
  terraform -chdir="$RUNNERS/$runner" plan -input=false -no-color -lock-timeout=5m "${mode[@]}" -out=tfplan "$@" -var "prefix=$PREFIX"
  {
    echo "#### $title"
    echo '```'
    terraform -chdir="$RUNNERS/$runner" show -no-color tfplan | grep -E '^\s+# |^Plan:|^No changes' || true
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
  terraform -chdir="$RUNNERS/$runner" apply -input=false -no-color -lock-timeout=5m tfplan
  echo "::endgroup::"
}

data() {
  [ -f "$APP_DIR/deploy/data.hcl" ] || return 0
  step data "$ENVIRONMENT/cross-region/data/$name" "data · $ENVIRONMENT" \
    -var-file="$APP_DIR/deploy/data.hcl" \
    -var "environment=$ENVIRONMENT" -var "name=$name" -var "regions=$regions_json"
}

ecs() {
  local region=$1
  : "${IMAGE_TAG:?ecs apps need image-tag}" "${REGISTRY_ACCOUNT:?ecs apps need registry-account}"
  step ecs "$ENVIRONMENT/$region/apps/$name" "app · $region" \
    -var-file="$APP_DIR/deploy/app.hcl" -var-file="$APP_DIR/deploy/env/$ENVIRONMENT.tfvars" \
    -var "environment=$ENVIRONMENT" -var "region=$region" -var "regions=$regions_json" \
    -var "image=$REGISTRY_ACCOUNT.dkr.ecr.$region.amazonaws.com/$name:$IMAGE_TAG"
}

site() {
  step cloudfront "$ENVIRONMENT/global/apps/$name" "site · $ENVIRONMENT" \
    -var-file="$APP_DIR/deploy/app.hcl" -var-file="$APP_DIR/deploy/env/$ENVIRONMENT.tfvars" \
    -var "environment=$ENVIRONMENT" -var "platform_region=$PRIMARY_REGION"
}

# The site's buckets: the primary and, with two platform regions, its copy (origin failover).
site_buckets() {
  terraform -chdir="$RUNNERS/cloudfront" output -json | jq -r '.bucket.value, .failover_bucket.value | select(. != null)'
}

# Every bucket gets the same files: CloudFront may read any of them.
#   built site (the "site" artifact of build-static): hashed assets/ cached for a year, the rest
#                  (index.html, config.json) always revalidated; only those two are invalidated.
#   no build (no package.json: the files of source_dir in the repo, names that do not change
#                  between deploys): HTML, CSS, JS, JSON, XML and text always revalidated, the rest
#                  (images, video, fonts) cached for 7 days; everything is invalidated.
site_files() {
  local bucket distribution dir="${SITE_DIR:-}" built=true
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    dir="$APP_DIR/$source_dir"
    built=false
  fi
  [ -d "$dir" ] || { echo "::error::no site files: neither the site artifact nor $source_dir/ in the repo"; exit 1; }
  distribution=$(terraform -chdir="$RUNNERS/cloudfront" output -raw distribution_id)
  while read -r bucket; do
    if [ "$built" = true ]; then
      if [ -d "$dir/assets" ]; then
        aws s3 sync "$dir/assets" "s3://$bucket/assets" --cache-control "public, max-age=31536000, immutable"
      fi
      aws s3 sync "$dir" "s3://$bucket" --delete --exclude "assets/*" --cache-control "no-cache"
    else
      aws s3 sync "$dir" "s3://$bucket" --delete --cache-control "public, max-age=604800"
      aws s3 cp "$dir" "s3://$bucket/" --recursive --exclude "*" \
        --include "*.html" --include "*.css" --include "*.js" --include "*.json" \
        --include "*.xml" --include "*.txt" --include "*.webmanifest" --cache-control "no-cache"
    fi
    echo "Files of \`$dir\` in \`s3://$bucket\`." >>"$GITHUB_STEP_SUMMARY"
  done < <(site_buckets)
  if [ "$built" = true ]; then
    aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/index.html" "/config.json" >/dev/null
    echo "\`/index.html\` and \`/config.json\` invalidated." >>"$GITHUB_STEP_SUMMARY"
  else
    aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/*" >/dev/null
    echo "Everything invalidated (\`/*\`)." >>"$GITHUB_STEP_SUMMARY"
  fi
}

# The site buckets are versioned and production keeps force_destroy off: their files (a build that
# is deployed again from the same commit) are removed here, before Terraform removes the buckets.
empty_site_bucket() {
  local bucket kind objects
  init cloudfront "$ENVIRONMENT/global/apps/$name"
  while read -r bucket; do
    for kind in Versions DeleteMarkers; do
      while :; do
        objects=$(aws s3api list-object-versions --bucket "$bucket" --max-items 1000 \
          --query "{Objects: ${kind}[].{Key: Key, VersionId: VersionId}}" --output json)
        [ "$(jq '.Objects | length' <<<"$objects")" -gt 0 ] || break
        aws s3api delete-objects --bucket "$bucket" --delete "$objects" >/dev/null
      done
    done
  done < <(site_buckets 2>/dev/null || true)
}

# tests/smoke/*.hurl against every public name, with retries while the new tasks become healthy.
smoke() {
  if [ "${#smoke_files[@]}" -eq 0 ] || [ "${#hosts[@]}" -eq 0 ]; then
    echo "No smoke tests (tests/smoke/*.hurl and a public host are both needed)." >>"$GITHUB_STEP_SUMMARY"
    return 0
  fi
  local host file
  for host in "${hosts[@]}"; do
    for file in "${smoke_files[@]}"; do
      echo "::group::smoke · $host · $file"
      docker run --rm -v "$APP_DIR:/app" -w /app "$HURL_IMAGE" \
        --test --retry 20 --retry-interval 15000 --variable "host=https://$host" "$file"
      echo "::endgroup::"
      echo "Smoke \`$file\` on https://$host: passed." >>"$GITHUB_STEP_SUMMARY"
    done
  done
}

case "$runtime" in
  ecs)
    if [ "$DESTROY" = true ]; then
      for ((i = ${#regions[@]} - 1; i >= 0; i--)); do ecs "${regions[$i]}"; done
      data
    else
      data
      for region in "${regions[@]}"; do ecs "$region"; done
      smoke
    fi
    ;;
  cloudfront)
    if [ "$DESTROY" = true ]; then
      empty_site_bucket
      site
    else
      site
      site_files
    fi
    ;;
  *)
    echo "::error::runtime \"$runtime\" has no deploy in deploy-app"
    exit 1
    ;;
esac
