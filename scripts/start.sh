#!/bin/bash
# Starts the services configured at build time. Omnibus reconfigure already ran
# while the image was built, so the image wrapper's startup work is skipped.
set -euo pipefail

# Space-separated runit services to leave stopped, for example "sidekiq".
for service in ${GITLAB_DISABLED_SERVICES:-}; do
  rm -f "/opt/gitlab/service/${service}"
done

# Services log to files. Follow them so `docker logs` shows startup and errors.
tail --quiet --lines=+1 --follow=name --retry \
  /var/log/gitlab/*/current /var/log/gitlab/gitlab-rails/*.log 2>/dev/null &

exec /opt/gitlab/embedded/bin/runsvdir-start
