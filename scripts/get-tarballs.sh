#!/bin/bash
# Helper script that lives on download.ceph.com to pull tarballs from chacra.ceph.com
# There are two files it grabs, one with 'orig' and one without (unsure why we need both)

: ${2?"Usage: $0 \$release \$sha1 \$version"}

release=$1
sha1=$2
version=$3

pushd /data/download.ceph.com/www/tarballs

wget https://chacra.ceph.com/binaries/ceph/$release/$sha1/ubuntu/bionic/x86_64/flavors/default/ceph_$version.orig.tar.gz -O ceph_$version.orig.tar.gz || wget https://chacra.ceph.com/binaries/ceph/$release/$sha1/ubuntu/focal/x86_64/flavors/default/ceph_$version.orig.tar.gz -O ceph_$version.orig.tar.gz
wget https://chacra.ceph.com/binaries/ceph/$release/$sha1/ubuntu/bionic/x86_64/flavors/default/ceph-$version.tar.gz -O ceph-$version.tar.gz || wget https://chacra.ceph.com/binaries/ceph/$release/$sha1/ubuntu/focal/x86_64/flavors/default/ceph-$version.tar.gz -O ceph-$version.tar.gz

popd

