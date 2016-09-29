#!/bin/bash

set -ex

TEMPVENV=$(mktemp -td venv.XXXXXXXXXX)
VENV="$TEMPVENV/bin"

branch_slash_filter() {
    # The build system relies on an HTTP binary store that uses branches/refs
    # as URL parts.  A literal extra slash in the branch name is considered
    # illegal, so this function performs a check *and* prunes the common
    # `origin/branch-name` scenario (which is OK to have).
    RAW_BRANCH=$1
    branch_slashes=$(grep -o "/" <<< ${RAW_BRANCH} | wc -l)
    FILTERED_BRANCH=`echo ${RAW_BRANCH} | rev | cut -d '/' -f 1 | rev`

    # Prevent building branches that have slashes in their name
    if [ "$((branch_slashes))" -gt 1 ] ; then
        echo "Will refuse to build branch: ${RAW_BRANCH}"
        echo "Invalid branch name (contains slashes): ${FILTERED_BRANCH}"
        exit 1
    fi
    echo $FILTERED_BRANCH
}

install_python_packages () {
    # Use this function to create a virtualenv and install
    # python packages. Pass a list of package names.
    #
    # Usage:
    #
    #   to_install=( "ansible" "chacractl>=0.0.4" )
    #   install_python_packages "to_install[@]"

    # Create the virtualenv
    virtualenv $TEMPVENV

    # Define and ensure the PIP cache
    PIP_SDIST_INDEX="$HOME/.cache/pip"
    mkdir -p $PIP_SDIST_INDEX

    echo "Updating setuptools"
    $VENV/pip install --upgrade --exists-action=i --download="$PIP_SDIST_INDEX" setuptools

    echo "Ensuring latest pip is installed"
    $VENV/pip install --upgrade --exists-action=i --download="$PIP_SDIST_INDEX" pip
    $VENV/pip install --upgrade --exists-action=i --find-links="file://$PIP_SDIST_INDEX" --no-index pip

    pkgs=("${!1}")
    for package in ${pkgs[@]}; do
        echo $package
        # download packages to the local pip cache
        $VENV/pip install --upgrade --exists-action=i --download="$PIP_SDIST_INDEX" $package
        # install packages from the local pip cache, ignoring pypi
        $VENV/pip install --upgrade --exists-action=i --find-links="file://$PIP_SDIST_INDEX" --no-index $package
    done
}

make_chacractl_config () {
    # create the .chacractl config file
    if [ -z "$1" ]                           # Is parameter #1 zero length?
    then
      url=$CHACRACTL_URL
    else
      url=$1
    fi
    cat > $HOME/.chacractl << EOF
url = "$url"
user = "$CHACRACTL_USER"
key = "$CHACRACTL_KEY"
ssl_verify = False
EOF
}

get_rpm_dist() {
    # creates a DISTRO_VERSION and DISTRO global variable for
    # use in constructing chacra urls for rpm distros

    LSB_RELEASE=/usr/bin/lsb_release
    [ ! -x $LSB_RELEASE ] && echo unknown && exit

    ID=`$LSB_RELEASE --short --id`

    case $ID in
    RedHatEnterpriseServer)
        DISTRO_VERSION=`$LSB_RELEASE --short --release | cut -d. -f1`
        DISTRO=rhel
        ;;
    CentOS)
        DISTRO_VERSION=`$LSB_RELEASE --short --release | cut -d. -f1`
        DISTRO=centos
        ;;
    Fedora)
        DISTRO_VERSION=`$LSB_RELEASE --short --release`
        DISTRO=fedora
        ;;
    SUSE\ LINUX)
        DESC=`$LSB_RELEASE --short --description`
        DISTRO_VERSION=`$LSB_RELEASE --short --release`
        case $DESC in
        *openSUSE*)
                DISTRO=opensuse
            ;;
        *Enterprise*)
                DISTRO=sles
                ;;
            esac
        ;;
    *)
        DIST=unknown
        DISTRO=unknown
        ;;
    esac

}

check_binary_existence () {
    url=$1

    # we have to use ! here so thet -e will ignore the error code for the command
    # because of this, the exit code is also reversed
    ! $VENV/chacractl exists binaries/${url} ; exists=$?

    # if the binary already exists in chacra, do not rebuild
    if [ $exists -eq 1 ] && [ "$FORCE" = false ] ; then
        echo "The endpoint at ${chacra_endpoint} already exists and FORCE was not set, Exiting..."
        exit 0
    fi

}


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
    "state":"$state",
    "distro":"$distro",
    "distro_version":"$distro_version",
    "distro_arch":"$distro_arch",
    "branch":"$BRANCH",
    "sha1":"$SHA1",
    "flavor":"$FLAVOR"
}
EOF

    SHAMAN_URL="https://shaman.ceph.com/api/builds/$project/"
    # post the build information as JSON to shaman
    curl -X $http_method -H "Content-Type:application/json" --data "@$WORKSPACE/build_status.json" -u $SHAMAN_API_USER:$SHAMAN_API_KEY ${SHAMAN_URL}


}


update_build_status() {
    # A proxy script to PUT (update) the status of a build in shaman
    # 'state' can be either of: 'started', 'completed', or 'failed'
    # 'project' is used to post to the right url in shaman

    # required
    state=$1
    project=$2

    # optional
    distro=$3
    distro_version=$4
    distro_arch=$5

    submit_build_status "PUT" $state $project $distro $distro_version $distro_arch
}


create_build_status() {
    # A proxy script to POST (create) the status of a build in shaman for
    # a normal/initial build
    # 'state' can be either of: 'started', 'completed', or 'failed'
    # 'project' is used to post to the right url in shaman

    # required
    state=$1
    project=$2

    # optional
    distro=$3
    distro_version=$4
    distro_arch=$5

    submit_build_status "POST" $state $project $distro $distro_version $distro_arch
}


failed_build_status() {
    # A helper script to POST (create) the status of a build in shaman as
    # a failed build. The only required argument is the 'project', so that it
    # can be used post to the right url in shaman

    # required
    project=$1

    state="failed"

    # optional
    distro=$2
    distro_version=$3
    distro_arch=$4

    submit_build_status "POST" $state $project $distro $distro_version $distro_arch
}
