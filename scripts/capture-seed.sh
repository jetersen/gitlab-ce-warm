#!/usr/bin/env bash
# Runs seeds/<name>.sh against a built image and saves the files the seed
# changed to build/seeds/<name>.tar, plus its output as build/seeds/<name>.json.
# Usage: capture-seed.sh <name> <image>
set -euo pipefail

cd "$(dirname "$0")/.."
seed=$1
image=$2
name=gitlab-ce-warm-seed
marker=/opt/gitlab/gitlab-ce-warm-seed-marker
token=$(cat scripts/root-token)

cleanup() { docker rm --force "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
mkdir -p build/seeds
rm -f "build/seeds/$seed.tar" "build/seeds/$seed.json"

docker create --name "$name" --publish 127.0.0.1::8181 "$image" >/dev/null
: > build/seeds/marker
docker cp build/seeds/marker "$name:$marker"
rm -f build/seeds/marker
docker start "$name" >/dev/null

start=$(date +%s)
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" = healthy ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ] || [ $(( $(date +%s) - start )) -gt 600 ]; then
    docker logs --tail 200 "$name"
    exit 1
  fi
  sleep 1
done

"seeds/$seed.sh" "http://$(docker port "$name" 8181/tcp)/api/v4" "$token" > "build/seeds/$seed.json"
cat "build/seeds/$seed.json"

docker exec "$name" bash -euo pipefail -c "
  gitlab-ctl stop >/dev/null
  data=/var/opt/gitlab/postgresql/data
  # A cleanly stopped cluster only needs the WAL segment with its last checkpoint.
  redo=\$(pg_controldata \"\$data\" | sed -n 's/^Latest checkpoint.s REDO WAL file: *//p')
  test -n \"\$redo\"
  find \"\$data/pg_wal\" -maxdepth 1 -type f ! -name \"\$redo\" -delete
  find /var/log/gitlab -type f -exec truncate --size 0 {} +
  find / -xdev \\( -path /proc -o -path /sys -o -path /dev -o -path /run \\
    -o -path /tmp -o -path /etc/hosts -o -path /etc/hostname \\
    -o -path /etc/resolv.conf -o -path /var/log \\) -prune \\
    -o -cnewer $marker ! -type s -print > /tmp/seed-paths
  # Exit status 1 only reports files that changed while read, such as logs
  # from runit's log writers, which keep running after gitlab-ctl stop.
  tar --create --file /tmp/seed.tar --no-recursion --files-from /tmp/seed-paths \\
    --warning=no-file-changed || [ \$? -eq 1 ]
"
docker cp "$name:/tmp/seed.tar" "build/seeds/$seed.tar"
ls -lh "build/seeds/$seed.tar"
