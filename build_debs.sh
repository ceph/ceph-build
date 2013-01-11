#!/bin/bash -x

set -e

bindir=`dirname $0`

usage() {
    echo "usage: $0 releasedir pbuilddir ver [dists]"
}

releasedir=$1
pbuilddir=$2
cephver=$3
dists=$4

[ -z "$releasedir" ] && echo specify release dir && usage && exit 1
[ -z "$pbuilddir" ] && echo specify pbuilder image dir && usage && exit 1
[ -z "$cephver" ] && echo specify version && usage && exit 1

start_time=`date`
echo version $cephver

whoami=`whoami`
[ "$whoami" != "root" ] && echo "must run as root not $whoami" && usage && exit 1

[ -z "$dists" ] && dists=`cat $releasedir/$cephver/debian_dists`
dvers=`cat $releasedir/$cephver/debian_version`
echo deb vers $dvers
echo dists $dists

for dist in $dists
do
    pbuilder --clean

    bpvers=`$bindir/gen_debian_version.sh $dvers $dist`
    echo deb vers $bpvers

#[ "$dist" = "sid" ] && dist="wheezy"

#    $bindir/update_pbuilder.sh $pbuilddir $dist

    echo building debs for $dist
    if [ `dpkg-architecture -qDEB_BUILD_ARCH` = "i386" ] ; then
        #  Architecture dependent, independent and source
        pbuilder build \
            --distribution $dist \
            --basetgz $pbuilddir/$dist.tgz \
            --buildresult $releasedir/$cephver \
            --debbuildopts "-j`grep -c processor /proc/cpuinfo`" \
            $releasedir/$cephver/ceph_$bpvers.dsc
    else
        #  Binary only architecture dependent
        pbuilder build \
            --binary-arch \
            --distribution $dist \
            --basetgz $pbuilddir/$dist.tgz \
            --buildresult $releasedir/$cephver \
            --debbuildopts "-j`grep -c processor /proc/cpuinfo`" \
            $releasedir/$cephver/ceph_$bpvers.dsc
    fi
 
done

# do lintian checks
for dist in $dists
do
    bpvers=`$bindir/gen_debian_version.sh $dvers $dist`
    echo lintian checks for $bpvers
    echo lintian --allow-root $releasedir/$cephver/*$bpvers*.deb
done

echo "Start Time = $start_time"
echo "  End Time = $(date)" 
