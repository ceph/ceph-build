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

pip_download() {
    local package=$1
    shift
    local options=$@
    if ! $VENV/pip download $options --dest="$PIP_SDIST_INDEX" $package; then
        # pip <8.0.0 does not have "download" command
        $VENV/pip install $options \
                  --upgrade --exists-action=i --cache-dir="$PIP_SDIST_INDEX" \
                  $package
    fi
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
    # XXX This means we are now pinning to 10.0.0, to prevent issues on pip
    # mismtaching versions, but also that we need to revisit this when newer
    # options are needed. ``easy_install`` is a must on systems with ancient
    # versions of pip that break with newer versions of pkg_resources that come
    # with the virtualenv. Doing an initial upgrade with easy_install
    # circumvents the problem
    $VENV/easy_install --upgrade pip
    $VENV/pip install "pip==10.0.0"

    echo "Updating setuptools"
    pip_download setuptools

    pkgs=("${!1}")
    for package in ${pkgs[@]}; do
        echo $package
        # download packages to the local pip cache
        pip_download $package --no-binary=:all:
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
    # XXX This means we are now pinning to 10.0.0, to prevent issues on pip
    # mismtaching versions, but also that we need to revisit this when newer
    # options are needed. ``easy_install`` is a must on systems with ancient
    # versions of pip that break with newer versions of pkg_resources that come
    # with the virtualenv. Doing an initial upgrade with easy_install
    # circumvents the problem
    $VENV/easy_install --upgrade pip
    $VENV/pip install "pip==10.0.0"

    echo "Updating setuptools"
    pip_download setuptools

    pkgs=("${!1}")
    for package in ${pkgs[@]}; do
        echo $package
        # download packages to the local pip cache
        pip_download $package
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
        bionic*)
            DIST=bionic
            DISTRO="ubuntu"
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
    local use_gcc=$1

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
    [ "$DIST" = "bionic" ] && os="ubuntu"

    if [ $os = "debian" ]; then
        mirror="http://www.gtlib.gatech.edu/pub/debian"
        if [ "$DIST" = "jessie" ]; then
          # despite the fact we're building for jessie, pbuilder was failing due to
          # missing wheezy key 8B48AD6246925553.  Pointing pbuilder at the archive
          # keyring takes care of it.
          debootstrapopts='DEBOOTSTRAPOPTS=( "--keyring" "/usr/share/keyrings/debian-archive-keyring.gpg" )'
        else
          # this assumes that newer Debian releases are being added to
          # /etc/apt/trusted.gpg that is also the default location for Ubuntu trusted
          # keys. The slave should ensure that the needed keys are added accordingly
          # to this location.
          debootstrapopts='DEBOOTSTRAPOPTS=( "--keyring" "/etc/apt/trusted.gpg" )'
        fi
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
    file_size_kb=`test -f $pbuild_tar && du -k "$pbuild_tar" | cut -f1 || echo 0`

    if [ "$is_not_tar" = "1" ]; then
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

    if [ -n "$use_gcc" ]; then
        # Newer pbuilder versions set $HOME to /nonexistent which breaks all kinds of
        # things that rely on a proper (writable) path. Setting this to the system user's $HOME is not enough
        # because of how pbuilder uses a chroot environment for builds, using a temporary directory here ensures
        # that writes will be successful.
        echo "BUILD_HOME=`mktemp -d`" >> ~/.pbuilderrc
        # Some Ceph components will want to use cached wheels that may have older versions of buggy executables
        # like: /usr/share/python-wheels/pip-8.1.1-py2.py3-none-any.whl which causes errors that are already fixed
        # in newer versions. This ticket solves the specific issue in 8.1.1 (which vendors urllib3):
        # https://github.com/shazow/urllib3/issues/567
        echo "USENETWORK=yes" >> ~/.pbuilderrc
        setup_pbuilder_for_ppa >> ~/.pbuilderrc
        install_extra_packages >> ~/.pbuilderrc
    fi
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

