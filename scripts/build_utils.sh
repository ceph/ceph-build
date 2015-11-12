#!/bin/bash

set -ex

VENV="$WORKSPACE/venv/bin"

install_python_packages () {
    # Use this function to create a virtualenv and install
    # python packages. Pass a list of package names.
    #
    # Usage:
    #
    #   to_install=( "ansible" "chacractl>=0.0.4" )
    #   install_python_packages "to_install[@]" 

    # Create the virtualenv
    virtualenv $WORKSPACE/venv

    # Define and ensure the PIP cache
    PIP_SDIST_INDEX="$HOME/.cache/pip"
    mkdir -p $PIP_SDIST_INDEX

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
cat > $HOME/.chacractl << EOF
url = "$CHACRACTL_URL"
user = "$CHACRACTL_USER"
key = "$CHACRACTL_KEY"
EOF
}
