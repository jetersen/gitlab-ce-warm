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
# The warm image has no Bootsnap cache. Let this boot and the seed build one
# with only what they load.
printf 0 > build/seeds/BOOTSNAP_READONLY
docker cp build/seeds/BOOTSNAP_READONLY "$name:/opt/gitlab/etc/gitlab-rails/env/BOOTSNAP_READONLY"
rm -f build/seeds/BOOTSNAP_READONLY
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
  printf 1 > /opt/gitlab/etc/gitlab-rails/env/BOOTSNAP_READONLY
  chown root:root /opt/gitlab/etc/gitlab-rails/env/BOOTSNAP_READONLY
  # Application services can miss runit's stop timeout on slow runners. Only a
  # clean PostgreSQL shutdown matters for the snapshot, so verify that instead.
  gitlab-ctl stop puma sidekiq gitlab-workhorse || gitlab-ctl kill puma sidekiq gitlab-workhorse || true
  gitlab-ctl stop || true
  data=/var/opt/gitlab/postgresql/data
  pg_controldata \"\$data\" | grep 'Database cluster state:'
  pg_controldata \"\$data\" | grep -q 'Database cluster state: *shut down\$'
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
