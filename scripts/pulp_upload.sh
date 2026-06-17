#!/bin/bash

# Upload Ceph build artifacts to a Pulp repository and publish distributions.

# Intended for CI jobs after package builds complete. Discovers RPM or DEB
# packages under WORKSPACE/dist/ceph, uploads them to Pulp, attaches the
# uploaded content to per-arch repositories, and creates publications and
# distributions with metadata labels for Shaman discovery.

# Required environment variables:
#   WORKSPACE       - Jenkins workspace root containing dist/ceph artifacts
#   CEPH_VERSION    - Full Ceph version string (used to derive release branch)
#   SHA1            - Git commit SHA for this build
#   OS_NAME         - Target OS (e.g. centos, ubuntu)
#   OS_VERSION      - Target OS version
#   OS_VERSION_NAME - Ubuntu codename (used when OS_NAME=ubuntu)
#   OS_PKG_TYPE     - Package format: "rpm" or "deb"
#   FLAVOR          - Build flavor label (e.g. default, crimson)
#   ARCH            - Target architecture (deb uploads only)
#   VERSION         - Package version (deb uploads only)
#

set -ex

source ./scripts/build_utils.sh

export PATH="$HOME/.local/bin:$PATH"

PULP_PROJECT="ceph"
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

# Return the distro_version label for Pulp distribution metadata (OS-specific mapping).
get_distro_version_label() {
    case "${OS_NAME}" in
        centos)
            case "${OS_VERSION}" in
                [0-7])
                    printf '%s\n' "${OS_VERSION}"
                    ;;
                *)
                    printf '%s.stream\n' "${OS_VERSION}"
                    ;;
            esac
            ;;
        rocky)
            case "${OS_VERSION}" in
                8)
                    printf '%s\n' '8.10'
                    ;;
                9)
                    printf '%s\n' '9.7'
                    ;;
                10)
                    printf '%s\n' '10.1'
                    ;;
                *)
                    printf '%s\n' "${OS_VERSION}"
                    ;;
            esac
            ;;
        *)
            printf '%s\n' "${OS_VERSION}"
            ;;
    esac
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
    log "WARNING: no pool/main or WORKDIR under ${deb_tree}; searching ${deb_tree}"
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
    pulp "${content_type}" repository content modify --repository "$repo_name" \
        --add-content "$add_content_json" --base-version 0
}

