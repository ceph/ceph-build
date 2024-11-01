#!/bin/bash
# vim: ts=4 sw=4 expandtab

set -ex

function write_sccache_conf() {
  export SCCACHE_CONF=$WORKSPACE/sccache.conf
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
  SCCACHE_URL="https://github.com/mozilla/sccache/releases/download/v0.8.2/sccache-v0.8.2-$(uname -m)-unknown-linux-musl.tar.gz"
  curl -L $SCCACHE_URL | sudo tar --no-anchored --strip-components=1 -C /usr/local/bin/ -xzf - sccache
}
