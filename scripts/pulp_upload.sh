#!/bin/bash

# Upload Ceph build artifacts to a Pulp repository and publish distributions.

# Intended for CI jobs after package builds complete. Discovers RPM or DEB
# packages under WORKSPACE/dist/ceph, uploads them to Pulp, attaches the
# uploaded content to per-arch repositories, and creates publications and
# distributions with metadata labels for Shaman discovery.

# Required environment variables:
#   WORKSPACE       - Jenkins workspace root containing dist/ceph artifacts
#   BRANCH          - Branch name
#   SHA1            - Git commit SHA for this build
#   OS_NAME         - Target OS (e.g. centos, ubuntu)
#   OS_VERSION      - Target OS version
#   OS_VERSION_NAME - Ubuntu codename (used when OS_NAME=ubuntu)
#   OS_PKG_TYPE     - Package format: "rpm" or "deb"
#   FLAVOR          - Build flavor label (e.g. default, crimson)
#   ARCH            - Target architecture (deb uploads only)
#   VERSION         - Package version (deb uploads only)

set -ex

source ./scripts/build_utils.sh

export PATH="$HOME/.local/bin:$PATH"

PULP_PROJECT="ceph"
# Must match the base URL the Pulp client is configured with in setup_pulp.sh
PULP_SERVER_URL="https://pulp.front.sepia.ceph.com"
SHORT_SHA1=${SHA1: -8}

# Log a message to stderr with a consistent prefix.
log() {
    echo "[pulp_upload] $*" >&2
}

# Return the OS version label used in Pulp repository and endpoint names.
# For Ubuntu, OS_VERSION_NAME (codename) is used instead of OS_VERSION.
resolve_os_version_for_repo() {
    local os_label="${OS_VERSION}"
    if [ "$OS_NAME" == "ubuntu" ]; then
        os_label="${OS_VERSION_NAME}"
    fi
    printf '%s\n' "$os_label"
}

# Return the number of repository versions to retain.
get_repo_versions_to_retain() {
    local versions=10
    if [[ "$CEPH_REPO" == *-ci ]]; then
        versions=3
    fi
    printf '%s\n' "$versions"
}

# Create a Pulp repository if it doesn't exist.
# Arguments:
#   $1 - Pulp repository name
#   $2 - Package type: "rpm" or "deb"
#   $3 - Number of repository versions to retain
#   $4 - Architecture label stored on the repository
#   $5 - Package manager version string for the version label
# Returns 0 if the repository was created or already exists,
#        1 if an error occurred.
create_pulp_repository() {
    local repo_name="$1"
    local os_pkg_type="$2"
    local retain_repo_versions="$3"
    local repo_arch="$4"
    local package_version="$5"
    local labels_json key value

    log "Checking if Pulp repository ${repo_name} already exists"
    if pulp "${os_pkg_type}" repository show --name "${repo_name}" \
            > /dev/null 2>&1; then
        log "WARNING: Pulp repository ${repo_name} already exists"
        return 0
    fi

    labels_json=$(
        get_pulp_distribution_labels "${repo_arch}" \
            "${package_version}" \
            | jq -Rs '
                split("\n") | map(select(length > 0)) as $lines
                | reduce range(0; ($lines | length); 2) as $i
                    ({}; . + {($lines[$i]): $lines[$i + 1]})
            '
    )

    log "Creating Pulp repository ${repo_name} (OS_PKG_TYPE=${os_pkg_type})"
    if [ "$os_pkg_type" == "rpm" ]; then
        if ! pulp rpm repository create --name "${repo_name}" \
                --no-autopublish \
                --retain-repo-versions "${retain_repo_versions}" \
                --labels "${labels_json}"; then
            log "ERROR: Failed to create ${os_pkg_type} repository" \
                "${repo_name}"
            exit 1
        fi
    elif [ "$os_pkg_type" == "deb" ]; then
        if ! pulp deb repository create --name "${repo_name}" \
                --retain-repo-versions "${retain_repo_versions}"; then
            log "ERROR: Failed to create ${os_pkg_type} repository" \
                "${repo_name}"
            exit 1
        fi
    else
        log "ERROR: Unsupported OS_PKG_TYPE='${os_pkg_type}'"
        exit 1
    fi

    log "Pulp repository ${repo_name} created"
    if [ "$os_pkg_type" == "deb" ]; then
        log "Setting repository labels: ${labels_json}"
        while IFS=$'\t' read -r key value; do
            pulp deb repository label set \
                --repository "${repo_name}" \
                --key "${key}" --value "${value}"
        done < <(
            jq -r 'to_entries[] | "\(.key)\t\(.value)"' \
                <<< "${labels_json}"
        )
    fi
    return 0
}

