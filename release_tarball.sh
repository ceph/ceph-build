#!/bin/bash -x

set -e

usage() {
    echo "usage: $0 releasedir [versionfile]"
}

releasedir=$1
versionfile=$2

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1

if git diff --quiet ; then
    echo repository is clean
else
    echo
    echo "**** REPOSITORY IS DIRTY ****"
    echo
    if [ "$force" != "force" ]; then
	echo "add 'force' argument if you really want to continue."
	exit 1
    fi
    echo "forcing."
fi

cephver=`git describe --match "v*" | sed s/^v//`
echo current version $cephver

srcdir=`pwd`

if [ -d "$releasedir/$cephver" ]; then
    echo "$releasedir/$cephver already exists; reuse that release tarball"
else
    echo building tarball
    rm ceph-*.tar.gz || true
    rm ceph-*.tar.bz2 || true

    if [ -x make-dist ]; then
        ./make-dist
    else
        make dist-bzip2
    fi

    vers=`ls ceph-*.tar.bz2 | cut -c 6- | sed 's/.tar.bz2//'`
    echo tarball vers $vers

    echo extracting
    mkdir -p $releasedir/$cephver/rpm
    cp rpm/*.patch $releasedir/$cephver/rpm || true
    cd $releasedir/$cephver

    tar jxf $srcdir/ceph-$vers.tar.bz2
    [ "$vers" != "$cephver" ] && mv ceph-$vers ceph-$cephver

    tar zcf ceph_$cephver.orig.tar.gz ceph-$cephver
    cp -a ceph_$cephver.orig.tar.gz ceph-$cephver.tar.gz

    tar jcf ceph-$cephver.tar.bz2 ceph-$cephver

    # copy debian dir, too
    cp -a $srcdir/debian debian
    cd $srcdir

    # copy in spec file, too
    cp ceph.spec $releasedir/$cephver
fi

if [ -n "$versionfile" ]; then
    echo $cephver > $versionfile
    echo "wrote $cephver to $versionfile"
fi

echo "done."
