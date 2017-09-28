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


install_python_packages_no_binary () {
    # Use this function to create a virtualenv and install python packages
    # without compiling (or using wheels). Pass a list of package names.  If
    # the virtualenv exists it will get re-used since this function can be used
    # along with install_python_packages
    #
    # Usage:
    #
    #   to_install=( "ansible" "chacractl>=0.0.4" )
    #   install_python_packages_no_binary "to_install[@]"

    # Create the virtualenv
    if [ "$(ls -A $TEMPVENV)" ]; then
        echo "Will reuse existing virtual env: $TEMPVENV"
    else
        virtualenv $TEMPVENV
    fi


    # Define and ensure the PIP cache
    PIP_SDIST_INDEX="$HOME/.cache/pip"
    mkdir -p $PIP_SDIST_INDEX

    echo "Ensuring latest pip is installed"
    $VENV/pip install --upgrade --exists-action=i --download="$PIP_SDIST_INDEX" pip
    $VENV/pip install --upgrade --exists-action=i --find-links="file://$PIP_SDIST_INDEX" --no-index pip

    echo "Updating setuptools"
    $VENV/pip install --upgrade --exists-action=i --download="$PIP_SDIST_INDEX" setuptools

    pkgs=("${!1}")
    for package in ${pkgs[@]}; do
        echo $package
        # download packages to the local pip cache
        $VENV/pip install --no-binary=:all: --upgrade --exists-action=i --download="$PIP_SDIST_INDEX" $package
        # install packages from the local pip cache, ignoring pypi
        $VENV/pip install --no-binary=:all: --upgrade --exists-action=i --find-links="file://$PIP_SDIST_INDEX" --no-index $package
    done
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

    echo "Ensuring latest pip is installed"
    $VENV/pip install --upgrade --exists-action=i --download="$PIP_SDIST_INDEX" pip
    $VENV/pip install --upgrade --exists-action=i --find-links="file://$PIP_SDIST_INDEX" --no-index pip

    echo "Updating setuptools"
    $VENV/pip install --upgrade --exists-action=i --download="$PIP_SDIST_INDEX" setuptools

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
ssl_verify = True
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

    submit_build_status "POST" $state $project $distro $distro_version $distro_arch
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


get_distro_and_target() {
    # Get distro from DIST for chacra uploads
    DISTRO=""
    case $DIST in
        stretch*)
            DIST=stretch
            DISTRO="debian"
            ;;
        jessie*)
            DIST=jessie
            DISTRO="debian"
            ;;
        wheezy*)
            DIST=wheezy
            DISTRO="debian"
            ;;
        xenial*)
            DIST=xenial
            DISTRO="ubuntu"
            ;;
        precise*)
            DIST=precise
            DISTRO="ubuntu"
            ;;
        trusty*)
            DIST=trusty
            DISTRO="ubuntu"
            ;;
        centos*)
            DISTRO="centos"
            MOCK_TARGET="epel"
            ;;
        rhel*)
            DISTRO="rhel"
            MOCK_TARGET="epel"
            ;;
        fedora*)
            DISTRO="fedora"
            MOCK_TARGET="fedora"
            ;;
        *)
            DISTRO="unknown"
            ;;
    esac
}


