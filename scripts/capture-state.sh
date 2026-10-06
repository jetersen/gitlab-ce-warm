#!/usr/bin/env bash
# Boots the base image once, lets Omnibus configure it, and writes every file
# that configuration created or changed to build/state.tar.
set -euo pipefail

cd "$(dirname "$0")/.."
image=$(sed -n 's/^FROM \(gitlab\/gitlab-ce:[^ ]*\) AS base$/\1/p' Dockerfile)
[ -n "$image" ] || { echo "Base image not found in Dockerfile" >&2; exit 1; }
name=gitlab-ce-warm-capture
marker=/opt/gitlab/gitlab-ce-warm-marker
token=$(cat scripts/root-token)

cleanup() { docker rm --force "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
mkdir -p build
rm -f build/state.tar

omnibus_config=(
  "external_url 'http://localhost:8181'"
  "letsencrypt['enable'] = false"
  "gitlab_kas['enable'] = false"
  "logrotate['enable'] = false"
  # Workhorse serves HTTP directly without the bundled NGINX.
  "nginx['enable'] = false"
  "gitlab_workhorse['listen_network'] = 'tcp'"
  "gitlab_workhorse['listen_addr'] = '0.0.0.0:8181'"
  "prometheus_monitoring['enable'] = false"
  "puma['worker_processes'] = 0"
  "sidekiq['concurrency'] = 10"
  "sidekiq['metrics_enabled'] = false"
  "gitlab_rails['rake_cache_clear'] = false"
  "gitlab_rails['usage_ping_enabled'] = false"
  "gitlab_rails['gitlab_signup_enabled'] = false"
  # The image keeps the compile cache from this boot.
  "gitlab_rails['env'] = { 'ENABLE_BOOTSNAP' => '1' }"
)
config=$(printf '%s; ' "${omnibus_config[@]}")

# Test instances touch a small part of GitLab. Loading classes on demand starts
# Puma and Sidekiq much sooner than eager loading the whole application.
lazy_load="sed -i 's/config.eager_load = true/config.eager_load = false/' /opt/gitlab/embedded/service/gitlab-rails/config/environments/production.rb"

docker create --name "$name" --shm-size 256m \
  --tmpfs /var/opt/gitlab/postgresql:rw,noexec,nosuid,size=1g \
  -e GITLAB_DISABLE_OPENSSH=true \
  -e GITLAB_ROOT_PASSWORD="Warm-Start-$(openssl rand -hex 24)" \
  -e GITLAB_PRE_RECONFIGURE_SCRIPT="$lazy_load" \
  -e GITLAB_OMNIBUS_CONFIG="$config" \
  "$image" >/dev/null

# Database seeds run once during the first reconfigure.
seed=$(mktemp)
cat > "$seed" <<RUBY
ApplicationSetting.current_without_cache.update!(require_personal_access_token_expiry: false)
Gitlab::CurrentSettings.expire_current_application_settings
user = User.find_by_username!('root')
token = PersonalAccessToken.new(user: user, name: 'gitlab-ce-warm', scopes: %w[api read_repository write_repository sudo admin_mode], expires_at: nil)
token.set_token('${token}')
token.save!
RUBY
chmod 0644 "$seed"
docker cp "$seed" "$name:/opt/gitlab/embedded/service/gitlab-rails/db/fixtures/production/90_gitlab_ce_warm_token.rb"
rm -f "$seed"
: > build/marker
docker cp build/marker "$name:$marker"
rm -f build/marker

docker start "$name" >/dev/null
start=$(date +%s)
until docker exec "$name" sh -c "curl -sf 'http://127.0.0.1:8181/-/readiness?all=1' >/dev/null && curl -sf http://127.0.0.1:8181/-/health | grep -q 'GitLab OK'" 2>/dev/null; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ] || [ $(( $(date +%s) - start )) -gt 1200 ]; then
    docker logs "$name" > build/capture.log 2>&1; tail -n 60 build/capture.log
    exit 1
  fi
  sleep 2
done
echo "Configured in $(( $(date +%s) - start ))s"

docker exec "$name" bash -euo pipefail -c "
  gitlab-ctl stop >/dev/null
  data=/var/opt/gitlab/postgresql/data
  # A cleanly stopped cluster only needs the WAL segment with its last checkpoint.
  redo=\$(pg_controldata \"\$data\" | sed -n 's/^Latest checkpoint.s REDO WAL file: *//p')
  test -n \"\$redo\"
  find \"\$data/pg_wal\" -maxdepth 1 -type f ! -name \"\$redo\" -delete
  find /var/log/gitlab -type f -exec truncate --size 0 {} +
  rm -f /opt/gitlab/embedded/service/gitlab-rails/db/fixtures/production/90_gitlab_ce_warm_token.rb
  {
    find / -xdev \\( -path /proc -o -path /sys -o -path /dev -o -path /run \\
      -o -path /tmp -o -path /root -o -path /var/cache -o -path /etc/hosts \\
      -o -path /etc/hostname -o -path /etc/resolv.conf \\
      -o -path /opt/gitlab/embedded/cookbooks \\) -prune \\
      -o -cnewer $marker -print
    find /etc/gitlab /var/opt/gitlab /var/log/gitlab ! -type s
  } > /tmp/state-paths
  tar --create --file /tmp/state.tar --no-recursion --files-from /tmp/state-paths
"
docker cp "$name:/tmp/state.tar" build/state.tar
ls -lh build/state.tar
