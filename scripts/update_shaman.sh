#!/bin/bash
# vim: ts=4 sw=4 expandtab

get_pipeline_node_url() {
    local distro="$1"
    local arch="$2"
    local flavor="${FLAVOR:-default}"

    # cut is portable; no sed regex quirks
    local base job build_num
    base=$(echo "$BUILD_URL"      | cut -d/ -f1-3)    # https://jenkins.ceph.com
    job=$(echo "$BUILD_URL"       | cut -d/ -f5)      # ceph-dev-pipeline
    build_num=$(echo "$BUILD_URL" | cut -d/ -f6)      # 5306

    local nodes_json branch_id child_id

    # By default, the Blue Ocean nodes API returns a limited number of nodes.  We have at around 160
    # as of this writing so `limit=500` bypasses that limitation.
    # Store the node IDs used for this particular job.
    nodes_json=$(curl -sf \
        "${base}/blue/rest/organizations/jenkins/pipelines/${job}/runs/${build_num}/nodes/?limit=500" \
        2>/dev/null)

    # This is the branch of the matrix.. not a git branch.
    branch_id=$(echo "$nodes_json" | jq -r \
        --arg dist "$distro" --arg arch "$arch" --arg flav "$flavor" \
        '[.[] | select(.displayName | (contains($dist) and contains($arch) and contains($flav)))] | first | .id // empty')

    # Now find the node ID (the Jenkins builder ID) used for this particular matrix branch.
    child_id=$(echo "$nodes_json" | jq -r \
        --arg parent "$branch_id" \
        '[.[] | select(.firstParent == $parent)] | first | .id // empty')

    # Fall back to the branch ID if we couldn't get a node ID.
    local node_id="${child_id:-${branch_id}}"

    if [ -n "$node_id" ]; then
        echo "${BUILD_URL}pipeline-overview/?selected-node=${node_id}"
    else
        echo "$BUILD_URL"
    fi
}

submit_build_status() {
    http_method=$1
    state=$2
    project=$3
    distro=$4
    distro_version=$5
    distro_arch=$6

    local pipeline_url log_url
    pipeline_url=$(get_pipeline_node_url "$distro" "$distro_arch")

    # If we were able to deduce an individual matrix branch node ID,
    # use that for log_url, else use the older consoleFull endpoint.
    if [[ $pipeline_url =~ selected-node ]]; then
        log_url="$pipeline_url"
    else
        log_url="$BUILD_URL/consoleFull"
    fi

    cat > $WORKSPACE/build_status.json << EOF
{
    "extra":{
        "version":"$vers",
        "root_build_cause":"$ROOT_BUILD_CAUSE",
        "node_name":"$NODE_NAME",
        "job_name":"$JOB_NAME",
        "build_user":"$BUILD_USER"
    },
    "url":"$BUILD_URL",
    "log_url":"$log_url",
    "status":"$state",
    "distro":"$distro",
    "distro_version":"$distro_version",
    "distro_arch":"$distro_arch",
    "ref":"$BRANCH",
    "sha1":"$SHA1",
    "flavor":"$FLAVOR"
}
EOF

    # these variables are saved in this jenkins
    # properties file so that other scripts
    # in the same job can inject them
    cat > $WORKSPACE/build_info << EOF
NORMAL_DISTRO=$distro
NORMAL_DISTRO_VERSION=$distro_version
NORMAL_ARCH=$distro_arch
SHA1=$SHA1
EOF

    SHAMAN_URL="https://shaman.ceph.com/api/builds/$project/"
    # post the build information as JSON to shaman
    curl -X $http_method -H "Content-Type:application/json" --data "@$WORKSPACE/build_status.json" -u $SHAMAN_API_USER:$SHAMAN_API_KEY ${SHAMAN_URL}
}

# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE}")" ]; then
  submit_build_status "POST" "$@"
fi