setup_pbuilder() {
    # This function will set the tgz images needed for pbuilder on a given host. It has
    # some hard-coded values like `/srv/debian-base` because it gets built every
    # time this file is executed - completely ephemeral.  If a Debian host will use
    # pbuilder, then it will need this. Since it is not idempotent it makes
    # everything a bit slower. ## FIXME ##

    basedir="/srv/debian-base"

    # Ensure that the basedir directory exists
    sudo mkdir -p "$basedir"

    # This used to live in a *file* on /srv/ceph-build as
    # /srv/ceph-build/update_pbuilder.sh Now it lives here because it doesn't make
    # sense to have a file that lives in /srv/ that we then concatenate to get its
    # contents.  what.
    # By using $DIST we are narrowing down to updating only the distro image we
    # need, unlike before where we updated everything on every server on every
    # build.

    os="debian"
    [ "$DIST" = "precise" ] && os="ubuntu"
    [ "$DIST" = "saucy" ] && os="ubuntu"
    [ "$DIST" = "trusty" ] && os="ubuntu"
    [ "$DIST" = "xenial" ] && os="ubuntu"

    if [ $os = "debian" ]; then
        mirror="http://www.gtlib.gatech.edu/pub/debian"
        # this assumes that newer Debian releases are being added to
        # /etc/apt/trusted.gpg that is also the default location for Ubuntu trusted
        # keys. The slave should ensure that the needed keys are added accordingly
        # to this location.
        debootstrapopts='DEBOOTSTRAPOPTS=( "--keyring" "/etc/apt/trusted.gpg" )'
        components='COMPONENTS="main contrib"'
    elif [ "$ARCH" = "arm64" ]; then
        mirror="http://ports.ubuntu.com/ubuntu-ports"
        debootstrapopts=""
        components='COMPONENTS="main universe"'
    else
        mirror="http://us.archive.ubuntu.com/ubuntu"
        debootstrapopts=""
        components='COMPONENTS="main universe"'
    fi

    # ensure that the tgz is valid, otherwise remove it so that it can be recreated
    # again
    pbuild_tar="$basedir/$DIST.tgz"
    is_not_tar=`python -c "exec 'try: import tarfile;print int(not int(tarfile.is_tarfile(\"$pbuild_tar\")))\nexcept IOError: print 1'"`
    file_size_kb=`du -k "$pbuild_tar" | cut -f1`

    if $is_not_tar; then
        sudo rm -f "$pbuild_tar"
    fi

    if [ $file_size_kb -lt 1 ]; then
        sudo rm -f "$pbuild_tar"
    fi

    # Ordinarily pbuilder only pulls packages from "main".  ceph depends on
    # packages like python-virtualenv which are in "universe". We have to configure
    # pbuilder to look in "universe". Otherwise the build would fail with a message similar
    # to:
    #    The following packages have unmet dependencies:
    #      pbuilder-satisfydepends-dummy : Depends: python-virtualenv which is a virtual package.
    #                                      Depends: xmlstarlet which is a virtual package.
    #     Unable to resolve dependencies!  Giving up...
    echo "$components" > ~/.pbuilderrc
    echo "$debootstrapopts" >> ~/.pbuilderrc

    sudo pbuilder --clean

    if [ -e $basedir/$DIST.tgz ]; then
        echo updating $DIST base.tgz
        sudo pbuilder update \
        --basetgz $basedir/$DIST.tgz \
        --distribution $DIST \
        --mirror "$mirror" \
        --override-config
    else
        echo building $DIST base.tgz
        sudo pbuilder create \
        --basetgz $basedir/$DIST.tgz \
        --distribution $DIST \
        --mirror "$mirror"
    fi
}

delete_libvirt_vms() {
    # Delete any VMs leftover from previous builds.
    # Primarily used for Vagrant VMs leftover from docker builds.
    libvirt_vms=`sudo virsh list --all --name`
    for vm in $libvirt_vms; do
        # Destroy returns a non-zero rc if the VM's not running
        sudo virsh destroy $vm || true
        sudo virsh undefine $vm || true
    done
    # Clean up any leftover disk images
    sudo find /var/lib/libvirt/images/ -type f -delete
    sudo virsh pool-refresh default || true
}

clear_libvirt_networks() {
    # Sometimes, networks may linger around, so we must ensure they are killed:
    networks=`sudo virsh net-list --all --name`
    for network in $networks; do
        sudo virsh net-destroy $network || true
        sudo virsh net-undefine $network || true
    done
}

restart_libvirt_services() {
    # restart libvirt services
    sudo service libvirt-bin restart
    sudo service libvirt-guests restart
}

# Function to update vagrant boxes on static libvirt slaves used for ceph-ansible and ceph-docker testing
update_vagrant_boxes() {
    outdated_boxes=`vagrant box outdated --global | grep 'is outdated' | awk '{ print $2 }' | tr -d "'"`
    if [ -n "$outdated_boxes" ]; then
        for box in $outdated_boxes; do
            vagrant box update --box $box
        done
        # Clean up old images
        vagrant box prune
    fi
}
