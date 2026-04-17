#!/bin/bash
set -ex

log() {
    echo "[pulp_upload] $*" >&2
}

PULP_PROJECT="ceph"
SHORT_SHA1=${SHA1: -8}

BRANCH="main"
if [[ $CEPH_VERSION =~ ^20.* ]]; then
  BRANCH="tentacle"
elif [[ $CEPH_VERSION =~ ^19.* ]]; then
  BRANCH="squid"
elif [[ $CEPH_VERSION =~ ^18.* ]]; then
  BRANCH="reef"
elif [[ $CEPH_VERSION =~ ^17.* ]]; then
  BRANCH="quincy"
elif [[ $CEPH_VERSION =~ ^16.* ]]; then
  BRANCH="pacific"
else:
  log "ERROR: Unsupported version '${VERSION}'"
  exit 1
fi

REPO_NAME="${PULP_PROJECT}-${BRANCH}-${OS_NAME}-${OS_VERSION}-${ARCH}"
REPO_ENDPOINT="${PULP_PROJECT}/${BRANCH}/${SHA1}/${OS_NAME}/${OS_VERSION}"
REPO_ENDPOINT="${REPO_ENDPOINT}/flavors/${FLAVOR}/${ARCH}"

log "Starting Pulp upload (OS_PKG_TYPE=${OS_PKG_TYPE})"
log "Repository: ${REPO_NAME}; base_path: ${REPO_ENDPOINT}"

if [ "$OS_PKG_TYPE" = "rpm" ]; then
    rpm_release=$(grep Release dist/ceph/ceph.spec | \
      sed 's/Release:[ \t]*//g' | cut -d '%' -f 1)
    rpm_version=$(grep Version dist/ceph/ceph.spec | \
      sed 's/Version:[ \t]*//g')

    PACKAGE_MANAGER_VERSION="$rpm_version-$rpm_release"
    log "Package version label (RPM): ${PACKAGE_MANAGER_VERSION}"

    log "Discovering RPM artifacts under" \
        "${WORKSPACE}/dist/ceph/rpmbuild/ (SRPMS, RPMS)"
    while IFS= read -r rpm_file; do
        [ -z "$rpm_file" ] && continue
        pulp rpm content -t package upload --repository "${REPO_NAME}" \
            --file "$rpm_file"
    done < <(
        find "${WORKSPACE}/dist/ceph/rpmbuild/SRPMS" \
            "${WORKSPACE}/dist/ceph/rpmbuild/RPMS" \
            -name "*.rpm"
    )
    log "Finished RPM uploads (repository=${REPO_NAME})"
elif [ "$OS_PKG_TYPE" = "deb" ]; then
    PACKAGE_MANAGER_VERSION="${VERSION}-1${OS_VERSION_NAME}"
    log "Package version label (DEB): ${PACKAGE_MANAGER_VERSION}"

    log "Discovering DEB artifacts under ${WORKSPACE}/dist/ceph/" \
        "(.changes, .deb, .ddeb, .dsc, .gz)"
    while IFS= read -r deb_file; do
        [ -z "$deb_file" ] && continue
        pulp deb content -t package upload --repository "${REPO_NAME}" \
            --file "$deb_file"
    done < <(
        find "${WORKSPACE}/dist/ceph/" -regextype egrep \
            -regex ".*(\.changes|\.deb|\.ddeb|\.dsc|ceph.*\.gz)$" |
            grep -vE "(Packages|Sources|Contents)" || true
    )
    log "Finished DEB uploads (repository=${REPO_NAME})"
else
    log "ERROR: Unsupported OS_PKG_TYPE='${OS_PKG_TYPE}' (expected rpm or deb)"
    exit 1
fi

FINAL_VERSION=$(pulp "${OS_PKG_TYPE}" repository version list \
    --repository "$REPO_NAME" --limit 1 | jq -r '.[0].number')
log "Found final version ${FINAL_VERSION}"

if [ "$OS_PKG_TYPE" == "deb" ]; then
    PUB_HREF=$(
        pulp deb publication create --repository "$REPO_NAME" \
            --version "$FINAL_VERSION" --simple "true" --structured "false" \
            | jq -r '.pulp_href'
    )
    log "Created DEB publication ${PUB_HREF}"
else
    PUB_HREF=$(
        pulp "${OS_PKG_TYPE}" publication create --repository "$REPO_NAME" \
            --version "$FINAL_VERSION" | jq -r '.pulp_href'
    )
    log "Created RPM publication ${PUB_HREF}"
fi

DIST_NAME="dist-${REPO_NAME}-${SHORT_SHA1}"
LABELS="project=${PULP_PROJECT},"
LABELS="${LABELS}version=${PACKAGE_MANAGER_VERSION},"
LABELS="${LABELS}ref=${BRANCH},"
LABELS="${LABELS}arch=${ARCH}"
LABELS="${LABELS},sha1=${SHA1}"

log "Creating distribution ${DIST_NAME} " \
    "with base_path=${REPO_ENDPOINT} labels=${LABELS}"
pulp "${OS_PKG_TYPE}" distribution create \
    --name "${DIST_NAME}" \
    --repository "${REPO_NAME}" \
    --base-path "${REPO_ENDPOINT}" \
    --publication "${PUB_HREF}"

log "Updating distribution ${DIST_NAME} with publication" \
    "publication=${PUB_HREF} and labels=${LABELS}"
pulp "${OS_PKG_TYPE}" distribution update \
    --name "${DIST_NAME}" \
    --publication "${PUB_HREF}" \
    --labels "${LABELS}"

log "Pulp upload and distribution publish completed (repository=${REPO_NAME})"
