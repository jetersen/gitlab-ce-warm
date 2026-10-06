#!/usr/bin/env bash
# Starts an image and checks that the API accepts the documented root token.
set -euo pipefail

cd "$(dirname "$0")/.."
image=$1
name=gitlab-ce-warm-smoke
token=$(cat scripts/root-token)
trap 'docker rm --force "$name" >/dev/null 2>&1 || true' EXIT

start=$(date +%s)
docker run --detach --name "$name" --publish 127.0.0.1::8181 \
  --env GITLAB_DISABLED_SERVICES="${GITLAB_DISABLED_SERVICES:-}" "$image" >/dev/null
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" = healthy ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ] || [ $(( $(date +%s) - start )) -gt 600 ]; then
    docker logs --tail 200 "$name"
    exit 1
  fi
  sleep 1
done
echo "Healthy after $(( $(date +%s) - start ))s"

# The broad exercise merges a merge request, which needs Sidekiq.
if docker exec "$name" test -e /opt/gitlab/service/sidekiq; then
  scripts/api-exercise.sh "http://$(docker port "$name" 8181/tcp)" "$token"
fi

url="http://$(docker port "$name" 8181/tcp)/api/v4"
api() { curl --fail-with-body --silent --show-error --header "Private-Token: $token" --header 'Content-Type: application/json' "$@"; }
[ "$(api "$url/user" | jq -r .username)" = root ]
project=$(api --request POST "$url/projects" --data '{"name":"smoke","initialize_with_readme":true}' | jq -r .id)
api --request POST "$url/projects/$project/releases" --data '{"tag_name":"v1.0.0","ref":"main","name":"Smoke"}' | jq -e '.tag_name == "v1.0.0"' >/dev/null
echo "API smoke test passed"
