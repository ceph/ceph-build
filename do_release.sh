#!/bin/sh -x

set -e

bindir=`dirname $0`

usage() {
    echo "usage: $0 releasedir [dists]"
}

releasedir=$1
shift
dists="$*"

[ -z "$releasedir" ] && usage && exit 1

rhosts="localhost lenny32-packager.dreamhost.com"

versionfile=`mktemp`
cleanup() {
    [ -n "$pids" ] && kill $pids
    rm $versionfile
    [ -n "$vers" ] && rm -rf $releasedir/$vers
}
trap cleanup INT EXIT

rm $releasedir/* || true

$bindir/release_tarball.sh $releasedir $versionfile
vers=`cat $versionfile`

$bindir/build_dsc.sh $releasedir $vers 1 $dists
$bindir/sign_debs.sh $releasedir $vers 288995c8 dsc

for rem in $rhosts
do
    ssh root@$rem rm -r /tmp/release \; mkdir -p /tmp/release || true
    scp -rp $releasedir/$vers root@$rem:/tmp/release/$vers
    xterm -e ssh root@$rem /home/sage/ceph-build/build_debs.sh /tmp/release /home/sage/debian-base $vers &
    pids="$pids $!"
done

for p in $pids
do
    wait $p
done
pids=""

for rem in $rhosts
do
    rsync -auv root@$rem:/tmp/release/$vers/\*.\{changes\,deb\} $releasedir/$vers
done

$bindir/sign_debs.sh $releasedir $vers 288995c8 changes

# probably a better way, but
rm $versionfile

trap true INT EXIT

exit 0
