#!/bin/bash

set -e

releasedir=$1
repo=$2
cephvers=$3
component=$4

[ -z "$releasedir" ] && echo specify releasedir && exit 1
[ -z "$repo" ] && echo specify reprepro dir && exit 1
[ -z "$cephvers" ] && echo specify version && exit 1
[ ! -d "$releasedir/$cephvers" ] && echo missing $releasedir/$cephvers && exit 1
[ -z "$component" ] && echo "must specify repo component" && exit 1

bindir=`dirname $0`

echo version $cephvers
echo component $component

[ -z "$dists" ] && dists=`cat $releasedir/$cephvers/debian_dists`
dvers=`cat $releasedir/$cephvers/debian_version`
echo deb vers $dvers
echo dists $dists


for dist in $dists
do
    bpvers=`$bindir/gen_debian_version.sh $dvers $dist`
    echo dist $dist
    echo vers $bpvers
    for f in $releasedir/$cephvers/*${bpvers}_*.changes
    do
	echo file $f
	reprepro -b $repo -C $component --ignore=wrongdistribution include $dist $f
    done
done
