#!/bin/bash

# Push a locally built Ceph dev container image to the Pulp container registry.
#
# Intended to run after scripts/build_container (container/build.sh) when
# REMOVE_LOCAL_IMAGES=false so the Quay-tagged image is still on the builder.
#
# Required environment variables:
#   WORKSPACE                  - Jenkins workspace root
#   SHA1                       - Git commit SHA for this build
#   BRANCH                     - Ceph branch name
#   ARCH                       - Build architecture (x86_64 or arm64)
#   FLAVOR                     - Build flavor (default or debug)
#   CONTAINER_REPO_HOSTNAME    - Source registry host (e.g. quay.ceph.io)
#   CONTAINER_REPO_ORGANIZATION - Source registry org (e.g. ceph-ci)
#   PULP_USERNAME              - Pulp registry username
#   PULP_PASSWORD              - Pulp registry password

set -ex

: "${SHA1:?SHA1 is required}"
: "${BRANCH:?BRANCH is required}"
: "${ARCH:?ARCH is required}"
: "${FLAVOR:?FLAVOR is required}"
: "${CONTAINER_REPO_HOSTNAME:?CONTAINER_REPO_HOSTNAME is required}"
: "${CONTAINER_REPO_ORGANIZATION:?CONTAINER_REPO_ORGANIZATION is required}"
: "${PULP_USERNAME:?PULP_USERNAME is required}"
: "${PULP_PASSWORD:?PULP_PASSWORD is required}"

PULP_SERVER_URL="${PULP_SERVER_URL:-https://pulp.front.sepia.ceph.com}"
PULP_REGISTRY_BASE_PATH="${PULP_REGISTRY_BASE_PATH:-ceph-ci}"
PULP_PROJECT="${PULP_PROJECT:-ceph}"
PULP_REGISTRY_TLS_VERIFY="${PULP_REGISTRY_TLS_VERIFY:-true}"

# Strip scheme from a registry URL for podman image references.
registry_host_from_url() {
    local url="${1%/}"
    url="${url#https://}"
    url="${url#http://}"
    printf '%s\n' "$url"
}

# Find the local dev container image produced by container/build.sh.
# build.sh tags quay.ceph.io/ceph-ci/ceph with SHA1 (and optional suffixes).
find_local_container_image() {
    local repo_path="${CONTAINER_REPO_HOSTNAME}/${CONTAINER_REPO_ORGANIZATION}/ceph"
    local image

    image="$(
        podman images --format '{{.Repository}}:{{.Tag}}' \
            | grep "^${repo_path}:" \
            | grep "${SHA1}" \
            | head -1 \
            || true
    )"
    if [ -n "$image" ]; then
        printf '%s\n' "$image"
        return 0
    fi

    echo "ERROR: No local container image found for ${repo_path}:*${SHA1}*" >&2
    echo "Ensure REMOVE_LOCAL_IMAGES=false when running build_container" >&2
    podman images --format '{{.Repository}}:{{.Tag}}' \
        | grep "${CONTAINER_REPO_ORGANIZATION}/ceph" >&2 || true
    return 1
}

SOURCE_IMAGE="$(find_local_container_image)"
echo "Source image: ${SOURCE_IMAGE}" >&2

PULP_REGISTRY_HOST="$(registry_host_from_url "$PULP_SERVER_URL")"
IMAGE_ARCH="$(podman inspect --format '{{.Architecture}}' "$SOURCE_IMAGE")"
IMAGE_TAG="${SHA1}-${IMAGE_ARCH}"
DEST_IMAGE="${PULP_REGISTRY_HOST}/${PULP_REGISTRY_BASE_PATH}/${PULP_PROJECT}:${IMAGE_TAG}"

echo "Logging in to ${PULP_SERVER_URL}" >&2
podman login --tls-verify="${PULP_REGISTRY_TLS_VERIFY}" \
    -u "${PULP_USERNAME}" -p "${PULP_PASSWORD}" "${PULP_SERVER_URL}"

echo "Tagging ${SOURCE_IMAGE} -> ${DEST_IMAGE}" >&2
podman tag "${SOURCE_IMAGE}" "${DEST_IMAGE}"

echo "Pushing ${DEST_IMAGE}" >&2
podman push --tls-verify="${PULP_REGISTRY_TLS_VERIFY}" "${DEST_IMAGE}"

echo "Pulp container push completed: ${DEST_IMAGE} (branch=${BRANCH}, flavor=${FLAVOR}, arch=${ARCH})" >&2
