# gitlab-ce-warm

GitLab CE images built for one job: starting a disposable GitLab for
[Release Drafter](https://github.com/release-drafter/release-drafter)'s forge
conformance tests as fast as possible. They are not meant for anything else.

```sh
docker run --detach --publish 8181:8181 ghcr.io/jetersen/gitlab-ce-warm:19.1.3-ce.0-release-drafter
curl --header 'Private-Token: glpat-gitlab-ce-warm-root-token' http://localhost:8181/api/v4/user
```

Pin the image by digest. The `root` user's access token above is public.

## How it is fast

- Omnibus reconfigure, database setup, and the test project's seed run at build
  time. The container starts the runit services directly.
- Rails loads classes on demand, reuses a prebuilt Bootsnap cache, reads a
  prebuilt schema cache, and skips partition sync and metrics setup at boot.
- Puma and Sidekiq never run garbage collection. Puma uses about 2 GB.
- `patches/` caches Mustermann's translator lookup and URI-encoded characters,
  which compiles the API routes on the first request about a third faster. This
  is proposed upstream in gitlab-org/gitlab!260179.
- Sidekiq does not start; the seeded merge request is already merged.
- Puma serves port 8181 without Workhorse. Seeding uses Workhorse, but the
  tests only call JSON API endpoints, so Git over HTTP, uploads, archive
  downloads, and file or commit creation through the API do not work.
- The Bootsnap cache only holds what the seed and its read requests load.
- Files the API does not open are removed, including the frontend, docs,
  migrations, image upload tooling, SSH, and debug symbols. The web UI, image
  uploads, and project templates do not work.
- Layers are zstd compressed and split for parallel pulls, and seeded files
  are not stored twice.

The generated commit SHAs, merge request number, and timestamps of the seed are
in `/etc/gitlab-ce-warm/seed.json`.

## Building

```sh
scripts/capture-state.sh
docker buildx build --load --target warm --tag gitlab-ce-warm:test .
scripts/smoke-test.sh gitlab-ce-warm:test
scripts/capture-seed.sh release-drafter gitlab-ce-warm:test
docker buildx build --load --target release-drafter --tag gitlab-ce-warm:release-drafter-test .
```

`capture-state.sh` boots the base image named in the `Dockerfile` and saves the
configured state. `capture-seed.sh` runs `seeds/release-drafter.sh` against the
`warm` image and saves what it changed. `smoke-test.sh` runs
`scripts/api-exercise.sh`, which also guided which files could be removed.

The Build workflow builds `linux/amd64` and `linux/arm64` natively, runs the
smoke tests, and publishes from `main`. Dependabot updates the base image.

## Mirrors

The Mirror workflow copies images listed in `mirrors/*/Dockerfile` to GHCR
without changes, keeping the upstream digest, because GitHub-hosted runners pull
from GHCR faster.

| Mirror | Upstream |
| --- | --- |
| `ghcr.io/jetersen/forgejo` | `data.forgejo.org/forgejo/forgejo` |

GitLab CE is distributed under the MIT License by GitLab Inc. This repository
is not affiliated with GitLab Inc.
