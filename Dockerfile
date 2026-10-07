# syntax=docker/dockerfile:1

# Dependabot updates this tag and digest. scripts/capture-state.sh reads it too.
FROM gitlab/gitlab-ce:19.4.1-ce.0@sha256:9b33b45b9f42d176bada85ee5ecb81ddab7e506c435f44cd582206e284b2809c AS base

FROM base AS slim
# Configured Omnibus state captured from the same base image by
# scripts/capture-state.sh. It replaces the first-start reconfigure.
ADD build/state.tar /
COPY scripts/start.sh /usr/local/bin/gitlab-warm-start
COPY scripts/disable-gc.rb /opt/gitlab/embedded/lib/gitlab-ce-warm/disable-gc.rb
COPY --chmod=644 patches/mustermann_translator_cache.rb /opt/gitlab/embedded/service/gitlab-rails/config/initializers/zz_mustermann_translator_cache.rb
# Boot settings for a short-lived test instance, read by Puma and Sidekiq:
# - partition sync already ran while the state was captured
# - the prebuilt Bootsnap cache is complete, so never write to it
# - no memory watchdog thread and no database config validation
RUN set -eu; \
  cd /opt/gitlab/etc/gitlab-rails/env; \
  printf true > DISABLE_POSTGRES_PARTITION_CREATION_ON_STARTUP; \
  printf 1 > BOOTSNAP_READONLY; \
  printf false > GITLAB_MEMORY_WATCHDOG_ENABLED; \
  printf true > SKIP_DATABASE_CONFIG_VALIDATION; \
  chmod 644 DISABLE_POSTGRES_PARTITION_CREATION_ON_STARTUP BOOTSNAP_READONLY \
    GITLAB_MEMORY_WATCHDOG_ENABLED SKIP_DATABASE_CONFIG_VALIDATION
