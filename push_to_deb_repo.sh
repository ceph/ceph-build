#!/bin/bash

set -e

releasedir=$1
repo=$2
cephvers=$3
component=$4

usage() {
    echo "usage: $0 releasedir repodir version component"
}

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$repo" ] && echo specify reprepro dir && usage && exit 1
[ -z "$cephvers" ] && echo specify version && usage && exit 1
[ ! -d "$releasedir/$cephvers" ] && echo missing $releasedir/$cephvers && usage && exit 1
[ -z "$component" ] && echo "must specify repo component" && usage && exit 1

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
    #for f in $releasedir/$cephvers/*${bpvers}_*.changes
    for f in `find $releasedir/$cephvers/ -name "*${bpvers}_*.changes"`
    do
	echo file $f
	reprepro --ask-passphrase -b $repo -C $component --ignore=undefinedtarget --ignore=wrongdistribution include $dist $f
    done
done
