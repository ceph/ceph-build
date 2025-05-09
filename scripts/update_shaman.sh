submit_build_status() {

    # A helper script to post (create) the status of a build in shaman
    # 'state' can be either 'failed' or 'started'
    # 'project' is used to post to the right url in shaman
    http_method=$1
    state=$2
    project=$3
    distro=$4
    distro_version=$5
    distro_arch=$6
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
    "log_url":"$BUILD_URL/consoleFull",
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
