# ceph-dev-pipeline

Declarative Jenkins pipeline that builds Ceph dev packages (and dev container
images) for a branch+sha1 across a distro/arch/flavor matrix, then uploads them
to Chacra and/or Pulp and reports status to Shaman.

- Job definition: [ceph-dev-pipeline.yml](config/definitions/ceph-dev-pipeline.yml) (JJB)
- Pipeline: [Jenkinsfile](build/Jenkinsfile), fetched by Jenkins from
  `ceph/ceph-build` at `$CEPH_BUILD_BRANCH` (lightweight checkout, wiped workspace)
- Triggered manually, or by [ceph-dev-pipeline-trigger](../ceph-dev-pipeline-trigger/build/Jenkinsfile),
  which turns git commit trailers (`Ci-Compile: ...`, `Distros: ...`, etc.) on a
  ceph-ci push into job parameters.

## Flow

1. **source distribution** — triggers `$SETUP_JOB` (`ceph-source-dist`) unless
   `SETUP_BUILD_ID` is given; produces `dist/ceph-$VERSION.tar.bz2`, `dist/sha1`,
   `dist/version`, `dist/other_envvars`.
2. **parallel build** (matrix) — axes `DIST` × `ARCH` × `FLAVOR`, filtered by the
   `DISTROS`/`ARCHS`/`FLAVORS` parameters. `debug` flavor only on
   centos9/rocky10/noble + x86_64. Each cell runs on a node labeled
   `(installed-os-centos9||installed-os-noble)&&$ARCH&&gigantic` — i.e. the
   *host* is CentOS 9 or Ubuntu Noble regardless of the target distro; all
   distro-specific work happens inside containers.
   1. **node** — `scripts/setup_container_runtime.sh` (installs/repairs rootless podman).
   2. **checkout ceph-build** — clones `ceph/ceph-build@$CEPH_BUILD_BRANCH` into the workspace.
   3. **copy artifacts** — `copyArtifacts` from the setup job, verifies `SHA1`,
      sets `VERSION`, and untars a subset of the tarball into `dist/ceph/`.
   4. **check for built packages** — asks Shaman (chacra) and Pulp whether this
      build already exists; if every enabled backend has it, compilation is
      skipped (override with `FORCE=true` or `THROWAWAY=true`).
   5. **builder container** — see below.
   6. **build** — `build-with-container.py ... -e rpm|debs`, then extracts `cephadm`.
   7. **upload packages** — `chacra_upload.sh` / `pulp_upload.sh`, plus a
      generated `ceph-release` RPM pointing at the repo URL; Shaman status is
      updated started/completed/failed.
   8. **container** / **registry upload** — builds the Ceph dev container image
      (centos9, rocky10 only) and optionally mirrors it to the Pulp registry.

## Where scripts come from

Two independent sources, both living in the cell's workspace:

| Path | Origin | Contents |
| --- | --- | --- |
| `./scripts/` | `ceph/ceph-build` clone (stage "checkout ceph-build") | [setup_container_runtime.sh](../scripts/setup_container_runtime.sh), [setup_pulp.sh](../scripts/setup_pulp.sh), [setup_chacractl.sh](../scripts/setup_chacractl.sh), [chacra_upload.sh](../scripts/chacra_upload.sh), [pulp_upload.sh](../scripts/pulp_upload.sh), [notify_shaman_pulp_repo.sh](../scripts/notify_shaman_pulp_repo.sh), [update_shaman.sh](../scripts/update_shaman.sh), [build_container](../scripts/build_container), [pulp_container_push.sh](../scripts/pulp_container_push.sh) |
| `./dist/ceph/` | extracted from the ceph source tarball built by `ceph-source-dist` | `src/script/build-with-container.py`, `Dockerfile.build`, `install-deps.sh`, `ceph.spec.in`, `debian/`, `container/`, `make-*.sh` |

Important consequence: everything that runs *inside* the build container comes
from the **tarball of the branch being built**, not from a git checkout —
so `build-with-container.py` and `Dockerfile.build` are whatever that branch has.

## The builder container

Built and run by `python3 src/script/build-with-container.py` (from
`dist/ceph/`) with `--image-variant=packages -d $DIST`.

- **Containerfile**: `Dockerfile.build` at the root of the ceph source tree.
- **Base OS image**: `Dockerfile.build` is `FROM $DISTRO`, where `DISTRO` is a
  `--build-arg` set by `build-with-container.py` from its `DefaultImage` map
  (overridable with `--base-image`):

  | `-d` value | base image |
  | --- | --- |
  | centos9 | `quay.io/centos/centos:stream9` |
  | centos10 | `quay.io/centos/centos:stream10` |
  | rocky9 | `docker.io/rockylinux/rockylinux:9` |
  | rocky10 | `docker.io/rockylinux/rockylinux:10` |
  | focal / jammy / noble | `docker.io/ubuntu:20.04` / `22.04` / `24.04` |
  | bookworm / trixie | `docker.io/debian:bookworm` / `docker.io/debian:trixie` |

