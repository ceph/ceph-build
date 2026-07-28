#!/bin/bash
set -euxo pipefail

: "${WORKSPACE:?}"
: "${OSD_FLAVOR:?}"
: "${CHECK_APP_ID:?}"
: "${CHECK_INSTALL_ID:?}"
: "${CHECK_NAME:?}"
: "${CHECK_REPO_OWNER:?}"
: "${CHECK_REPO_NAME:?}"

cd "${WORKSPACE}/cbt"
. /etc/os-release || ID=ubuntu
case $ID in
debian|ubuntu)
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3-yaml python3-lxml python3-prettytable python3-matplotlib cython3 git
    ;;
centos|rhel|rocky|almalinux)
    sudo dnf copr remove tchaikov/llvm-toolset-10 || true
    sudo dnf module enable -y llvm-toolset || true
    sudo dnf install -y llvm-toolset || true
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager --set-enabled crb 2>/dev/null || \
      sudo dnf config-manager --set-enabled powertools 2>/dev/null || \
      sudo dnf config-manager --set-enabled PowerTools 2>/dev/null || true
    if ! rpm -q epel-release >/dev/null 2>&1; then
        major=${VERSION_ID%%.*}
        sudo dnf install -y epel-release || \
          sudo dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm"
    fi
    sudo dnf install -y python3-pyyaml python3-lxml python3-prettytable \
      python3-matplotlib python3-cython git
    sudo dnf update -y libarchive || true
    gcc_toolset_ver=13
    if test -d /opt/rh/gcc-toolset-${gcc_toolset_ver}/root/lib/gcc/x86_64-redhat-linux/${gcc_toolset_ver}; then
        sudo ln -sf /opt/rh/gcc-toolset-${gcc_toolset_ver}/root/lib/gcc/x86_64-redhat-linux/${gcc_toolset_ver} \
                    /usr/lib/gcc/x86_64-redhat-linux/${gcc_toolset_ver}
    fi
    ;;
fedora)
    sudo yum install -y python3-pyyaml python3-lxml python3-prettytable \
      python3-matplotlib python3-cython clang git
    ;;
*)
    echo "unknown distro: $ID"
    exit 1
    ;;
esac

kill_cluster_procs
# Previous build may have left SeaStore devices dirty.
wipe_seastore_devs

mkdir -p "${WORKSPACE}/perf-workloads"
rm -rf "${WORKSPACE}/seastore-imgs"
rm -f "${WORKSPACE}/perf-workloads"/*.yaml \
      "${WORKSPACE}/run-cbt-seastore.sh" \
      "${WORKSPACE}/seastore-devs.txt" \
      "${WORKSPACE}/prepare-workloads.py"
: > "${WORKSPACE}/seastore-devs.txt"