# Drop what an API-only test instance never loads: compiled frontend assets,
# translations, bundled documentation, and binaries for disabled services.
RUN set -eux; \
  for service in puma sidekiq; do \
    sed -i 's|^rubyopt="-W:no-experimental"$|rubyopt="-W:no-experimental --disable=did_you_mean,error_highlight,syntax_suggest -r/opt/gitlab/embedded/lib/gitlab-ce-warm/disable-gc.rb"|' "/opt/gitlab/sv/$service/run"; \
    grep -q disable-gc.rb "/opt/gitlab/sv/$service/run"; \
  done; \
  # Start Puma with one Bundler setup instead of bundle exec plus Bundler setup.
  sed -i 's|/opt/gitlab/embedded/bin/bundle exec puma |/opt/gitlab/embedded/bin/ruby -rbundler/setup /opt/gitlab/embedded/bin/puma |' /opt/gitlab/sv/puma/run; \
  grep -q -- '-rbundler/setup /opt/gitlab/embedded/bin/puma' /opt/gitlab/sv/puma/run; \
  rails=/opt/gitlab/embedded/service/gitlab-rails; \
  # The boot-time warmup request renders the HTML root page, which the API
  # tests never use.
  sed -i '/^warmup do |app|$/,/^end$/d' "$rails/config.ru"; \
  if grep -q warmup "$rails/config.ru"; then exit 1; fi; \
  # Google Cloud API clients are only used by Google Cloud integrations.
  sed -i -E "s/^(gem 'google-apis-[a-z0-9_]+', [^#]*), feature_category:/\\1, require: false, feature_category:/" "$rails/Gemfile"; \
  rm "$rails/config/initializers/google_api_client.rb" "$rails/config/initializers/httpclient_patch.rb"; \
  # Load internal event definitions and the emoji index on first use instead of
  # at boot. The definitions must stay: unknown events make requests fail.
  rm "$rails/config/initializers/internal_events.rb" "$rails/config/initializers/tanuki_emoji.rb"; \
  test "$(grep -c "^gem 'google-apis-.*require: false" "$rails/Gemfile")" -ge 10; \
  find "$rails/public/assets" -type f ! -name '*.json' -delete; \
  rm -rf "$rails/doc" "$rails/doc-locale" "$rails"/locale/*/; \
  cd /opt/gitlab/embedded/bin; \
  rm -f alertmanager consul cosign gitaly-backup gitaly-blackbox gitaly-debug \
    gitlab-elasticsearch-indexer gitlab-kas gitlab-pages gitlab-zip-cat \
    gitlab-zip-metadata node_exporter pgbouncer_exporter postgres_exporter \
    praefect prometheus redis-benchmark redis_exporter registry spamcheck \
    valkey-benchmark valkey-cli valkey-server; \
  rm -f go-crond; \
  rm -rf /opt/gitlab/embedded/lib/python3.12 /opt/gitlab/embedded/lib/libpython3.12.so*; \
  # SSH is disabled. Gitaly reads the gitlab-shell directory but not its binaries.
  rm -rf /opt/gitlab/embedded/service/gitlab-shell/bin; \
  # Precompiled gems ship native extensions for every Ruby version; keep only
  # the embedded Ruby's.
  ruby_version=$(/opt/gitlab/embedded/bin/ruby -e 'print RUBY_VERSION[/\A\d+\.\d+/]'); \
  find /opt/gitlab/embedded/lib/ruby/gems -depth -type d -regextype posix-extended \
    -regex '.*/[0-9]+\.[0-9]+' ! -name "$ruby_version" \
    -execdir test -d "$ruby_version" \; -exec rm -rf {} +; \
  gems=/opt/gitlab/embedded/lib/ruby/gems/3.3.0/gems; \
  rm -rf "$gems"/devfile-*/out "$gems"/elasticsearch-rails-*/lib/rails/templates; \
  rm -rf "$rails/changelogs" "$rails/CHANGELOG.md" "$rails"/public/-/graphql/introspection_result*.json; \
  # Frontend files. Rails only reads the asset manifests when rendering HTML.
  find "$rails/public/assets" -mindepth 1 -type f ! -path "$rails/public/assets/webpack/manifest.json" \
    \( -path "$rails/public/assets/*/*" -o ! -name '*.json' \) -delete; \
  rm -rf "$rails"/public/-/emojis "$rails"/public/-/speedscope "$rails"/public/-/pwa-icons \
    "$gems"/tanuki_emoji-*/app/assets; \
  # The database is already created, so schema dumps and migrations are unused.
  rm -rf "$rails"/db/*.sql "$rails"/db/*.sql.bundled "$rails"/db/schema_migrations \
    "$rails"/db/migrate "$rails"/db/post_migrate "$rails"/.rubocop_todo; \
  # Omnibus bundles several PostgreSQL versions; keep the one the data uses.
  pg_version=$(cat /var/opt/gitlab/postgresql/data/PG_VERSION); \
  test -x "/opt/gitlab/embedded/postgresql/$pg_version/bin/postgres"; \
  find /opt/gitlab/embedded/postgresql -mindepth 1 -maxdepth 1 ! -name "$pg_version" -exec rm -rf {} +; \
  # Gitaly runs the Git it embeds, not these standalone copies. NGINX is disabled.
  rm -f /opt/gitlab/embedded/bin/gitaly-git-* /opt/gitlab/embedded/sbin/nginx; \
  # Image uploads are out of scope: no EXIF stripping (exiftool needs Perl) or resizing.
  rm -rf /opt/gitlab/embedded/bin/exiftool /opt/gitlab/embedded/lib/exiftool-perl \
    /opt/gitlab/embedded/bin/gm /opt/gitlab/embedded/bin/gitlab-resize-image \
    /usr/bin/perl /usr/bin/perl5* /usr/lib/x86_64-linux-gnu/perl* /usr/lib/aarch64-linux-gnu/perl* \
    /usr/lib/*-linux-gnu/libperl.so* /usr/share/perl /usr/share/perl5; \
  # Unused by Gitaly, which runs its embedded Git, and by an API-only instance.
  rm -rf /opt/gitlab/embedded/libexec/git-core /opt/gitlab/embedded/share/terminfo \
    /opt/gitlab/embedded/share/locale /opt/gitlab/embedded/service/fast-stats \
    "$rails/vendor/project_templates" /usr/share/doc/*; \
  # Build leftovers in installed gems.
  find "$gems" -type f \( -name '*.c' -o -name '*.h' -o -name '*.hh' -o -name '*.cc' \
    -o -name '*.cpp' -o -name '*.o' -o -name '*.a' -o -name '*.rbs' \) -delete; \
  # Keep third-party notices, compressed.
  gzip -9f /opt/gitlab/LICENSE /opt/gitlab/dependency_licenses.json "$rails/rails-license.json"; \
  find /opt/gitlab/licenses /opt/gitlab/LICENSES -type f ! -name '*.gz' -exec gzip -9f {} +; \
  # Debug symbols and symbol tables are not needed to run.
  apt-get update -qq; \
  apt-get install -qq --no-install-recommends binutils >/dev/null; \
  find /opt/gitlab/embedded -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -size +100k \
    -exec sh -c 'head -c 4 "$1" | grep -q ELF && strip --strip-unneeded "$1"' _ {} \; ; \
  apt-get purge -qq --auto-remove binutils >/dev/null; \
  rm -rf /var/lib/apt/lists/* /var/lib/dpkg/info /var/cache/* /tmp/*

# Rebuild without the base image's declared volumes and deleted files. Similar
# sized layers let a pull extract one layer while it downloads the next.
FROM scratch AS warm
COPY --from=slim \
  --exclude=opt/gitlab/embedded/service \
  --exclude=opt/gitlab/embedded/bin \
  --exclude=opt/gitlab/embedded/lib/ruby/gems \
  --exclude=var/opt/gitlab \
  / /
COPY --from=slim /opt/gitlab/embedded/service /opt/gitlab/embedded/service
COPY --from=slim /opt/gitlab/embedded/bin /opt/gitlab/embedded/bin
COPY --from=slim /opt/gitlab/embedded/lib/ruby/gems /opt/gitlab/embedded/lib/ruby/gems
# The preseeded image rebuilds the Bootsnap cache from its own workload.
COPY --from=slim --exclude=gitlab-rails/tmp/cache/bootsnap /var/opt/gitlab /var/opt/gitlab
ENV PATH=/opt/gitlab/embedded/bin:/opt/gitlab/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 \
  TERM=xterm
LABEL org.opencontainers.image.source=https://github.com/jetersen/gitlab-ce-warm \
  org.opencontainers.image.description="Preconfigured GitLab CE for fast-starting API tests" \
  org.opencontainers.image.licenses=MIT
EXPOSE 8181
HEALTHCHECK --interval=2s --timeout=5s --start-period=10m \
  CMD curl --fail --silent 'http://127.0.0.1:8181/-/readiness?all=1' >/dev/null
ENTRYPOINT ["/usr/local/bin/gitlab-warm-start"]

# Preseeded variants add the state from scripts/capture-seed.sh, then drop
# what the seeded tests no longer need. Seeding creates commits, which needs
# Workhorse; the tests themselves only call JSON API endpoints, so Puma serves
# port 8181 directly. The seed's generated identifiers are in
# /etc/gitlab-ce-warm/seed.json.
FROM slim AS release-drafter-seeded
# Replace the Bootsnap cache and WAL instead of layering the seed's on top.
RUN rm -rf /var/opt/gitlab/gitlab-rails/tmp/cache/bootsnap \
  && find /var/opt/gitlab/postgresql/data/pg_wal -maxdepth 1 -type f -delete
ADD build/seeds/release-drafter.tar /
COPY build/seeds/release-drafter.json /etc/gitlab-ce-warm/seed.json
# The seeded merge request is already merged, so nothing needs Sidekiq.
RUN set -eu; \
  rm /opt/gitlab/service/sidekiq /opt/gitlab/service/gitlab-workhorse \
    /opt/gitlab/embedded/bin/gitlab-workhorse; \
  puma=/var/opt/gitlab/gitlab-rails/etc/puma.rb; \
  sed -i "s|^bind 'tcp://127.0.0.1:8080'\$|bind 'tcp://0.0.0.0:8181'|" "$puma"; \
  grep -q "^bind 'tcp://0.0.0.0:8181'\$" "$puma"

# The same layer split as warm, so seeded files are not stored twice.
FROM scratch AS release-drafter
COPY --from=release-drafter-seeded \
  --exclude=opt/gitlab/embedded/service \
  --exclude=opt/gitlab/embedded/bin \
  --exclude=opt/gitlab/embedded/lib/ruby/gems \
  --exclude=var/opt/gitlab \
  / /
COPY --from=release-drafter-seeded /opt/gitlab/embedded/service /opt/gitlab/embedded/service
COPY --from=release-drafter-seeded /opt/gitlab/embedded/bin /opt/gitlab/embedded/bin
COPY --from=release-drafter-seeded /opt/gitlab/embedded/lib/ruby/gems /opt/gitlab/embedded/lib/ruby/gems
COPY --from=release-drafter-seeded /var/opt/gitlab /var/opt/gitlab
ENV PATH=/opt/gitlab/embedded/bin:/opt/gitlab/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 \
  TERM=xterm
LABEL org.opencontainers.image.source=https://github.com/jetersen/gitlab-ce-warm \
  org.opencontainers.image.description="Preconfigured GitLab CE for fast-starting API tests" \
  org.opencontainers.image.licenses=MIT
EXPOSE 8181
HEALTHCHECK --interval=2s --timeout=5s --start-period=10m \
  CMD curl --fail --silent 'http://127.0.0.1:8181/-/readiness?all=1' >/dev/null
ENTRYPOINT ["/usr/local/bin/gitlab-warm-start"]
