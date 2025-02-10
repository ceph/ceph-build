#!/bin/bash
# vim: ts=4 sw=4 expandtab
set -ex
. $(dirname ${0})/build_utils.sh

cd "$WORKSPACE"
VENV="${WORKSPACE}/.venv"
python3 -m venv $VENV
pkgs=( "chacractl>=0.0.21" )
install_python_packages $VENV "pkgs[@]"

chacra_url=`curl -u $SHAMAN_API_USER:$SHAMAN_API_KEY https://shaman.ceph.com/api/nodes/next/`
make_chacractl_config $chacra_url
echo $chacra_url
