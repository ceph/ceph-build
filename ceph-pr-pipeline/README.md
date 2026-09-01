# ceph-pr-pipeline

One pipeline for all ceph.git PR checks, replacing the GitHub Pull Request
Builder plugin and six freestyle jobs.  ceph.git is cloned once and built once
(x86_64, with tests); the test legs run on separate builders from the shared
build tree.  The GitHub status contexts are unchanged, so branch protection
rules don't change.

| Status context | Replaces | How it runs now |
| --- | --- | --- |
| `Signed-off-by` | [ceph-pr-commits](../ceph-pr-commits/) | GitHub API only, no clone, seconds |
| `Unmodified Submodules` | [ceph-pr-submodules](../ceph-pr-submodules/) | GitHub API only, no clone, seconds |
| `make check` | [ceph-pull-requests](../ceph-pull-requests/) | shared build → ctest on its own builder |
| `ceph API tests` | [ceph-pr-api](../ceph-pr-api/) | shared build → API tests on its own builder |
| `ceph windows tests` | [ceph-windows-pull-requests](../ceph-windows-pull-requests/) | parallel leg, containerized builds + one Windows VM (see below) |
| `make check (arm64)` | [ceph-pull-requests-arm64](../ceph-pull-requests-arm64/) | parallel leg, build+test on one arm64 node |

## Flow

```
webhook (pull_request / issue_comment)
  └─ ceph-pr-pipeline-trigger         gating, cancellation, label handling
       └─ ceph-pr-pipeline
            prepare                   resolve PR, classify files, post pending statuses
            ├─ Signed-off-by          GitHub API
            ├─ Unmodified Submodules  GitHub API
            ├─ ceph windows tests     (noble+libvirt) container builds + Windows VM
            ├─ build and test (arm64) (arm64)  restore-or-build + tests
            └─ build and test
                 build ceph           (huge)  ONE clone, bwc -e buildtests, tree → S3
                 ├─ make check        tree ← S3, bwc -e tests
                 └─ ceph API tests    tree ← S3, run-backend-api-tests (in container)
```

- **Cache:** build trees are zstd-tarred to the Sepia LRC's RGW (the doli
  cluster) as `pr-builds/<PR>/<head sha>.<arch>.tar.zst`.  Re-runs for an
  unchanged head sha skip compilation (`FORCE_BUILD=true` overrides).
- **Statuses:** each leg posts its own context via the GitHub API.  Pending
  is posted from `prepare` before legs wait for executors; canceled/failed
  runs finalize any still-pending contexts.  Docs/container/gha-only PRs
  (plus qa-only for windows/arm64) report success without building.
- **Checkout time:** set `CEPH_REFERENCE_REPO` to a local ceph.git mirror on
  the builders to cut the remaining clones to seconds.

## The windows leg

Historically ([ceph-windows-pull-requests](../ceph-windows-pull-requests/))
this check provisioned three VMs per run: an Ubuntu VM to cross-compile
Ceph for Windows in, a second Ubuntu VM to build and host a vstart cluster,
and a Windows VM to run the tests — 114–177 minutes, most of it VM
provisioning and two from-scratch builds.  Now only the Windows client is a
VM (it loads the wnbd/Dokan kernel drivers; nothing but a real Windows
kernel can); both builds run in containers on the builder host with
persistent caches.  Measured: 79 min on a node with cold caches, ~60 warm.

Steps, in order (all scripts in [scripts/ceph-windows](../scripts/ceph-windows/)):

1. **Checkout**: ceph-build plus the PR merge ref, then submodules.
2. **Cross-compile** (`win32_build_container`): runs the PR's own
   `win32_build.sh` in a podman container built from
   `win32-build.containerfile` (just the mingw toolchain packages; podman's
   layer cache makes the image build a no-op after each builder's first
   run).  Produces
   `$WORKSPACE/ceph.zip`; the build tree is then removed so `do_cmake.sh`
   can run later.  Two per-builder caches under `~/.cache/ceph-win32-build/`:
   - `deps/<sha>`: the compiled mingw deps (mingw-llvm, boost, openssl,
     ...), keyed by the sha of the branch's `win32_deps_build.sh` +
     `mingw_conf.sh` + the containerfile, so a deps change in any branch
     just builds a new entry (flock-guarded); `win32_build.sh` skips the
     whole deps build when the cache's `completed` marker exists.
   - `ccache`: compiler cache for the tree itself.  Mount paths are fixed
     (`/workspace`, `/depscache`) so object paths stay stable across builds
     and nodes.  `MINGW_LLVM_DIR` must be exported into the container:
     `mingw_conf.sh` defaults it relative to the ceph tree, not `DEPS_DIR`.
3. **`setup_libvirt`**: ensures the libvirt default NAT network (virbr0,
   192.168.122.1) and the ssh helpers.
4. **`setup_libvirt_windows_vm`**: boots the pristine Windows Server 2019
   image as a QEMU/KVM guest on that network.
