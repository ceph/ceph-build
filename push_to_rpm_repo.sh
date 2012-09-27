#!/bin/bash

set -e

releasedir=$1
repo=$2
cephvers=$3

keyid=17ED316D

usage() {
    echo "usage: $0 releasedir repodir version component"
}

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$repo" ] && echo specify reprepro dir && usage && exit 1
[ -z "$cephvers" ] && echo specify version && usage && exit 1
[ ! -d "$releasedir/$cephvers" ] && echo missing $releasedir/$cephvers && usage && exit 1

bindir=`dirname $0`

echo version $cephvers
#echo component $component

mkdir -p $repo

# For each distribution that we've built
for dist in `ls -1 $releasedir/$cephvers/rpm`
do
    echo dist $dist
    # build and sign yum index in release directory
    $bindir/gen_yum_repo.sh $releasedir/$cephvers/rpm/$dist $keyid $dist
    # stage the results
    for dir in $releasedir/$cephvers/rpm/$dist/RPMS/*
    do
        mkdir -p $repo/$cephvers/$dist
        cp -a $dir  $repo/$cephvers/$dist/.
    done
done

echo done
