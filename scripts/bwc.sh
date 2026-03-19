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
bwc() {
    # TODO: enable (read-only?) sccache support
    # specify timeout in hours for $1
    local timeout=$(($1*60*60))
    shift
    local current_branch=${GIT_BRANCH:-main}
    current_branch=${current_branch//\//-}
    local args=()
    if [ "${NPMCACHE}" ]; then
        args+=(--npm-cache-path="${NPMCACHE}")
    fi
    args+=("${@}")
    timeout "${timeout}" ./src/script/build-with-container.py \
        -d "${DISTRO_BASE:-jammy}" \
        --env-file="${PWD}/.env" \
        --current-branch="${current_branch}" \
        -t"+$(bwc_arch)" \
        "${args[@]}"
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
