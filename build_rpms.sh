#!/bin/sh -x

set -e

usage() {
    echo "usage: $0 releasedir vers [debsubver] [dists...]"
}

releasedir=$1
cephver=$2
subver=$3
shift
shift
shift
dists="$*"

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$cephver" ] && echo specify version && usage && exit 1
[ -z "$subver" ] && subver=1
[ -z "$dists" ] && dists="centos6"

bindir=`dirname $0`
echo "$bindir" | grep -v -q '^/' && bindir=`pwd`"/$bindir"

rpmver="$cephver-$subver"

echo rpmver $rpmver

cd $releasedir/$cephver || exit 1

# take note  XXX debian version keeping here just in case
echo $dists > rpm_dists
echo $rpmver > rpm_version

# Set up build area
BUILDAREA=./rpmbuild
mkdir -p ${BUILDAREA}/{SOURCES,SRPMS,SPECS,RPMS,BUILD}
cp -a ceph-*.tar.bz2 ${BUILDAREA}/SOURCES/.

# Build RPMs
BUILDAREA=`readlink -fn ${BUILDAREA}`   ### rpm wants absolute path
rpmbuild -bb --define "_topdir ${BUILDAREA}" --define "_unpackaged_files_terminate_build 0" ceph.spec

rm -r ceph-$cephver
echo done
