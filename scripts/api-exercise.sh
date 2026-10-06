#!/usr/bin/env bash
# Exercises common REST and GraphQL paths against a running instance. Used to
# check that pruning keeps the API working. Usage: api-exercise.sh <base-url> <token>
set -euo pipefail

base=$1
token=$2
api_url="$base/api/v4"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

api() {
  local method=$1 path=$2 body=${3:-} response
  if ! response=$(curl --fail-with-body --silent --show-error --retry 5 --retry-connrefused \
    --request "$method" --header "Private-Token: $token" \
    --header 'Content-Type: application/json' \
    ${body:+--data "$body"} "$api_url$path"); then
    printf '%s %s failed: %s\n' "$method" "$path" "$response" >&2
    return 1
  fi
  printf '%s' "$response"
}
step() { printf '%s\n' "$*" >&2; }

step users
api GET /user >/dev/null
user=$(api POST /users '{"email":"exercise@example.com","username":"exercise","name":"Exercise","password":"Zx9-kLm2-Pq7v-T4wR","skip_confirmation":true}' | jq -r .id)
api GET "/users/$user" >/dev/null

step groups and projects
group=$(api POST /groups '{"name":"Exercise Group","path":"exercise-group"}' | jq -r .id)
project=$(api POST /projects "$(jq -nc --argjson ns "$group" '{name:"api",namespace_id:$ns,initialize_with_readme:true,default_branch:"main"}')" | jq -r .id)
api POST "/projects/$project/members" "$(jq -nc --argjson u "$user" '{user_id:$u,access_level:30}')" >/dev/null
api GET "/projects/$project" >/dev/null
api GET "/groups/$group/projects" >/dev/null

step repository
api POST "/projects/$project/repository/files/src%2Fapp.rb" '{"branch":"main","content":"puts 1\n","commit_message":"add app"}' >/dev/null
api POST "/projects/$project/repository/branches" '{"branch":"feature","ref":"main"}' >/dev/null
api PUT "/projects/$project/repository/files/src%2Fapp.rb" '{"branch":"feature","content":"puts 2\n","commit_message":"change app"}' >/dev/null
api GET "/projects/$project/repository/tree?recursive=true" >/dev/null
api GET "/projects/$project/repository/files/src%2Fapp.rb/raw?ref=main" >/dev/null
api GET "/projects/$project/repository/files/src%2Fapp.rb/blame?ref=main" >/dev/null
api GET "/projects/$project/repository/commits?ref_name=feature" >/dev/null
api GET "/projects/$project/repository/compare?from=main&to=feature" >/dev/null
curl --fail --silent --show-error --header "Private-Token: $token" --output /dev/null \
  "$api_url/projects/$project/repository/archive.tar.gz"
api POST "/projects/$project/repository/tags" '{"tag_name":"v0.1.0","ref":"main","message":"annotated"}' >/dev/null
api GET "/projects/$project/repository/contributors" >/dev/null

step merge requests
mr=$(api POST "/projects/$project/merge_requests" '{"source_branch":"feature","target_branch":"main","title":"Change app","description":"Closes nothing"}' | jq -r .iid)
api GET "/projects/$project/merge_requests/$mr/changes" >/dev/null
api POST "/projects/$project/merge_requests/$mr/notes" '{"body":"Looks **good** :thumbsup:"}' >/dev/null
api POST "/projects/$project/merge_requests/$mr/award_emoji" '{"name":"thumbsup"}' >/dev/null
for attempt in $(seq 60); do
  api PUT "/projects/$project/merge_requests/$mr/merge" '{}' >/dev/null 2>&1 || true
  [ "$(api GET "/projects/$project/merge_requests/$mr" | jq -r .state)" = merged ] && break
  [ "$attempt" -lt 60 ] || { echo "merge request did not merge" >&2; exit 1; }
  sleep 2
done

step issues, labels, milestones
api POST "/projects/$project/labels" '{"name":"bug","color":"#ff0000"}' >/dev/null
milestone=$(api POST "/projects/$project/milestones" '{"title":"v1"}' | jq -r .id)
issue=$(api POST "/projects/$project/issues" "$(jq -nc --argjson m "$milestone" '{title:"Broken",description:"See `code` and [link](https://example.com)",labels:"bug",milestone_id:$m}')" | jq -r .iid)
# shellcheck disable=SC2016 # Markdown backticks, not shell expansion.
api POST "/projects/$project/issues/$issue/notes" '{"body":"Reproduced with ```ruby\nputs 1\n```"}' >/dev/null
api PUT "/projects/$project/issues/$issue" '{"state_event":"close"}' >/dev/null
api GET "/projects/$project/issues?labels=bug" >/dev/null
api POST /markdown '{"text":"# Title\n\n- [ ] task :smile:","gfm":true}' >/dev/null

step uploads
printf 'hello\n' > "$work/notes.txt"
curl --fail-with-body --silent --show-error --header "Private-Token: $token" \
  --form "file=@$work/notes.txt" "$api_url/projects/$project/uploads" >/dev/null

step releases
api POST "/projects/$project/releases" '{"tag_name":"v1.0.0","ref":"main","name":"One","description":"First","milestones":["v1"]}' >/dev/null
api POST "/projects/$project/releases/v1.0.0/assets/links" '{"name":"docs","url":"https://example.com/docs"}' >/dev/null
api GET "/projects/$project/releases" >/dev/null

step snippets and wiki
api POST "/projects/$project/snippets" '{"title":"snip","visibility":"private","files":[{"file_path":"a.rb","content":"puts 1"}]}' >/dev/null
api POST "/projects/$project/wikis" '{"title":"Home","content":"Welcome"}' >/dev/null
api GET "/projects/$project/wikis" >/dev/null

step search and graphql
api GET "/projects/$project/search?scope=blobs&search=puts" >/dev/null
curl --fail-with-body --silent --show-error --header "Private-Token: $token" \
  --header 'Content-Type: application/json' --data "$(jq -nc --arg p "exercise-group/api" \
    '{query:"query($p:ID!){project(fullPath:$p){name repository{rootRef} mergeRequests{nodes{iid state}} issues{nodes{iid title}} releases{nodes{tagName}}}}",variables:{p:$p}}')" \
  "$base/api/graphql" | jq -e '.data.project.name == "api"' >/dev/null

step "API exercise passed"