use_ppa() {
    case $vers in
        10.*)
            # jewel
            use_ppa=false;;
        11.*)
            # kraken
            use_ppa=false;;
        12.*)
            # luminous
            use_ppa=false;;
        *)
            # mimic, nautilus, *
            case $DIST in
                trusty)
                    use_ppa=true;;
                xenial)
                    use_ppa=true;;
                *)
                    use_ppa=false;;
            esac
            ;;
    esac
    $use_ppa
}

setup_gcc_hook() {
    new=$1
    cat <<EOF
old=\$(gcc -dumpversion)
if dpkg --compare-versions \$old eq $new; then
    return
fi

case \$old in
    4*)
        old=4.8;;
    5*)
        old=5;;
    7*)
        old=7;;
    8*)
        old=8;;
esac

update-alternatives --remove-all gcc

update-alternatives \
  --install /usr/bin/gcc gcc /usr/bin/gcc-${new} 20 \
  --slave   /usr/bin/g++ g++ /usr/bin/g++-${new}

update-alternatives \
  --install /usr/bin/gcc gcc /usr/bin/gcc-\${old} 10 \
  --slave   /usr/bin/g++ g++ /usr/bin/g++-\${old}

update-alternatives --auto gcc

# cmake uses the latter by default
ln -nsf /usr/bin/gcc /usr/bin/\$(arch)-linux-gnu-gcc
ln -nsf /usr/bin/g++ /usr/bin/\$(arch)-linux-gnu-g++
EOF
}

setup_pbuilder_for_new_gcc() {
    # point gcc,g++ to the newly installed ones
    local hookdir=$1
    shift
    local version=$1
    shift

    # need to add the test repo and install gcc-7 after
    # `pbuilder create|update` finishes apt-get instead of using "extrapackages".
    # otherwise installing gcc-7 will leave us a half-configured build-essential
    # and gcc-7, and `pbuilder` command will fail. because the `build-essential`
    # depends on a certain version of gcc which is upgraded already by the one
    # in test repo.
    if [ "$ARCH" = "arm64" ]; then
        cat > $hookdir/D05install-gcc-7 <<EOF
echo "deb [lang=none] http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu $DIST main" >> \
  /etc/apt/sources.list.d/ubuntu-toolchain-r.list
echo "deb [lang=none] http://ports.ubuntu.com/ubuntu-ports $DIST-updates main" >> \
  /etc/apt/sources.list.d/ubuntu-toolchain-r.list
EOF
    elif [ "$ARCH" = "x86_64" ]; then
        cat > $hookdir/D05install-gcc-7 <<EOF
echo "deb [lang=none] http://security.ubuntu.com/ubuntu $DIST-security main" >> \
  /etc/apt/sources.list.d/ubuntu-toolchain-r.list
echo "deb [lang=none] http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu $DIST main" >> \
  /etc/apt/sources.list.d/ubuntu-toolchain-r.list
echo "deb [arch=amd64 lang=none] http://mirror.cs.uchicago.edu/ubuntu-toolchain-r $DIST main" >> \
  /etc/apt/sources.list.d/ubuntu-toolchain-r.list
echo "deb [arch=amd64,i386 lang=none] http://mirror.yandex.ru/mirrors/launchpad/ubuntu-toolchain-r $DIST main" >> \
  /etc/apt/sources.list.d/ubuntu-toolchain-r.list
EOF
    else
        echo "unsupported arch: $ARCH"
        exit 1
    fi
cat >> $hookdir/D05install-gcc-7 <<EOF
cat << ENDOFKEY | apt-key add -
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: SKS 1.1.6
Comment: Hostname: keyserver.ubuntu.com

mI0ESuBvRwEEAMi4cDba7xlKaaoXjO1n1HX8RKrkW+HEIl79nSOSJyvzysajs7zUow/OzCQp
9NswqrDmNuH1+lPTTRNAGtK8r2ouq2rnXT1mTl23dpgHZ9spseR73s4ZBGw/ag4bpU5dNUSt
vfmHhIjVCuiSpNn7cyy1JSSvSs3N2mxteKjXLBf7ABEBAAG0GkxhdW5jaHBhZCBUb29sY2hh
aW4gYnVpbGRziLYEEwECACAFAkrgb0cCGwMGCwkIBwMCBBUCCAMEFgIDAQIeAQIXgAAKCRAe
k3eiup7yfzGKA/4xzUqNACSlB+k+DxFFHqkwKa/ziFiAlkLQyyhm+iqz80htRZr7Ls/ZRYZl
0aSU56/hLe0V+TviJ1s8qdN2lamkKdXIAFfavA04nOnTzyIBJ82EAUT3Nh45skMxo4z4iZMN
msyaQpNl/m/lNtOLhR64v5ZybofB2EWkMxUzX8D/FQ==
=LcUQ
-----END PGP PUBLIC KEY BLOCK-----
ENDOFKEY
# import PPA's signing key into APT's keyring
env DEBIAN_FRONTEND=noninteractive apt-get update -y -o Acquire::Languages=none -o Acquire::Translation=none || true
env DEBIAN_FRONTEND=noninteractive apt-get install -y g++-$version
EOF

    chmod +x $hookdir/D05install-gcc-7

    setup_gcc_hook $version > $hookdir/D10update-gcc-alternatives
    chmod +x $hookdir/D10update-gcc-alternatives
}

