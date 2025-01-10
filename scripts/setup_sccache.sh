#!/bin/bash
# vim: ts=4 sw=4 expandtab

set -ex

SCCACHE_URL="https://github.com/mozilla/sccache/releases/download/v0.8.2/sccache-v0.8.2-$(uname -m)-unknown-linux-musl.tar.gz"

function write_sccache_conf() {
  export SCCACHE_CONF=${SCCACHE_CONF:-$WORKSPACE/sccache.conf}
  cat << EOF > $SCCACHE_CONF
[cache.s3]
bucket = "ceph-sccache"
endpoint = "s3.us-south.cloud-object-storage.appdomain.cloud"
use_ssl = true
key_prefix = ""
server_side_encryption = false
no_credentials = false
region = "auto"
EOF
}

function write_aws_credentials() {
  export AWS_PROFILE=default
  mkdir -p $HOME/.aws
  cat << EOF > $HOME/.aws/credentials
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
}

function install_sccache () {
  local sudo
  if [ "$(id -u)" != "0" ]; then
    sudo="sudo"
  fi
  curl -L $SCCACHE_URL | $sudo tar --no-anchored --strip-components=1 -C /usr/local/bin/ -xzf - sccache
}

function setup_pbuilderrc () {
  cat >> ~/.pbuilderrc << EOF
export SCCACHE="${SCCACHE}"
export SCCACHE_CONF=/etc/sccache.conf
export DWZ="${DWZ}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
EOF
  sudo cp ~/.pbuilderrc /root/.pbuilderrc
}

function setup_sccache_pbuilder_hook () {
  for hook_dir in $(ls -d ~/.pbuilder/hook*.d); do
    hook=$hook_dir/D09-setup-sccache
    cp $BASH_SOURCE $hook
    cat >> $hook << EOF
if [ "$SCCACHE" = true ] ; then
  write_sccache_conf
  write_aws_credentials
  install_sccache
fi
EOF
    chmod +x $hook
  done
}

function reset_sccache () {
  sccache --zero-stats
  sccache --stop-server
}
