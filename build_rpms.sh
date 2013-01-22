#!/bin/sh -x

set -e

usage() {
    echo "usage: $0 releasedir vers [debsubver] [dists...]"
}

releasedir=$1
cephver=$2
[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$cephver" ] && echo specify version && usage && exit 1

bindir=`dirname $0`
echo "$bindir" | grep -v -q '^/' && bindir=`pwd`"/$bindir"

dist=`$bindir/get_rpm_dist.sh`
[ -z "$dist" ] && echo no dist && exit 1
echo dist $dist

cd $releasedir/$cephver || exit 1

# Set up build area
BUILDAREA=./rpm/$dist
mkdir -p ${BUILDAREA}/{SOURCES,SRPMS,SPECS,RPMS,BUILD}
cp -a ceph-*.tar.bz2 ${BUILDAREA}/SOURCES/.
cp -a ceph-spec ${BUILDAREA}/SPECS/.

# Build RPMs
BUILDAREA=`readlink -fn ${BUILDAREA}`   ### rpm wants absolute path
cd ${BUILDAREA}/SPECS
rpmbuild -ba --define "_topdir ${BUILDAREA}" --define "_unpackaged_files_terminate_build 0" ceph.spec

echo done
