# gitlab-ce-warm

GitLab CE images that start in seconds instead of minutes, for API tests and
CI fixtures.

The official `gitlab/gitlab-ce` image runs Omnibus reconfigure, creates the
database, and boots Rails with eager loading on every new container. These
images do that work once at build time and start the configured services
directly.

```sh
docker run --detach --publish 8181:8181 ghcr.io/jetersen/gitlab-ce-warm:19.1.3-ce.0
curl --header 'Private-Token: glpat-gitlab-ce-warm-root-token' http://localhost:8181/api/v4/user
```

Pin images by digest in automated tests.

## What is different

- Omnibus configuration, database schema, and seeds are already applied.
- The `root` user has a non-expiring personal access token,
  `glpat-gitlab-ce-warm-root-token`, with `api`, `read_repository`,
  `write_repository`, `sudo`, and `admin_mode` scopes.
- Workhorse listens on port 8181 without NGINX. GitLab URLs use
  `http://localhost:8181`.
- Rails loads classes on demand and reuses a prebuilt Bootsnap cache.
- KAS, Pages, the container registry, Prometheus and exporters, SSH, and
  Let's Encrypt are disabled or removed.
- Compiled frontend assets, emoji images, translations, and bundled
  documentation are removed. The web UI is not usable; the REST and GraphQL
  APIs are.
- Database migrations and schema dumps are removed because the database is
  already set up. GitLab's Rake tasks for migrations do not work.
- Image uploads are not supported: exiftool, Perl, and image resizing are
  removed. Other uploads work.
- Creating projects from built-in templates is not supported.
- SSH binaries, unused services, Git helper programs (Gitaly uses its embedded
  Git), native extensions for other Ruby versions, gem build leftovers, and
  debug symbols are removed. Third-party license notices are kept, compressed
  with gzip.
- Layers use zstd compression.

Removals were chosen by tracing which files a booted instance opens while
`scripts/api-exercise.sh` and an API conformance suite run. `scripts/smoke-test.sh`
runs that exercise against every build.

The container reports healthy once `/-/readiness?all=1` succeeds.

## Preseeded tags

Tags ending in `-release-drafter`, such as `19.1.3-ce.0-release-drafter`, also
contain the project that
[Release Drafter](https://github.com/release-drafter/release-drafter)'s forge
conformance suite tests against. `seeds/release-drafter.sh` creates it while the
image is built, so tests start without seeding. The generated commit SHAs, merge
request number, and timestamps are in `/etc/gitlab-ce-warm/seed.json`. The merge
request is already merged, so these tags work with
`GITLAB_DISABLED_SERVICES=sidekiq`.

## Configuration

`GITLAB_DISABLED_SERVICES` takes a space-separated list of runit services to
leave stopped. For example, `GITLAB_DISABLED_SERVICES=sidekiq` frees CPU for
Puma when a test does not depend on background jobs. Merge requests, for
example, need Sidekiq to merge.

Configuration in `/etc/gitlab/gitlab.rb` and `GITLAB_OMNIBUS_CONFIG` is not
applied at startup.

## Security

The root password is random and not published. The access token above is
public. Use these images only for disposable test instances that are not
reachable from untrusted networks.

## Building

`scripts/capture-state.sh` boots the base image named in the `Dockerfile` once
and saves the configured state to `build/state.tar`. The `warm` target adds that
state to the base image, prunes unused files, and flattens the result.
`scripts/capture-seed.sh` runs a seed script against a built image and saves
what it changed for the preseeded targets.

```sh
scripts/capture-state.sh
docker buildx build --load --target warm --tag gitlab-ce-warm:test .
scripts/smoke-test.sh gitlab-ce-warm:test
scripts/capture-seed.sh release-drafter gitlab-ce-warm:test
docker buildx build --load --target release-drafter --tag gitlab-ce-warm:release-drafter-test .
```

The Build workflow builds `linux/amd64` and `linux/arm64` natively, runs the
smoke test, and publishes from `main`. Dependabot updates the base image.

GitLab CE is distributed under the MIT License by GitLab Inc. This repository
is not affiliated with GitLab Inc.