setup_pbuilder_for_old_gcc() {
    # point gcc,g++ to the ones shipped by distro
    local hookdir=$1
    case $DIST in
        trusty)
            old=4.8;;
        xenial)
            old=5;;
        bionic)
            old=8;;
    esac
    setup_gcc_hook $old > $hookdir/D10update-gcc-alternatives
    chmod +x $hookdir/D10update-gcc-alternatives
}

setup_pbuilder_for_ppa() {
    local hookdir
    if use_ppa; then
        hookdir=$HOME/.pbuilder/hook.d
        rm -rf $hookdir
        mkdir -p $hookdir
        setup_pbuilder_for_new_gcc $hookdir 7
    else
        hookdir=$HOME/.pbuilder/hook-old-gcc.d
        rm -rf $hookdir
        mkdir -p $hookdir
        setup_pbuilder_for_old_gcc $hookdir
    fi
    echo "HOOKDIR=$hookdir"
}

install_extra_packages() {
    case $vers in
        1[0-2].*)
            # jewel, kraken, luminous
            ;;
        *)
            # mimic, nautilus, *
            case $DIST in
                trusty|xenial)
                    ;;
                bionic)
                    echo 'EXTRAPACKAGES="g++-8"';;
                *)
                    ;;
            esac
            ;;
    esac
}

extra_cmake_args() {
    # statically link against libstdc++ for building new releases on old distros
    if use_ppa; then
        echo "-DWITH_STATIC_LIBSTDCXX=ON"
    fi
}

prune_stale_vagrant_vms() {
    # Vagrant VMs might be stale from a previous run. Seen only with libvirt as
    # a provider, the VMs appear in "prepare" state as reported by ``vagrant
    # global-status``. The fix is to ensure the ``.vagrant/machines`` dir is
    # removed, and then call the ``vagrant global-status --prune`` to clean up
    # reporting.
    # See: https://github.com/SUSE/pennyworth/wiki/Troubleshooting#missing-domain

    # Usage examples:

    # Global workspace search with extended globbing (will only look into tests directories):
    #
    #   prune_stale_vagrant_vms $WORKSPACE/../**/tests
    #
    # Current worspace only:
    #
    #   prune_stale_vagrant_vms

    # Allow an optional search path, for faster searching on the global
    # workspace
    case "$1" in
        *\*\**)
            SEARCH_PATH=$1
            ;;
        *)
            SEARCH_PATH="$WORKSPACE"
            ;;
    esac

    # set extended pattern globbing
    shopt -s globstar

    # From the global workspace path, find any machine stale from other jobs
    sudo find $SEARCH_PATH -type d -wholename '*/.vagrant/machines' -exec rm -rv {} +

    # unset extended pattern globbing, to prevent messing up other functions
    shopt -u globstar

    # Make sure anything stale has been removed from reporting, without halting
    # everything if it fails
    vagrant global-status --prune || true
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
    if test -f /etc/redhat-release; then
        sudo service libvirtd restart
    else
        sudo service libvirt-bin restart
    fi
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

