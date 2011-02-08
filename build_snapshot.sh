#!/bin/sh -x

bindir=`dirname $0`
releasedir=$1
pbuilddir=$2

[ -z "$releasedir" ] && exit 1
[ -z "$pbuilddir" ] && exit 1

versionfile=`mktemp`
cleanup() {
    rm $versionfile
}
trap cleanup SIGINT EXIT

$bindir/release_tarball.sh $releasedir $versionfile dosuffix
vers=`cat $versionfile`

$bindir/build_dsc.sh $releasedir $vers
sudo $bindir/build_debs.sh $releasedir $pbuilddir $vers
$bindir/sign_debs.sh $releasedir $vers

