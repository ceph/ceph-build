#!/bin/bash
#
# ceph-build library script for performing build tasks using the
# build-with-container.py tool from the ceph/ceph repo.
#

# bwc - Run a build-with-container.py based build task.
# Arguments:
#   $1 - timeout value in hours
#   Remaining args passed to BWC command
# Variables:
#   DISTRO_BASE - if set, use DISTRO_BASE to select bwc distro
#                 argument. Defaults to "jammy"
#   GIT_BRANCH - Pass the current branch name to BWC in order
#                to generate a container tag. Defaults to "main"
#   NPMCACHE - Path to shared npm cache directory.
#   SCCACHE_DIR - Host directory for the compiler cache.  Defaults to
#                 ~/.cache/ceph-sccache; set it empty to disable caching.
#   SCCACHE_CACHE_SIZE - Cap for that directory.  Defaults to 40G.
bwc() {
    # specify timeout in hours for $1
    local timeout=$(($1*60*60))
    shift
    local current_branch=${GIT_BRANCH:-main}
    current_branch=${current_branch//\//-}
    local args=()
    if [ "${NPMCACHE}" ]; then
        args+=(--npm-cache-path="${NPMCACHE}")
    fi
    # The bwc images ship sccache and ceph's do_cmake.sh prefers it over
    # ccache ("if type sccache ... elif type ccache"), but nothing pointed
    # it at a directory outliving the container, so every build compiled
    # from scratch into a cache that was thrown away with the container --
    # ceph-pr-pipeline run 1202 logged "Building with sccache ... SCCACHE_CONF="
    # and then 33m45s of full compile.  Give it a per-builder directory.
    local sccache_dir="${SCCACHE_DIR-${HOME}/.cache/ceph-sccache}"
    if [ "${sccache_dir}" ]; then
        mkdir -p "${sccache_dir}"
        args+=("--extra=--volume=${sccache_dir}:/sccache:z")
        args+=("--extra=-eSCCACHE_DIR=/sccache")
        args+=("--extra=-eSCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE:-40G}")
    fi
    local seccomp
    seccomp=$(bwc_seccomp_profile)
    if [ "${seccomp}" ]; then
        args+=(--extra="${seccomp}")
    fi
    args+=("${@}")
    timeout "${timeout}" ./src/script/build-with-container.py \
        -d "${DISTRO_BASE:-jammy}" \
        --env-file="${PWD}/.env" \
        --current-branch="${current_branch}" \
        -t"+$(bwc_arch)" \
        "${args[@]}"
}

# bwc_seccomp_profile - Print a --security-opt argument holding the host's
#   seccomp profile minus io_pgetevents. libaio 0.3.113 (ubuntu 24.04+) only
#   falls back to io_getevents when io_pgetevents returns ENOSYS, and the
#   default profile denies it with EPERM, which aborts every bluestore test.
# Arguments: (none)
# Variables:
#   WORKSPACE - Path to write the generated profile to.
# Output: --security-opt argument, or nothing
bwc_seccomp_profile() {
    local src dest
    # this only applies to podman
    command -v podman > /dev/null || return 0
    # get the host's seccomp profile
    src=$(podman info --format '{{.Host.Security.SECCOMPProfilePath}}' 2>/dev/null)
    # if there isn't one, skip this
    [ -r "${src}" ] || return 0
    # a denied syscall has to come back as ENOSYS (38) for libaio to fall back
    [ "$(jq -r '.defaultErrnoRet' "${src}")" = "38" ] || return 0
    # make a temporary replacement seccomp profile
    dest="${WORKSPACE:-$(mktemp -d)}/seccomp-ceph.json"
    # drop io_pgetevents from the deny lists, and any list it empties
    jq '.syscalls |= [.[]
          | if .action != "SCMP_ACT_ALLOW"
            then .names |= map(select(startswith("io_pgetevents") | not))
            else . end
          | select(.names | length > 0)]' "${src}" > "${dest}" || return 0
    echo "--security-opt=seccomp=${dest}"
}

# bwc_populate_npm_cache - Configure the ceph sources and try to install
#   the dashboard fontend dependencies. This exists because we had some
#   issues getting npm to run reliably in the past.
# Arguments: (none)
# Variables:
#   NPMCACHE - Path to shared npm cache directory.
# Output: Status string
bwc_populate_npm_cache() {
    if [ -z "${NPMCACHE}" ]; then
        return 0
    fi
    # show npm cache info before trying to install dashboard deps
    npm_cache_info
    bwc 1 -e configure
    # try to pre-load the npm cache so that it doesn't fail during the normal build
    # step
    for i in {0..5}; do
        bwc 1 -e custom -- \
            cmake --build build -t mgr-dashboard-frontend-deps && break
        echo "Warning: Attempt $((i+1)) to cache npm packages failed."
        sleep $((10 + 30 * i))
    done
    # show npm cache info after trying to install dashboard deps
    npm_cache_info
}

# npm_cache_info - Print the size of the NPMCACHE directory.
# Arguments: (none)
# Variables:
#   NPMCACHE - Path to shared npm cache directory.
# Output: Status string
npm_cache_info() {
    if [ -z "${NPMCACHE}" ]; then
        return 0
    fi
    echo '===== npm cache info ======='
    du -sh "${NPMCACHE}" || echo "${NPMCACHE} not present"
    echo '============================'
}

# bwc_login - Log into registries
# Arguments: (none)
# Variables:
#   DOCKER_HUB_USERNAME - Path to shared npm cache directory.
#   DOCKER_HUB_PASSWORD - Path to shared npm cache directory.
bwc_login() {
    if [ -z "${DOCKER_HUB_USERNAME}" ] || [ -z "${DOCKER_HUB_PASSWORD}" ]; then
        return 0
    fi
    # Same-shell export so login and all later podman calls share one
    # persistent authfile: https://tracker.ceph.com/issues/77920
    export REGISTRY_AUTH_FILE="${HOME}/.config/containers/auth.json"
    mkdir -p "${REGISTRY_AUTH_FILE%/*}"
    podman login -u "${DOCKER_HUB_USERNAME}" -p "${DOCKER_HUB_PASSWORD}" docker.io
}

# bwc_arch - Print the architecture of the current host in the style
# common for containers (Go-style).
# Arguments: (none)
# Variables: (none)
# Output: Architecture string
bwc_arch() {
    local myarch
    myarch=$(uname -m)
    case "${myarch}" in
        x86_64) echo amd64 ;;
        aarch64) echo arm64 ;;
        *) echo "${myarch}" ;;
    esac
}

# vim: ts=4 sw=4 expandtab
