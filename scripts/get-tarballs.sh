#!/bin/bash
# Helper to get tarballs for releases
# Does not do any placement, you must be on the destination directory.

# There are two files it grabs, one with 'orig' and one without

: ${2?"Usage: $0 \$release \$sha1 \$version"}

release=$1
sha1=$2
version=$3

pushd /data/download.ceph.com/www/prerelease/ceph/tarballs

if [ ! -f ceph_$version.orig.tar.gz ]; then
  wget https://chacra.ceph.com/binaries/ceph/$release/$sha1/ubuntu/noble/x86_64/flavors/default/ceph_$version.orig.tar.gz || wget https://chacra.ceph.com/binaries/ceph/$release/$sha1/ubuntu/jammy/x86_64/flavors/default/ceph_$version.orig.tar.gz
  wget https://chacra.ceph.com/binaries/ceph/$release/$sha1/ubuntu/noble/x86_64/flavors/default/ceph-$version.tar.gz || wget https://chacra.ceph.com/binaries/ceph/$release/$sha1/ubuntu/jammy/x86_64/flavors/default/ceph-$version.tar.gz
fi

popd

