#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab
#
# Script: Python Virtual Environment and Package Installer

create_venv_dir() {
    local venv_dir
    venv_dir=$(mktemp -td venv.XXXXXXXXXX)
    trap "rm -rf ${venv_dir}" EXIT
    echo "${venv_dir}"
}

create_virtualenv () {
    local path=$1
    if [ -d $path ]; then
        echo "Will reuse existing virtual env: $path"
    else
        if command -v python3 > /dev/null; then
            python3 -m venv $path
        else
            virtualenv -p python $path
        fi
    fi
}

pip_download() {
    local venv=$1
    shift
    local package=$1
    shift
    local options=$@
    if ! $venv/pip download $options --dest="$PIP_SDIST_INDEX" $package; then
        # pip <8.0.0 does not have "download" command
        $venv/pip install $options \
                  --upgrade --exists-action=i --cache-dir="$PIP_SDIST_INDEX" \
                  $package
    fi
}


install_python_packages () {
    local venv_dir=$1
    shift
    local venv="$venv_dir/bin"
    # Use this function to create a virtualenv and install
    # python packages. Pass a list of package names.
    #
    # Usage (with pip 24.0 [the default]):
    #
    #   to_install=( "ansible" "chacractl>=0.0.21" )
    #   install_python_packages $TEMPVENV "to_install[@]"
    #
    # Usage (with pip<X.X.X [can also do ==X.X.X or !=X.X.X]):
    #
    #   to_install=( "ansible" "chacractl>=0.0.21" )
    #   install_python_packages_no_binary $TEMPVENV "to_install[@]" "pip<X.X.X"
    #
    # Usage (with latest pip):
    #
    #   to_install=( "ansible" "chacractl>=0.0.21" )
    #   install_python_packages $TEMPVENV "to_install[@]" latest

    create_virtualenv $venv_dir

    # Define and ensure the PIP cache
    PIP_SDIST_INDEX="$HOME/.cache/pip"
    mkdir -p $PIP_SDIST_INDEX

    # Avoid UnicodeErrors when installing packages.
    # See https://github.com/ceph/ceph/pull/42811
    export LC_ALL=en_US.UTF-8

    if [ "$2" == "latest" ]; then
        echo "Ensuring latest pip is installed"
        $venv/pip install -U pip
    elif [[ -n $2 && "$2" != "latest" ]]; then
        echo "Installing $2"
        $venv/pip install "$2"
    else
        # This is the default for most jobs.
        # See ff01d2c5 and fea10f52
        echo "Installing pip 24.0"
        $venv/pip install "pip==24.0"
    fi

    echo "Ensuring latest wheel is installed"
    $venv/pip install -U wheel

    echo "Updating setuptools"
    pip_download $venv setuptools

    pkgs=("${!1}")
    for package in ${pkgs[@]}; do
        echo $package
        # download packages to the local pip cache
        pip_download $venv $package
        # install packages from the local pip cache, ignoring pypi
        $venv/pip install --upgrade --exists-action=i --find-links="file://$PIP_SDIST_INDEX" --no-index $package
    done

    # See https://tracker.ceph.com/issues/59652
    echo "Pinning urllib3 and requests"
    $venv/pip install "urllib3<2.0.0"
    $venv/pip install "requests<2.30.0"
}