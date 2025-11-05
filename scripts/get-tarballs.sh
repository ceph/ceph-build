#!/bin/bash
set -x
# Helper to get tarball for releases

: ${2?"Usage: $0 \$release \$sha1 \$version"}

release=$1
sha1=$2
version=$3

pushd /data/download.ceph.com/www/prerelease/ceph/tarballs

if [[ ! -f ceph_${version}.tar.gz ]]; then
  wget -q https://chacra.ceph.com/binaries/ceph/${release}/${sha1}/ubuntu/noble/x86_64/flavors/default/ceph_${version}-1noble.tar.gz \
   || wget -q https://chacra.ceph.com/binaries/ceph/${release}/${sha1}/ubuntu/jammy/x86_64/flavors/default/ceph_${version}-1jammy.tar.gz

  mv ceph_${version}*.tar.gz ceph-${version}.tar.gz
fi

popd
