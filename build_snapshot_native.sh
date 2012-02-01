#!/bin/sh -ex

bindir=`dirname $0`

keyid="03C3951A"

usage() {
    echo "usage: $0 outdir dist"
}

outdir=$1
dist=$2

[ -z "$dist" ] && usage && exit 1

srcdir=`pwd`

numproc=`cat /proc/cpuinfo |grep -c processor`
[ -z "$numproc" ] && numproc=1
#numproc=$(($numproc * 2))

cephver=`git describe | cut -c 2-`
echo current version $cephver

rm ceph-*.tar.gz || true
make dist

tarver=`ls ceph-*.tar.gz | cut -c 6- | sed 's/.tar.gz//'`
echo tarball vers $tarver

echo extracting
mkdir -p $outdir
cd $outdir

tar zxf $srcdir/ceph-$tarver.tar.gz 
[ "$tarver" != "$cephver" ] && mv ceph-$tarver ceph-$cephver

cd ceph-$cephver
cp -av $srcdir/debian debian

debver="$cephver-1$dist"

echo $debver > ../version 

# add to changelog?
chver=`head -1 debian/changelog | perl -ne 's/.*\(//; s/\).*//; print'`
if [ "$chver" != "$debver" ]; then
    DEBEMAIL="sage@newdream.net" dch -D $dist --force-distribution -b -v "$debver" "autobuilt"
fi

# build
dpkg-buildpackage -j$numproc -k$keyid