# Locate the directory containing .deb packages for upload.
# Prefers pool/main (APT pool layout), then WORKDIR, then the deb tree root.
# Arguments:
#   $1 - ceph dist directory (typically ${WORKSPACE}/dist/ceph)
# Prints the chosen upload directory path on stdout.
resolve_deb_upload_dir() {
    local ceph_dist_dir="${1%/}"
    local deb_tree="${ceph_dist_dir}/debs/${OS_NAME}"
    local pool_main="${deb_tree}/pool/main"

    if [ -d "${pool_main}" ]; then
        log "Using APT pool layout under ${pool_main}"
        printf '%s\n' "${pool_main}"
        return 0
    fi
    local workdir="${deb_tree}/WORKDIR"
    if [ -d "${workdir}" ]; then
        log "pool/main not found; falling back to ${workdir}"
        printf '%s\n' "${workdir}"
        return 0
    fi
    log "WARNING: no pool/main or WORKDIR under ${deb_tree};" \
        "searching ${deb_tree}"
    printf '%s\n' "${deb_tree}"
}

# Attach previously uploaded package content to a Pulp repository.
# Arguments:
#   $1 - Pulp content type ("rpm" or "deb")
#   $2 - Pulp repository name
#   $3 - Name of a nameref array variable holding uploaded content UUIDs
add_pulp_uploaded_packages_to_repository() {
    local content_type="$1"
    local repo_name="$2"
    local uuid_array_name="$3"
    local -n _pulp_uuids="$uuid_array_name"
    local add_content_json kind_upper

    kind_upper=$(printf '%s' "$content_type" | tr '[:lower:]' '[:upper:]')
    log "Adding ${kind_upper} content to repository ${repo_name}"
    add_content_json="$(
        printf '['
        for uuid in "${_pulp_uuids[@]}"; do
            printf '{"pulp_href":"/pulp/api/v3/content/%s/packages/%s/"},' \
                "$content_type" "$uuid"
        done | sed 's/,$//'
        printf ']'
    )"
    pulp "${content_type}" repository content modify \
        --repository "$repo_name" --add-content "$add_content_json"
}

# Extract the content UUID from pulp upload command output.
# Pulp prints progress and status text before the final JSON object.
# Arguments:
#   $1 - Combined stdout/stderr from a pulp upload command
# Prints the UUID (last segment of .prn) on stdout.
# Returns 1 if the UUID cannot be parsed.
parse_pulp_upload_uuid() {
    local upload_output="$1"
    local json_line uuid

    json_line=$(printf '%s\n' "$upload_output" | sed -n '/^{/p' | tail -1)
    if [ -z "$json_line" ]; then
        log "ERROR: No JSON found in pulp upload output"
        return 1
    fi
    uuid=$(printf '%s\n' "$json_line" | \
        jq -r '.prn | split(":") | last')
    if [ -z "$uuid" ] || [ "$uuid" = "null" ]; then
        log "ERROR: Failed to parse pulp upload UUID from output"
        return 1
    fi
    printf '%s\n' "$uuid"
}

