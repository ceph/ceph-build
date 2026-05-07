#!/bin/bash
set -ex

export PATH="$HOME/.local/bin:$PATH"

PULP_PROJECT="ceph"
SHORT_SHA1=${SHA1: -8}

log() {
    echo "[pulp_upload] $*" >&2
}

resolve_branch_from_ceph_version() {
    local branch=""
    if [[ $CEPH_VERSION =~ ^21.* ]]; then
        branch="main"
    elif [[ $CEPH_VERSION =~ ^20.* ]]; then
        branch="tentacle"
    elif [[ $CEPH_VERSION =~ ^19.* ]]; then
        branch="squid"
    elif [[ $CEPH_VERSION =~ ^18.* ]]; then
        branch="reef"
    elif [[ $CEPH_VERSION =~ ^17.* ]]; then
        branch="quincy"
    elif [[ $CEPH_VERSION =~ ^16.* ]]; then
        branch="pacific"
    else
        log "ERROR: Unsupported Ceph version '${CEPH_VERSION}'" \
            "(expected 16.x–20.x for branch mapping)"
        exit 1
    fi
    printf '%s\n' "$branch"
}

resolve_os_version_for_repo() {
    local os_label="${OS_VERSION}"
    if [ "$OS_NAME" == "ubuntu" ]; then
        os_label="${OS_VERSION_NAME}"
    fi
    printf '%s\n' "$os_label"
}

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
    log "Discovering binary .deb packages under ${deb_dir}/"
    while IFS= read -r deb_file; do
        [ -z "$deb_file" ] && continue
        pulp_uuid+=($(pulp deb content -t package upload \
            --repository "$repo_name" --file "$deb_file" --no-publish | \
            jq -r '.prn | split(":") | last'
        ))
    done < <(
        find "${deb_dir}/" -regextype egrep -regex ".*(${_arch}\.deb)$"
    )
    log "Finished DEB uploads (repository=${repo_name})"
    [[ ${#pulp_uuid[@]} -gt 0 ]]
}

publish_pulp_distribution() {
    local repo_name="$1"
    local repo_endpoint="$2"
    local repo_arch="$3"
    local package_version="$4"
    local final_version pub_href dist_name labels

    if [ "$OS_PKG_TYPE" == "deb" ]; then
        pub_href=$(
            pulp deb publication create --repository "$repo_name" \
                --simple --no-structured | jq -r '.pulp_href'
        )
        log "Created DEB publication ${pub_href}"
    else
        pub_href=$(
            pulp "${OS_PKG_TYPE}" publication create --repository "$repo_name" \
                | jq -r '.pulp_href'
        )
        log "Created RPM publication ${pub_href}"
    fi

    dist_name="dist-${repo_name}-${SHORT_SHA1}"
    log "Creating distribution ${dist_name} " \
        "with base_path=${repo_endpoint}"
    pulp "${OS_PKG_TYPE}" distribution create \
        --name "${dist_name}" \
        --base-path "${repo_endpoint}" \
        --publication "${pub_href}"

    local lookup_flag="--name"
    if [[ "$OS_PKG_TYPE" == "rpm" ]]; then
        lookup_flag="--distribution"
    fi

    local i
    local -a labels=(
        project "${PULP_PROJECT}"
        version "${package_version}"
        ref "${BRANCH}"
        arch "${repo_arch}"
        sha1 "${SHA1}"
        distro "${OS_NAME}"
        distro_version "${OS_VERSION_NAME}"
        flavor "${FLAVOR}"
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

BRANCH=$(resolve_branch_from_ceph_version)
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
                log "Uploading SRPMS to ${REPO_NAME}-SRPMS"
                if upload_rpm_to_pulp "${_rpm_root}/SRPMS" "${REPO_NAME}-SRPMS" \
                    _rpm_pulp_uuids; then
                    add_pulp_uploaded_packages_to_repository rpm \
                        "${REPO_NAME}-SRPMS" _rpm_pulp_uuids
                    publish_pulp_distribution \
                        "${REPO_NAME}-SRPMS" \
                        "${REPO_ENDPOINT}/SRPMS" \
                        "source" \
                        "${PACKAGE_MANAGER_VERSION}"
                else
                    log "WARNING: SRPMS upload failed;" \
                        "skipping content modification and publication for ${REPO_NAME}-SRPMS"
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

    log "Uploading DEB artifacts to ${REPO_NAME}-${ARCH}"
    _deb_pulp_uuids=()
    if upload_deb_to_pulp "${WORKSPACE}/dist/ceph" "${REPO_NAME}-${ARCH}" \
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
    unset _deb_pulp_uuids

else
    log "ERROR: Unsupported OS_PKG_TYPE='${OS_PKG_TYPE}' (expected rpm or deb)"
    exit 1
fi