start_tox() {
# the $SCENARIO var is injected by the job template. It maps
# to an actual, defined, tox environment
while true; do
  case $1 in
    CEPH_DOCKER_IMAGE_TAG=?*)
      local ceph_docker_image_tag=${1#*=}
      shift
      ;;
    RELEASE=?*)
      local release=${1#*=}
      shift
      ;;
    *)
      break
      ;;
  esac
done
if [ "$release" = "dev" ]; then
    # dev runs will need to be set to the release
    # that matches what the current ceph master
    # branch is at
    local release="nautilus"
fi
TOX_RUN_ENV=("timeout 3h")
if [ -n "$ceph_docker_image_tag" ]; then
  TOX_RUN_ENV=("CEPH_DOCKER_IMAGE_TAG=$ceph_docker_image_tag" "${TOX_RUN_ENV[@]}")
fi
if [ -n "$release" ]; then
  TOX_RUN_ENV=("CEPH_STABLE_RELEASE=$release" "${TOX_RUN_ENV[@]}")
else
  TOX_RUN_ENV=("CEPH_STABLE_RELEASE=$RELEASE" "${TOX_RUN_ENV[@]}")
fi

function build_job_name() {
  local job_name=$1
  shift
  for item in "$@"; do
    job_name="${job_name}-${item}"
  done
  echo "${job_name}"
}

# shellcheck disable=SC2153
ENV_NAME="$(build_job_name "$RELEASE" "$DISTRIBUTION" "$DEPLOYMENT" "$SCENARIO")"

case $SCENARIO in
  update)
    TOX_INI_FILE=tox-update.ini
    ;;
  dashboard)
    TOX_INI_FILE=tox-dashboard.ini
    ;;
  podman)
    TOX_INI_FILE=tox-podman.ini
    ;;
  *)
    TOX_INI_FILE=tox.ini
    ;;
esac

for tox_env in $("$VENV"/tox -c "$TOX_INI_FILE" -l)
do
  if [[ "$ENV_NAME" == "$tox_env" ]]; then
# shellcheck disable=SC2116
    if ! eval "$(echo "${TOX_RUN_ENV[@]}")" "$VENV"/tox -c "$TOX_INI_FILE" --workdir="$TEMPVENV" -v -e="$ENV_NAME" -- --provider=libvirt; then echo "ERROR: Job didn't complete successfully or got stuck for more than 3h."
      exit 1
    fi
    return 0
  fi
done
echo "ERROR: Environment $ENV_NAME is not defined in tox.ini!"
exit 1
}

github_status_setup() {

    # This job is meant to be triggered from a Github Pull Request, only when the
    # job is executed in that way a few "special" variables become available. So
    # this build script tries to use those first but then it will try to figure it
    # out using Git directly so that if triggered manually it can attempt to
    # actually work.
    SHA=$ghprbActualCommit
    BRANCH=$ghprbSourceBranch


    # Find out the name of the remote branch from the Pull Request. This is otherwise not
    # available by the plugin. Without grepping for `heads` output will look like:
    #
    # 855ce630695ed9ca53c314b7e261ec3cc499787d    refs/heads/wip-volume-tests
    if [ -z "$ghprbSourceBranch" ]; then
        BRANCH=`git ls-remote origin | grep $GIT_PREVIOUS_COMMIT | grep heads | cut -d '/' -f 3`
        SHA=$GIT_PREVIOUS_COMMIT
    fi

    # sometimes, $GIT_PREVIOUS_COMMIT will not help grep from ls-remote, so we fallback
    # to looking for GIT_COMMIT (e.g. if the branch has not been rebased to be the tip)
    if [ -z "$BRANCH" ]; then
        BRANCH=`git ls-remote origin | grep $GIT_COMMIT | grep heads | cut -d '/' -f 3`
        SHA=$GIT_COMMIT
    fi

    # Finally, we verify one last time to bail if nothing really worked here to determine
    # this
    if [ -z "$BRANCH" ]; then
        echo "Could not determine \$BRANCH var from \$ghprbSourceBranch"
        echo "or by using \$GIT_PREVIOUS_COMMIT and \$GIT_COMMIT"
        exit 1
    fi

    # if ghprbActualCommit is not available, and the previous checks were not able to determine
    # the SHA1, then the last attempt should be to try and set it to the env passed in as a parameter (GITHUB_SHA)
    SHA="${ghprbActualCommit:-$GITHUB_SHA}"
    if [ -z "$SHA" ]; then
        echo "Could not determine \$SHA var from \$ghprbActualCommit"
        echo "or by using \$GIT_PREVIOUS_COMMIT or \$GIT_COMMIT"
        echo "or even looking at the \$GITHUB_SHA parameter for this job"
        exit 1
    fi

}