# Discover and upload RPM files from a build directory to Pulp.
# Arguments:
#   $1 - Directory to search for .rpm files
#   $2 - Pulp repository name
#   $3 - Name of a nameref array variable to populate with uploaded UUIDs
# Returns 0 when all RPMs were uploaded, 1 on upload failure or if none found.
upload_rpm_to_pulp() {
    local rpmbuild_dir="${1%/}"
    local repo_name="$2"
    local out_array_name="$3"
    local -n pulp_uuid="$out_array_name"

    local upload_output uuid
    pulp_uuid=()
    log "Discovering RPM artifacts under ${rpmbuild_dir}"
    while IFS= read -r rpm_file; do
        [ -z "$rpm_file" ] && continue
        if ! upload_output=$(pulp rpm content -t package upload \
                --repository "$repo_name" --file "$rpm_file" \
                --no-publish 2>&1); then
            log "WARNING: Failed to upload ${rpm_file} to ${repo_name}"
            return 1
        fi
        if ! uuid=$(parse_pulp_upload_uuid "$upload_output"); then
            log "WARNING: Failed to parse upload UUID for ${rpm_file}"
            return 1
        fi
        pulp_uuid+=("$uuid")
    done < <(
        find "${rpmbuild_dir}" -regextype egrep -regex ".*(\.rpm)$"
    )
    log "Finished RPM uploads (repository=${repo_name})"
    [[ ${#pulp_uuid[@]} -gt 0 ]]
}

# Discover and upload .deb packages for a given architecture to Pulp.
# Maps x86_64->amd64 and aarch64->arm64 for Debian naming conventions.
# Arguments:
#   $1 - Directory to search for .deb files
#   $2 - Pulp repository name
#   $3 - Build architecture (x86_64, aarch64, etc.)
#   $4 - Name of a nameref array variable to populate with uploaded UUIDs
# Returns 0 when all packages were uploaded, 1 on upload failure or if
# none found.
upload_deb_to_pulp() {
    local deb_dir="${1%/}"
    local repo_name="$2"
    local arch="$3"
    local out_array_name="$4"
    local -n pulp_uuid="$out_array_name"
    local _arch="$arch"
    local upload_output uuid

    if [ "$arch" == "x86_64" ]; then
        _arch="amd64"
    elif [ "$arch" == "aarch64" ]; then
        _arch="arm64"
    fi

    pulp_uuid=()
    log "Discovering .deb packages (${_arch} and all) under ${deb_dir}/"
    while IFS= read -r deb_file; do
        [ -z "$deb_file" ] && continue
        if ! upload_output=$(pulp deb content -t package upload \
                --repository "$repo_name" --file "$deb_file" 2>&1); then
            log "WARNING: Failed to upload ${deb_file} to ${repo_name}"
            return 1
        fi
        if ! uuid=$(parse_pulp_upload_uuid "$upload_output"); then
            log "WARNING: Failed to parse upload UUID for ${deb_file}"
            return 1
        fi
        pulp_uuid+=("$uuid")
    done < <(
        find "${deb_dir}/" -regextype egrep \
            -regex ".*(${_arch}|all)\.deb$" |
            awk -F/ '{name = $NF; if (!seen[name]++) print $0}'
    )
    log "Finished DEB uploads (repository=${repo_name}," \
        "count=${#pulp_uuid[@]})"
    [[ ${#pulp_uuid[@]} -gt 0 ]]
}

# Return Pulp distribution metadata labels as a flat key/value array.
# Arguments:
#   $1 - Architecture label stored on the distribution
#   $2 - Package manager version string for the version label
# Prints one label element per line (key, value, key, value, ...).
get_pulp_distribution_labels() {
    local repo_arch="$1"
    local package_version="$2"

    printf '%s\n' \
        project "${PULP_PROJECT}" \
        version "${package_version}" \
        ref "${BRANCH}" \
        branch "${BRANCH}" \
        arch "${repo_arch}" \
        sha1 "${SHA1}" \
        distro "${OS_NAME}" \
        distro_version "${OS_VERSION}" \
        flavors "${FLAVOR}"
}

# Create a Pulp publication and distribution, then apply metadata labels.
# Arguments:
#   $1 - Pulp repository name
#   $2 - Distribution base path (URL segment under the Pulp content root)
#   $3 - Architecture label stored on the distribution
#   $4 - Package manager version string for the version label
# Uses OS_PKG_TYPE, OS_NAME, OS_VERSION, BRANCH, SHA1, FLAVOR, and SHORT_SHA1
# from the environment. Exits on unsupported OS_PKG_TYPE; returns early on
# publication or distribution creation failure.
publish_pulp_distribution() {
    local repo_name="$1"
    local repo_endpoint="$2"
    local repo_arch="$3"
    local package_version="$4"
    local final_version pub_href dist_name lookup_flag stale_dist

    if [ "$OS_PKG_TYPE" == "rpm" ]; then
        pub_href=$(
            pulp rpm publication create --repository "$repo_name" \
                | jq -r '.pulp_href'
        )
        lookup_flag="--distribution"
    elif [ "$OS_PKG_TYPE" == "deb" ]; then
        pub_href=$(
            pulp deb publication create --repository "$repo_name" \
                --simple --no-structured | jq -r '.pulp_href'
        )
        lookup_flag="--name"
    else
        log "ERROR: Unsupported OS_PKG_TYPE='${OS_PKG_TYPE}'"
        exit 1
    fi

    if [ "$pub_href" == "null" ]; then
        log "ERROR: Failed to create ${OS_PKG_TYPE} publication"
        return
    fi
    log "Created ${OS_PKG_TYPE} publication: ${pub_href}"

    dist_name="dist-${repo_name}-${SHORT_SHA1}"

    log "Checking if Pulp distribution ${dist_name} already exists"
    if pulp "${OS_PKG_TYPE}" distribution show \
            "${lookup_flag}" "${dist_name}" > /dev/null 2>&1; then
        log "Pulp distribution ${dist_name} already exists; deleting"
        if ! pulp "${OS_PKG_TYPE}" distribution destroy \
                "${lookup_flag}" "${dist_name}"; then
            log "ERROR: Failed to delete existing ${OS_PKG_TYPE} distribution"
            return
        fi
    fi

    # A distribution created before FLAVOR was part of the naming scheme may
    # still own this base_path under a different name; base_paths are unique
    # in pulp, so it has to be removed before the new distribution is created.
    stale_dist=$(pulp "${OS_PKG_TYPE}" distribution list \
        --base-path "${repo_endpoint}" 2> /dev/null \
        | jq -r '.[0].name // empty' || true)
    if [ -n "$stale_dist" ] && [ "$stale_dist" != "$dist_name" ]; then
        log "Distribution ${stale_dist} owns base_path ${repo_endpoint}; deleting"
        if ! pulp "${OS_PKG_TYPE}" distribution destroy \
                "${lookup_flag}" "${stale_dist}"; then
            log "ERROR: Failed to delete ${OS_PKG_TYPE} distribution ${stale_dist}"
            return
        fi
    fi

    log "Creating distribution ${dist_name} " \
        "with base_path=${repo_endpoint}"
    if ! pulp "${OS_PKG_TYPE}" distribution create \
        --name "${dist_name}" \
        --base-path "${repo_endpoint}" \
        --publication "${pub_href}"; then
        log "ERROR: Failed to create ${OS_PKG_TYPE} distribution"
        return
    fi

    local i labels
    mapfile -t labels < <(
        get_pulp_distribution_labels "${repo_arch}" "${package_version}"
    )
    log "Setting distribution labels: ${labels[@]}"
    for ((i = 0; i < ${#labels[@]}; i += 2)); do
        pulp "${OS_PKG_TYPE}" distribution label set \
            "${lookup_flag}" "${dist_name}" \
            --key "${labels[i]}" --value "${labels[i + 1]}"
    done

    log "Pulp upload and distribution publish completed" \
        "(repository=${repo_name})"
}

log "Uploading artifacts to Pulp repository ..."

_OS_VERSION=$(resolve_os_version_for_repo)
REPO_VERSIONS_TO_RETAIN=$(get_repo_versions_to_retain)

# FLAVOR is part of the repository (and therefore distribution) name so that
# default and debug builds of the same branch/sha1 don't share repositories
# or clobber each other's distributions.
REPO_NAME="${PULP_PROJECT}-${BRANCH}-${OS_NAME}-${_OS_VERSION}-${FLAVOR}"
REPO_ENDPOINT="repos/${PULP_PROJECT}/${BRANCH}/${SHA1}/${OS_NAME}"
REPO_ENDPOINT="${REPO_ENDPOINT}/${_OS_VERSION}/flavors/${FLAVOR}"

if [ "$OS_PKG_TYPE" = "rpm" ]; then
    log "Starting RPM upload (OS_PKG_TYPE=${OS_PKG_TYPE})"

    spec_path="${WORKSPACE}/dist/ceph/ceph.spec"
    rpm_release=$(grep Release "$spec_path" | \
        sed 's/Release:[ \t]*//g' | cut -d '%' -f 1)
    rpm_version=$(grep Version "$spec_path" | \
        sed 's/Version:[ \t]*//g')
    PACKAGE_MANAGER_VERSION="$rpm_version-$rpm_release"
    log "Package version label (RPM): ${PACKAGE_MANAGER_VERSION}"

    _rpm_root="${WORKSPACE}/dist/ceph/rpmbuild"
    for _kind in SRPMS noarch aarch64 x86_64; do
        _rpm_pulp_uuids=()
        case "$_kind" in
            SRPMS)
                repo_name="${REPO_NAME}-source"
                create_pulp_repository "${repo_name}" "rpm" \
                        "${REPO_VERSIONS_TO_RETAIN}" "source" \
                        "${PACKAGE_MANAGER_VERSION}"

                log "Uploading SRPMS to ${repo_name}"
                if upload_rpm_to_pulp "${_rpm_root}/SRPMS" "${repo_name}" \
                    _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${repo_name}" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${repo_name}" \
                        "${REPO_ENDPOINT}/SRPMS" \
                        "source" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: SRPMS upload failed;" \
                        "skipping content modification and publication" \
                        "for ${repo_name}"
                fi
                ;;

            x86_64)
                repo_name="${REPO_NAME}-x86_64"
                create_pulp_repository "${repo_name}" "rpm" \
                    "${REPO_VERSIONS_TO_RETAIN}" "x86_64" \
                    "${PACKAGE_MANAGER_VERSION}"

                log "Uploading x86_64 RPMs to ${repo_name}"
                if upload_rpm_to_pulp "${_rpm_root}/RPMS/x86_64" \
                    "${repo_name}" _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${repo_name}" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${repo_name}" \
                        "${REPO_ENDPOINT}/x86_64" \
                        "x86_64" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: x86_64 RPM upload failed;" \
                        "skipping content modification and publication" \
                        "for ${repo_name}"
                fi
                ;;

            noarch)
                repo_name="${REPO_NAME}-noarch"
                create_pulp_repository "${repo_name}" "rpm" \
                    "${REPO_VERSIONS_TO_RETAIN}" "noarch" \
                    "${PACKAGE_MANAGER_VERSION}"

                log "Uploading noarch RPMs to ${repo_name}"
                if upload_rpm_to_pulp "${_rpm_root}/RPMS/noarch" \
                    "${repo_name}" _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${repo_name}" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${repo_name}" \
                        "${REPO_ENDPOINT}/noarch" \
                        "noarch" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: noarch RPM upload failed;" \
                        "skipping content modification and publication" \
                        "for ${repo_name}"
                fi
                ;;

            aarch64)
                repo_name="${REPO_NAME}-aarch64"
                create_pulp_repository "${repo_name}" "rpm" \
                    "${REPO_VERSIONS_TO_RETAIN}" "aarch64" \
                    "${PACKAGE_MANAGER_VERSION}"

                log "Uploading aarch64 RPMs to ${repo_name}"
                if upload_rpm_to_pulp "${_rpm_root}/RPMS/aarch64" \
                    "${repo_name}" _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${repo_name}" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${repo_name}" \
                        "${REPO_ENDPOINT}/aarch64" \
                        "aarch64" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: aarch64 RPM upload failed;" \
                        "skipping content modification and publication" \
                        "for ${repo_name}"
                fi
                ;;
        esac
    done
    unset _kind _rpm_root _rpm_pulp_uuids

elif [ "$OS_PKG_TYPE" = "deb" ]; then
    log "Starting DEB upload (OS_PKG_TYPE=${OS_PKG_TYPE})"

    PACKAGE_MANAGER_VERSION="${VERSION}-1${OS_VERSION_NAME}"

    repo_name="${REPO_NAME}-${ARCH}"
    create_pulp_repository "${repo_name}" "deb" \
        "${REPO_VERSIONS_TO_RETAIN}" "${ARCH}" \
        "${PACKAGE_MANAGER_VERSION}"

    log "Uploading DEB packages to ${repo_name}"
    _deb_upload_dir=$(resolve_deb_upload_dir "${WORKSPACE}/dist/ceph")
    _deb_pulp_uuids=()
    if upload_deb_to_pulp "${_deb_upload_dir}" "${repo_name}" \
        "${ARCH}" _deb_pulp_uuids; then
        add_pulp_uploaded_packages_to_repository deb "${repo_name}" \
            _deb_pulp_uuids
        publish_pulp_distribution \
            "${repo_name}" \
            "${REPO_ENDPOINT}/${ARCH}" \
            "${ARCH}" \
            "${PACKAGE_MANAGER_VERSION}"
    else
        log "WARNING: DEB upload failed;" \
            "skipping content modification and publication" \
            "for ${repo_name}"
    fi
    unset _deb_pulp_uuids _deb_upload_dir

else
    log "ERROR: Unsupported OS_PKG_TYPE='${OS_PKG_TYPE}' (expected rpm or deb)"
    exit 1
fi

# Hand off repo metadata to the shaman notify step, which runs as a
# separate process. PACKAGE_MANAGER_VERSION is included in the repo
# record's extra metadata; the repository's API URL becomes the record's
# chacra_url. See notify_shaman_pulp_repo.sh.
# rpm repositories are named after the rpm arch (aarch64), not the Jenkins
# matrix arch (arm64); see the SRPMS/noarch/aarch64/x86_64 loop above.
_repo_arch="${ARCH}"
if [ "$OS_PKG_TYPE" = "rpm" ] && [ "$ARCH" = "arm64" ]; then
    _repo_arch="aarch64"
fi
_repo_href=$(pulp "${OS_PKG_TYPE}" repository show \
    --name "${REPO_NAME}-${_repo_arch}" | jq -r '.pulp_href')
{
    printf 'PACKAGE_MANAGER_VERSION=%q\n' "${PACKAGE_MANAGER_VERSION}"
    printf 'PULP_REPO_API_URL=%q\n' "${PULP_SERVER_URL}${_repo_href}"
} > "${WORKSPACE}/pulp_repo_info"
