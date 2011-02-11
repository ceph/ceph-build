#!/bin/sh -x

set -e

bindir=`dirname $0`
releasedir=$1
pbuilddir=$2
dists=$3

[ -z "$releasedir" ] && exit 1
[ -z "$pbuilddir" ] && exit 1

versionfile=`mktemp`
cleanup() {
    rm $versionfile
}
trap cleanup SIGINT EXIT

$bindir/release_tarball.sh $releasedir $versionfile dosuffix
vers=`cat $versionfile`

$bindir/build_dsc.sh $releasedir $vers 1 $dists

sudo $bindir/build_debs.sh $releasedir $pbuilddir $vers
$bindir/sign_debs.sh $releasedir $vers

