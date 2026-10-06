#!/usr/bin/env bash
# Seeds the project used by Release Drafter's forge conformance suite and prints
# the generated identifiers as JSON. Usage: release-drafter.sh <api-url> <token>
set -euo pipefail

api_url=$1
token=$2

api() {
  local method=$1 path=$2 body=${3:-}
  curl --fail-with-body --silent --show-error --retry 10 --retry-connrefused \
    --request "$method" --header "Private-Token: $token" \
    --header 'Content-Type: application/json' \
    ${body:+--data "$body"} "$api_url$path"
}

parent=$(api POST /groups '{"name":"Release Drafter Tests","path":"release-drafter-tests"}' | jq -r .id)
subgroup=$(api POST /groups "$(jq -nc --argjson parent "$parent" \
  '{name: "Nested Fixtures", path: "nested-fixtures", parent_id: $parent}')" | jq -r .id)
project=$(api POST /projects "$(jq -nc --argjson namespace "$subgroup" \
  '{name: "Forge Conformance", path: "forge-conformance", namespace_id: $namespace,
    initialize_with_readme: true, default_branch: "main", visibility: "private"}')" | jq -r .id)

base_commit=$(api POST "/projects/$project/repository/commits" "$(jq -nc '{
  branch: "main",
  commit_message: "chore: seed release drafter fixture",
  actions: [
    {action: "create", file_path: ".github/release-drafter.yml",
     content: "name-template: \"v$RESOLVED_VERSION\"\ntemplate: \"$CHANGES\"\n"},
    {action: "create", file_path: "src/base.ts", content: "export const base = '"'"'base'"'"'\n"}
  ]}')" | jq -r .id)
api POST "/projects/$project/repository/tags" "$(jq -nc --arg ref "$base_commit" '{tag_name: "v1.0.0", ref: $ref}')" >/dev/null
api POST "/projects/$project/repository/branches" "$(jq -nc --arg ref "$base_commit" '{branch: "feature/conformance", ref: $ref}')" >/dev/null

head_commit=$(api POST "/projects/$project/repository/commits" "$(jq -nc '{
  branch: "feature/conformance",
  commit_message: "feat: exercise forge conformance",
  actions: [
    {action: "update", file_path: "README.md", content: "# Forge Conformance\n\nGitLab integration fixture.\n"},
    {action: "create", file_path: "src/feature.ts", content: "export const feature = '"'"'gitlab'"'"'\n"}
  ]}')" | jq -r .id)

merge_request=$(api POST "/projects/$project/merge_requests" "$(jq -nc '{
  source_branch: "feature/conformance", target_branch: "main",
  title: "feat: exercise forge conformance",
  description: "Exercises normalized change discovery against GitLab.",
  labels: "feature,integration", remove_source_branch: false}')" | jq -r .iid)

# Merging waits for Sidekiq to compute mergeability.
for attempt in $(seq 60); do
  api PUT "/projects/$project/merge_requests/$merge_request/merge" '{"should_remove_source_branch":false}' >/dev/null 2>&1 || true
  merged=$(api GET "/projects/$project/merge_requests/$merge_request")
  [ "$(jq -r .state <<<"$merged")" = merged ] && [ "$(jq -r .merge_commit_sha <<<"$merged")" != null ] && break
  [ "$attempt" -lt 60 ] || { echo "Merge request !$merge_request did not merge" >&2; exit 1; }
  sleep 2
done

api POST "/projects/$project/releases" '{"tag_name":"v1.0.0","name":"Version 1.0.0","description":"Seed release"}' >/dev/null

# Load the code behind the suite's read requests so the Bootsnap cache has it.
path=release-drafter-tests%2Fnested-fixtures%2Fforge-conformance
for read in "/projects/$path" "/projects/$path/repository/files/.github%2Frelease-drafter.yml?ref=main" \
  "/projects/$project/releases" "/projects/$project/releases/v1.0.0" "/projects/$project/repository/tags" \
  "/projects/$project/repository/compare?from=v1.0.0&to=main" "/projects/$project/repository/commits?ref_name=main" \
  "/projects/$project/repository/commits/$head_commit/merge_requests" \
  "/projects/$project/merge_requests?state=merged" "/projects/$project/labels"; do
  api GET "$read" >/dev/null
done

jq -n --arg base "$base_commit" --arg head "$head_commit" --argjson merged "$merged" '{
  baseCommit: $base,
  headCommit: $head,
  mergeRequestNumber: $merged.iid,
  mergeCommit: $merged.merge_commit_sha,
  mergeRequestUrl: $merged.web_url,
  mergedAt: $merged.merged_at
}'
