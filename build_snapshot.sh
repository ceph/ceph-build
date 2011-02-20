#!/bin/sh -x

set -e

bindir=`dirname $0`
releasedir=$1
pbuilddir=$2
shift
shift
dists="$*"

[ -z "$releasedir" ] && exit 1
[ -z "$pbuilddir" ] && exit 1

versionfile=`mktemp`
cleanup() {
    rm $versionfile
    [ -n "$vers" ] && rm -rf $releasedir/$vers
}
trap cleanup INT EXIT

$bindir/release_tarball.sh $releasedir $versionfile dosuffix
vers=`cat $versionfile`

$bindir/build_dsc.sh $releasedir $vers 1 $dists

sudo $bindir/build_debs.sh $releasedir $pbuilddir $vers
$bindir/sign_debs.sh $releasedir $vers

# probably a better way, but
rm $versionfile

trap true INT EXIT

exit 0