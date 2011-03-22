#!/bin/sh -x

set -e

bindir=`dirname $0`

usage() {
    echo "usage: $0 releasedir pbuilddir [dists...]"
}

releasedir=$1
pbuilddir=$2
shift
shift
dists="$*"

[ -z "$releasedir" ] && usage && exit 1
[ -z "$pbuilddir" ] && usage && exit 1

versionfile=`mktemp`
cleanup() {
    rm $versionfile
    [ -n "$vers" ] && rm -rf $releasedir/$vers
}
trap cleanup INT EXIT

rm $releasedir/* || true

$bindir/release_tarball.sh $releasedir $versionfile
vers=`cat $versionfile`

$bindir/build_dsc.sh $releasedir $vers 1 $dists
$bindir/sign_debs.sh $releasedir $vers 03C3951A dsc
sudo $bindir/build_debs.sh $releasedir $pbuilddir $vers
$bindir/sign_debs.sh $releasedir $vers 03C3951A changes

# probably a better way, but
rm $versionfile
trap true INT EXIT

exit 0