# Discover and upload RPM files from a build directory to Pulp.
# Arguments:
#   $1 - Directory to search for .rpm files
#   $2 - Pulp repository name
#   $3 - Name of a nameref array variable to populate with uploaded UUIDs
# Returns 0 when at least one RPM was uploaded, 1 otherwise.
upload_rpm_to_pulp() {
    local rpmbuild_dir="${1%/}"
    local repo_name="$2"
    local out_array_name="$3"
    local -n pulp_uuid="$out_array_name"

    pulp_uuid=()
    log "Discovering RPM artifacts under ${rpmbuild_dir}"
    while IFS= read -r rpm_file; do
        [ -z "$rpm_file" ] && continue
        pulp_uuid+=($(pulp rpm content -t package upload \
            --repository "$repo_name" --file "$rpm_file" --no-publish | \
            jq -r '.prn | split(":") | last'
        ))
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
# Returns 0 when at least one package was uploaded, 1 otherwise.
upload_deb_to_pulp() {
    local deb_dir="${1%/}"
    local repo_name="$2"
    local arch="$3"
    local out_array_name="$4"
    local -n pulp_uuid="$out_array_name"
    local _arch="$arch"

    if [ "$arch" == "x86_64" ]; then
        _arch="amd64"
    elif [ "$arch" == "aarch64" ]; then
        _arch="arm64"
    fi

    pulp_uuid=()
    log "Discovering .deb packages (${_arch} and all) under ${deb_dir}/"
    while IFS= read -r deb_file; do
        [ -z "$deb_file" ] && continue
        pulp_uuid+=($(pulp deb content -t package upload \
            --repository "$repo_name" --file "$deb_file" | \
            jq -r '.prn | split(":") | last'
        ))
    done < <(
        find "${deb_dir}/" -regextype egrep \
            -regex ".*(${_arch}|all)\.deb$" |
            awk -F/ '{name = $NF; if (!seen[name]++) print $0}'
    )
    log "Finished DEB uploads (repository=${repo_name}, count=${#pulp_uuid[@]})"
    [[ ${#pulp_uuid[@]} -gt 0 ]]
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
    local final_version pub_href dist_name labels lookup_flag

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
    log "Creating distribution ${dist_name} " \
        "with base_path=${repo_endpoint}"
    if ! pulp "${OS_PKG_TYPE}" distribution create \
        --name "${dist_name}" \
        --base-path "${repo_endpoint}" \
        --publication "${pub_href}"; then
        log "ERROR: Failed to create ${OS_PKG_TYPE} distribution"
        return
    fi

    local i distro_version
    distro_version=$(get_distro_version_label)
    local -a labels=(
        project "${PULP_PROJECT}"
        version "${package_version}"
        ref "${BRANCH}"
        branch "${BRANCH}"
        arch "${repo_arch}"
        sha1 "${SHA1}"
        distro "${OS_NAME}"
        distro_version "${distro_version}"
        flavors "${FLAVOR}"
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

BRANCH=$(release_from_version "${CEPH_VERSION}")
_OS_VERSION=$(resolve_os_version_for_repo)

REPO_NAME="${PULP_PROJECT}-${BRANCH}-${OS_NAME}-${_OS_VERSION}"
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
                log "Uploading SRPMS to ${REPO_NAME}-source"
                if upload_rpm_to_pulp "${_rpm_root}/SRPMS" "${REPO_NAME}-source" \
                    _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${REPO_NAME}-source" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${REPO_NAME}-source" \
                        "${REPO_ENDPOINT}/SRPMS" \
                        "source" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: SRPMS upload failed;" \
                        "skipping content modification and publication for ${REPO_NAME}-source"
                fi
                ;;
            x86_64)
                log "Uploading x86_64 RPMs to ${REPO_NAME}-x86_64"
                if upload_rpm_to_pulp "${_rpm_root}/RPMS/x86_64" \
                    "${REPO_NAME}-x86_64" _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${REPO_NAME}-x86_64" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${REPO_NAME}-x86_64" \
                        "${REPO_ENDPOINT}/x86_64" \
                        "x86_64" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: x86_64 RPM upload failed;" \
                        "skipping content modification and publication for ${REPO_NAME}-x86_64"
                fi
                ;;
            noarch)
                log "Uploading noarch RPMs to ${REPO_NAME}-noarch"
                if upload_rpm_to_pulp "${_rpm_root}/RPMS/noarch" \
                    "${REPO_NAME}-noarch" _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${REPO_NAME}-noarch" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${REPO_NAME}-noarch" \
                        "${REPO_ENDPOINT}/noarch" \
                        "noarch" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: noarch RPM upload failed;" \
                        "skipping content modification and publication for ${REPO_NAME}-noarch"
                fi
                ;;
            aarch64)
                log "Uploading aarch64 RPMs to ${REPO_NAME}-aarch64"
                if upload_rpm_to_pulp "${_rpm_root}/RPMS/aarch64" \
                    "${REPO_NAME}-aarch64" _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${REPO_NAME}-aarch64" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${REPO_NAME}-aarch64" \
                        "${REPO_ENDPOINT}/aarch64" \
                        "aarch64" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: aarch64 RPM upload failed;" \
                        "skipping content modification and publication for ${REPO_NAME}-aarch64"
                fi
                ;;
        esac
    done
    unset _kind _rpm_root _rpm_pulp_uuids

elif [ "$OS_PKG_TYPE" = "deb" ]; then
    PACKAGE_MANAGER_VERSION="${VERSION}-1${OS_VERSION_NAME}"
    log "Starting DEB upload (OS_PKG_TYPE=${OS_PKG_TYPE})"

    _deb_upload_dir=$(resolve_deb_upload_dir "${WORKSPACE}/dist/ceph")
    log "Uploading DEB artifacts to ${REPO_NAME}-${ARCH} from ${_deb_upload_dir}"
    _deb_pulp_uuids=()
    if upload_deb_to_pulp "${_deb_upload_dir}" "${REPO_NAME}-${ARCH}" \
        "${ARCH}" _deb_pulp_uuids; then
        add_pulp_uploaded_packages_to_repository deb "${REPO_NAME}-${ARCH}" \
            _deb_pulp_uuids
        publish_pulp_distribution \
            "${REPO_NAME}-${ARCH}" \
            "${REPO_ENDPOINT}/${ARCH}" \
            "${ARCH}" \
            "${PACKAGE_MANAGER_VERSION}"
    else
        log "WARNING: DEB upload failed;" \
            "skipping content modification and publication for ${REPO_NAME}-${ARCH}"
    fi
    unset _deb_pulp_uuids _deb_upload_dir

else
    log "ERROR: Unsupported OS_PKG_TYPE='${OS_PKG_TYPE}' (expected rpm or deb)"
    exit 1
fi