- **Provisioning**: `src/script/buildcontainer-setup.sh` (which runs
  `install-deps.sh`) plus an sccache install. `--image-variant=packages` skips
  test deps; crimson deps are included unless the branch is tentacle/squid/reef
  (`WITH_CRIMSON` in `$WORKSPACE/.env`).
- **Image name/tags**: `$CONTAINER_REPO_HOSTNAME/$CONTAINER_REPO_ORGANIZATION/ceph-build`
  (default `quay.ceph.io/ceph-ci/ceph-build`), tagged
  `<sha1[0:7]>.<BRANCH>.<DIST>.<ARCH>.<FLAVOR>` and `<BRANCH>.<DIST>.<ARCH>.<FLAVOR>`.
  The pipeline tries `podman pull` of both tags first so unchanged builder images
  are reused; both tags are pushed after the build.
- **Build execution**: `dist/ceph/` is bind-mounted at `/ceph` inside the
  container (`--homedir`, default `/ceph`), so `rpmbuild`/`make-debs` output
  lands back in the workspace at `dist/ceph/rpmbuild/` or `dist/ceph/debs/`.
- **Registry auth**: `REGISTRY_AUTH_FILE=$HOME/.config/containers/auth.json` is
  exported so podman login/build/push and `build-with-container.py` all share
  one authfile (agents run as a systemd service with no `XDG_RUNTIME_DIR`;
  without this the base-image pull goes anonymous and hits Docker Hub rate limits).

### Not the same as the Ceph dev container image

The "container" stage builds the *runtime* Ceph image via
[scripts/build_container](../scripts/build_container) → `dist/ceph/container/build.sh`
(`container/Containerfile`). It waits for a ready Shaman repo for this sha1, then
builds `FROM_IMAGE` = `quay.io/centos/centos:stream9` (centos9) or
`docker.io/rockylinux/rockylinux:10` (rocky10), installing the just-uploaded
packages.

## History: why `SETUP_JOB` exists

The pipeline does everything inside containers driven by
`src/script/build-with-container.py`, which comes from the ceph source tree
itself. That script only landed in ceph.git in Aug 2024 and was not backported
to reef until Feb 2025 (ceph#61683). Until then, **reef branches could not be
built by ceph-dev-pipeline at all** and had to go through the older pair of
freestyle jobs:

- [ceph-dev-new-setup](../ceph-dev-new-setup/) — creates the source distribution
- [ceph-dev-new](../ceph-dev-new/) — compiles and packages it

So [ceph-trigger-build](../ceph-trigger-build/README.md) routes on the
`CEPH-BUILD-JOB` git trailer: `ceph-dev-pipeline` (the default, which in turn
uses `ceph-source-dist` for the source distribution) or `ceph-dev-new` (the
legacy pair, fed by `ceph-dev-new-setup`). The legacy branch of that routing is
skipped when the `ceph-dev-new-trigger` job is itself enabled, so pushes don't
get built twice.

`SETUP_JOB` is the residue of that split *inside* the pipeline: ceph-dev-pipeline
originally used `ceph-dev-new-setup` as its stage-1 source distribution, and
`ceph-source-dist` became the default in commit `6e1f7376` (2025-04-14) with
`ceph-dev-new-setup` kept as a selectable option. The two are interchangeable
because both archive the same `dist/**` layout the "copy artifacts" stage expects
(`dist/sha1`, `dist/version`, `dist/other_envvars`, `dist/ceph-*.tar.bz2`).

## Key parameters

| Parameter | Default | Effect |
| --- | --- | --- |
| `BRANCH` / `SHA1` / `CEPH_REPO` | `main` / — / `ceph-ci` | what to build |
| `DISTROS` / `ARCHS` / `FLAVORS` | `centos9 noble jammy` / `x86_64 arm64` / `default` | matrix filter |
| `CI_COMPILE` / `CI_CONTAINER` | `true` / `true` | compile packages / build container images |
| `CHACRA_UPLOAD` / `PULP_UPLOAD` / `PULP_REGISTRY_UPLOAD` | `true` / `false` / `false` | upload backends |
| `THROWAWAY` | `false` | build but upload nothing (also skips existence checks) |
| `FORCE` | `false` | compile and re-upload even if artifacts already exist |
| `SCCACHE` / `DWZ` | `true` / `false` | sccache (S3 bucket `ceph-sccache`) / dwz debuginfo shrinking |
| `SETUP_JOB` / `SETUP_BUILD_ID` | `ceph-source-dist` / — | which job produces the source distribution (see [History](#history-why-setup_job-exists)) / reuse an existing one |
| `CEPH_BUILD_BRANCH` | `main` | which ceph-build branch supplies the Jenkinsfile and `scripts/` |
