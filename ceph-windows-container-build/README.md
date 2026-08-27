# ceph-windows-container-build

Builds Ceph for Windows (ceph.git's `win32_build.sh`) inside a podman
container on the builder host, via
`scripts/ceph-windows/win32_build_container`, instead of the throwaway
libvirt Ubuntu VM the windows CI used historically.  Produces the same
`ceph.zip` that `setup_libvirt_windows_vm`/`run_tests` consume.

Two host-side caches make repeat builds fast:

- **deps** (`~/.cache/ceph-win32-build/deps/<hash>`): the compiled mingw
  dependencies (mingw-llvm, boost, openssl, ...), keyed by the sha of the
  branch's `win32_deps_build.sh` + `mingw_conf.sh` + the containerfile.
  `win32_build.sh` skips the whole deps build when the cache's `completed`
  marker is present.
- **ccache** (`~/.cache/ceph-win32-build/ccache`): compiler cache for the
  ceph tree itself.  Container mount paths are fixed so object paths are
  stable across builds.

This job is the testbed for moving ceph-pr-pipeline's windows leg off VMs;
it is also usable for one-off manual windows builds of a branch or PR
(set `CEPH_BRANCH` or `ghprbPullId`).