write_collect_logs_playbook() {
    cat > $WORKSPACE/collect-logs.yml << EOF
- hosts: all
  become: yes
  tasks:
    - name: find ceph config file and logs
      find:
        paths:
          - /etc/ceph
          - /var/log/ceph
        patterns:
          - "*.conf"
          - "*.log"
      register: results

    - name: collect ceph config file and logs
      fetch:
        src: "{{ item.path }}"
        dest: "{{ archive_path }}/{{ inventory_hostname }}/"
        flat: yes
      with_items: "{{ results.files }}"

    - name: show ceph status
      command: "ceph --cluster {{ (item.path | basename | splitext)[0] }} -s -f json"
      with_items: "{{ results.files }}"
      when: "'.conf' in item.path"
      run_once: True
      delegate_to: mon0
EOF
}

collect_ceph_logs() {
    # this is meant to be run in a testing scenario directory
    # with running vagrant vms. the ansible playbook will connect
    # to your test nodes and fetch any ceph logs that are present
    # in /var/log/ceph and store them on the jenkins slave.
    # these logs can then be archived using the JJB archive publisher
    limit=$1

    if [ -f "./vagrant_ssh_config" ]; then
        mkdir -p $WORKSPACE/logs

        write_collect_logs_playbook

        pkgs=( "ansible" )
        install_python_packages "pkgs[@]"

        export ANSIBLE_SSH_ARGS='-F ./vagrant_ssh_config'
        export ANSIBLE_STDOUT_CALLBACK='debug'
        $VENV/ansible-playbook -vv -i hosts --limit $limit --extra-vars "archive_path=$WORKSPACE/logs" $WORKSPACE/collect-logs.yml
    fi
}

teardown_vagrant_tests() {
    # collect ceph logs and teardown any running vagrant vms
    # this also cleans up any lingering livirt networks
    scenarios=$(find . | grep vagrant_ssh_config | xargs dirname)

    for scenario in $scenarios; do
        cd $scenario
        # collect all ceph logs from all test nodes
        collect_ceph_logs all
        vagrant destroy -f
        stat ./fetch > /dev/null 2>&1 && rm -rf ./fetch
        cd -
    done

    # Sometimes, networks may linger around, so we must ensure they are killed:
    networks=`sudo virsh net-list --all | grep active | egrep -v "(default|libvirt)" | cut -d ' ' -f 2`
    for network in $networks; do
        sudo virsh net-destroy $network || true
        sudo virsh net-undefine $network || true
    done

    # For when machines get stuck in state: preparing
    # https://github.com/SUSE/pennyworth/wiki/Troubleshooting#missing-domain
    for dir in $(sudo find $WORKSPACE | grep '.vagrant/machines'); do
      rm -rf "$dir/*"
    done

    vagrant global-status --prune
}

get_nr_build_jobs() {
    # assume each compiling job takes 2200 MiB memory on average
    local nproc=$(nproc)
    local max_build_jobs=$(vmstat --stats --unit m | \
                               grep 'total memory' | \
                               awk '{print int($1/2200)}')
    if [[ $max_build_jobs -eq 0 ]]; then
        # probably the system is under high load, use a safe number
        max_build_jobs=16
    fi
    if [[ $nproc -ge $max_build_jobs ]]; then
        n_build_jobs=$max_build_jobs
    else
        n_build_jobs=$nproc
    fi
    echo $n_build_jobs
}
