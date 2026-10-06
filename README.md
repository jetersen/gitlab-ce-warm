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
- Compiled frontend assets, translations, and bundled documentation are
  removed. The web UI is not usable; the REST and GraphQL APIs are.
- Layers use zstd compression.

The container reports healthy once `/-/readiness?all=1` succeeds.

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
and saves the configured state to `build/state.tar`. The `Dockerfile` adds that
state to the base image, prunes unused files, and flattens the result.

```sh
scripts/capture-state.sh
docker buildx build --load --tag gitlab-ce-warm:test .
scripts/smoke-test.sh gitlab-ce-warm:test
```

The Build workflow builds `linux/amd64` and `linux/arm64` natively, runs the
smoke test, and publishes from `main`. Dependabot updates the base image.

GitLab CE is distributed under the MIT License by GitLab Inc. This repository
is not affiliated with GitLab Inc.
