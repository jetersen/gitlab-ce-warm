# syntax=docker/dockerfile:1

# Dependabot updates this tag and digest. scripts/capture-state.sh reads it too.
FROM gitlab/gitlab-ce:19.1.3-ce.0@sha256:d160bc91d3a112fdcaead0ecd76076e3371677c1314f266d9c26b5c3d3363db1 AS base

FROM base AS slim
# Configured Omnibus state captured from the same base image by
# scripts/capture-state.sh. It replaces the first-start reconfigure.
ADD build/state.tar /
COPY scripts/start.sh /usr/local/bin/gitlab-warm-start
# Drop what an API-only test instance never loads: compiled frontend assets,
# translations, bundled documentation, and binaries for disabled services.
RUN set -eux; \
  rails=/opt/gitlab/embedded/service/gitlab-rails; \
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
COPY --from=slim /var/opt/gitlab /var/opt/gitlab
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

# Preseeded variants add the state from scripts/capture-seed.sh. The seed's
# generated identifiers are in /etc/gitlab-ce-warm/seed.json.
FROM warm AS release-drafter
ADD build/seeds/release-drafter.tar /
COPY build/seeds/release-drafter.json /etc/gitlab-ce-warm/seed.json
