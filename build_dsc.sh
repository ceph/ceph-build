#!/bin/sh -x

set -e

usage() {
    echo "usage: $0 releasedir vers [debsubver] [dists...]"
}

bindir=`dirname $0`
echo "$bindir" | grep -v -q '^/' && bindir=`pwd`"/$bindir"

releasedir=$1
cephver=$2
debsubver=$3
shift
shift
shift
dists="$*"

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$cephver" ] && echo specify version && usage && exit 1
[ -z "$debsubver" ] && debsubver=1
[ -z "$dists" ] && dists=`cat $bindir/deb_dists`

debver="$cephver-$debsubver"

echo debver $debver

cd $releasedir/$cephver || exit 1

echo "(re)extracting"

[ -d "ceph-$cephver" ] && rm -r ceph-$cephver
tar zxvf ceph_$cephver.orig.tar.gz

# add debian dir
echo "copying in debian/"
cp -a debian ceph-$cephver

# take note 
echo $dists > debian_dists
echo $debver > debian_version

for dist in $dists
do
    echo building $dist dsc

    bpver=`$bindir/gen_debian_version.sh $debver $dist`

    # add to changelog?
    chvers=`head -1 debian/changelog | perl -ne 's/.*\(//; s/\).*//; print'`
    if [ "$chvers" != "$bpver" ]; then
	cd ceph-$cephver
	DEBEMAIL="sage@newdream.net" dch -D $dist --force-distribution -b -v "$bpver" "$comment"
	cd ..
    fi

    # per-dist hacks
    if [ "$dist" = "lenny" ]; then
	sed -i 's/, libgoogle-perftools-dev[^,]*,/,/' ceph-$cephver/debian/control
    fi
    if [ "$dist" = "wheezy" ]; then
	grep -v babeltrace ceph-$cephver/debian/control > ceph-$cephver/debian/control.new
	mv ceph-$cephver/debian/control.new ceph-$cephver/debian/control
    fi

    dpkg-source -b ceph-$cephver

done

rm -r ceph-$cephver
echo done