5. **`setup_ceph_vstart_container`**: compiles the PR's own source into
   the Ceph cluster the Windows client is tested against, and starts it.
   Nothing prebuilt is downloaded and no release is involved: bwc starts
   a container that has Ceph's build dependencies installed, mounts the
   same `$WORKSPACE/ceph` checkout (the PR merged onto its target
   branch) inside it, and runs `do_cmake.sh && ninja vstart` on it —
   `CMAKE_BUILD_TYPE=Release` just means an optimized compile of the
   PR's code.  Because both the client zip and the cluster come from
   this one checkout, a PR that changes mon/osd/mds behavior is tested
   on both sides of the wire, exactly like the VM flow was.  ccache is
   what makes the compile fast: a per-builder stash of object files from
   previous runs, so source files the PR didn't change are cache hits
   and only the PR's actual changes recompile (~5 min typical; ~10 min
   on a builder compiling for the first time).  vstart.sh then launches
   the daemons (mon/mgr/osd/mds) inside a second, long-lived container
   named `ceph_build`.  That container shares the host's network
   (`--net=host`) and the daemons bind 192.168.122.1 — the builder's own
   address on the libvirt NAT bridge — which is an address the Windows
   VM can reach, so the client talks to the cluster like it would any
   remote one.  The leg waits (bounded) for a READY marker the vstart
   script drops once pools are set up, and fails immediately if the
   cluster container dies instead.  Two vstart behaviors worth knowing:
   - vstart writes `mds root ino uid/gid = $(id -u/-g)` into the MDS conf,
     and the Windows client mounts with `client_mount_uid/gid = 1000` and
     `client_permissions = true` — the cluster must be started by uid 1000
     (as the VM's ubuntu user silently always did) or every cephfs write
     from the client gets EACCES.
   - vstart writes outside its data dir: `logrotate.conf`/`.state` in the
     build dir and `vstart_environment.sh` next to itself in src.  The
     vstart user owns the build dir wholesale plus that one src file; the
     host-side conf/keyring/log extraction goes through `podman cp`/`podman
     exec` because those files are subuid-owned on the host.
6. **`run_tests`**: uploads `ceph.zip` + conf/keyring to the Windows VM,
   runs `run_tests.ps1` and the qa/workunits/windows suite.  With
   `VSTART_CONTAINER` set, its cluster-side diagnostics use `podman exec`
   and local log copies; unset, the old ssh-into-the-VM behavior is
   unchanged (the old freestyle job shares this script).
7. **Cleanup** (post): remove both containers, destroy the VM, wipe the
   workspace.

The leg needs `installed-os-noble` builders: the container builds need a
modern podman, and on jammy `setup_container_runtime.sh` can only provide
docker.  The `ceph-windows-container-build` job runs step 2 standalone for
validation or one-off manual windows builds.

## Gating

- PR author with write/admin on ceph/ceph (the same check as ceph.git's
  `author-ci-perms.yml` workflow, which labels/comments on such PRs): CI
  runs automatically.
- Otherwise: all applicable contexts wait as pending until a Ceph developer
  adds the `ci-approved` label (which also clears `needs-ci-approval`).  **Every push removes the label**, cancels running
  builds, and resets statuses — it must be re-added for the new code.
- Comment phrases (org members always, others only while labeled):
  `jenkins retest ...` re-runs everything; `jenkins test <check>` runs one of
  `make check`, `make check arm64`, `api`, `windows`, `signed`, `submodules`.
  Bare `jenkins test` runs nothing.

## Rollout

1. Credentials: `pr-check-trigger-token`, `github-status-check-token`
   (repo:status + issues write + org read), `github-readonly-token`,
   `dgalloway-docker-hub`, `doli-lrc-pr-builds` (RGW keys for the
   `ceph-pr-builds` user on the doli LRC), `ceph_win_ci_private_key`.
2. Deploy both jobs with JJB, then pre-approve the sandbox signatures in
   Manage Jenkins → Script Console:

   ```groovy
   import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval
   [
     'method org.jenkinsci.plugins.workflow.support.steps.build.RunWrapper getRawBuild',
     'method hudson.model.Run getParent',
     'method hudson.model.Job getBuilds',
     'method jenkins.model.HistoricalBuild getNumber',
     'method jenkins.model.HistoricalBuild isBuilding',
     'method hudson.model.Actionable getAction java.lang.Class',
     'method hudson.model.ParametersAction getParameter java.lang.String',
     'method hudson.model.StringParameterValue getValue',
     'method hudson.model.Run getExecutor',
     'method hudson.model.Executor interrupt hudson.model.Result',
     'staticField hudson.model.Result ABORTED',
     'staticMethod jenkins.model.Jenkins get',
     'method jenkins.model.Jenkins getItemByFullName java.lang.String',
   ].each { ScriptApproval.get().approveSignature(it) }
   ```

   (If a run reports a differently-resolved signature, approve exactly what
   it prints at In-process Script Approval.)
3. Test side by side: run `ceph-pr-pipeline` manually with a PR number and
   `STATUS_PREFIX=pipeline/` so required contexts are untouched.
4. Add the webhook:
   `https://jenkins.ceph.com/generic-webhook-trigger/invoke?token=<pr-check-trigger-token value>`
   for `pull_request` + `issue_comment`, content type `application/json`.
5. Flip: disable the GHPRB triggers on the six old jobs, drop `STATUS_PREFIX`.
6. The cache lives in the dedicated `ceph-pr-builds` bucket on the doli
   LRC's RGW (any `doli0N.front.sepia.ceph.com:8080` endpoint; the legs
   pick the first one that answers).  The bucket-wide 21-day expiry
   lifecycle rule and a 20T quota on the `ceph-pr-builds` RGW user live
   server-side.  Optionally seed reference mirrors for
   `CEPH_REFERENCE_REPO`.

## Known gaps

- API tests now run inside the build container (was: bare noble host);
  validate on a real PR before the flip.
- Dashboard-frontend cobertura publishing is not wired up yet.
- A hard kill (double abort) skips `post{}`, so statuses stay pending.
- `build-with-container.py` names its container `ceph_build`: one leg per
  builder at a time (true today with single-executor builders).
