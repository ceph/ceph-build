#!/bin/bash
# vim: ts=4 sw=4 expandtab

submit_repo_status() {

    # A helper script to post (create) the status of a repo in shaman.
    # 'state' is the repo status (e.g. 'ready').
    # 'project' is used to post to the right url in shaman.
    # shaman keys repos by 'chacra_url' and builds Arch rows from the 'archs'
    # list, so the arch must be sent as a JSON array (not 'distro_arch').
    http_method=$1
    state=$2
    project=$3
    distro=$4
    distro_version=$5
    arch=$6
    url=$7

    # RPM builds also ship source RPMs (the SRPMS/ subdir), so advertise a
    # "source" arch to shaman alongside the binary arch, mirroring chacra.
    # Binary debs have no corresponding source repo. OS_PKG_TYPE is exported
    # by the calling Jenkins step.
    archs="\"$arch\""
    if [ "$OS_PKG_TYPE" = "rpm" ]; then
        archs="${archs},\"source\""
    fi

    # package_manager_version is computed by pulp_upload.sh (a separate
    # process) and handed off via this file in the shared workspace.
    PACKAGE_MANAGER_VERSION=""
    if [ -r "$WORKSPACE/pulp_repo_info" ]; then
        source "$WORKSPACE/pulp_repo_info"
    fi

    cat > $WORKSPACE/repo_status.json << EOF
{
    "url":"$url",
    "chacra_url":"$url",
    "status":"$state",
    "distro":"$distro",
    "distro_version":"$distro_version",
    "archs":[$archs],
    "ref":"$BRANCH",
    "sha1":"$SHA1",
    "flavor":"$FLAVOR",
    "extra":{
        "version":"$CEPH_VERSION",
        "package_manager_version":"$PACKAGE_MANAGER_VERSION",
        "build_url":"$BUILD_URL",
        "root_build_cause":"$ROOT_BUILD_CAUSE",
        "node_name":"$NODE_NAME",
        "job_name":"$JOB_NAME"
    }
}
EOF

    SHAMAN_URL="https://shaman.ceph.com/api/repos/$project/"
    # post the repo information as JSON to shaman
    curl -X $http_method -H "Content-Type:application/json" --data "@$WORKSPACE/repo_status.json" -u $SHAMAN_API_USER:$SHAMAN_API_KEY ${SHAMAN_URL}
}

# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE}")" ]; then
  submit_repo_status "POST" "$@"
fi
