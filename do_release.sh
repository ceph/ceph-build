#!/bin/sh -x

set -e

gpgkey='17ED316D'

bindir=`dirname $0`

usage() {
    echo "usage: $0 releasedir [dists]"
}

releasedir=$1
shift || true
dists="$*"

[ -z "$releasedir" ] && usage && exit 1

deb_hosts=`cat $bindir/deb_hosts`
rpm_hosts=`cat $bindir/rpm_hosts`

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

# debian stuff
$bindir/build_dsc.sh $releasedir $vers 1 $dists
$bindir/sign_debs.sh $releasedir $vers $gpgkey dsc

for rem in $deb_hosts
do
    ssh root@$rem rm -r /tmp/release/\* \; mkdir -p /tmp/release || true
    scp -rp $releasedir/$vers root@$rem:/tmp/release/$vers
    if [ $xterm -eq 1 ]; then
	xterm -l -e ssh root@$rem /home/sage/ceph-build/build_debs.sh /tmp/release /home/sage/debian-base $vers &
    else
	ssh root@$rem /home/sage/ceph-build/build_debs.sh /tmp/release /home/sage/debian-base $vers > build.$rem 2>&1 &
    fi
    pids="$pids $!"
done

# rpm stuff
for rem in $rpm_hosts
do
    ssh root@$rem rm -r /tmp/release/\* \; mkdir -p /tmp/release || true
    scp -rp $releasedir/$vers root@$rem:/tmp/release/$vers
    exit
    if [ $xterm -eq 1 ]; then
	xterm -l -e ssh root@$rem ceph-build/build_rpms.sh /tmp/release $vers &
    else
	ssh root@$rem ceph-build/build_rpms.sh /tmp/release $vers > build.$rem 2>&1 &
    fi
    pids="$pids $!"
done

for p in $pids
do
    wait $p
done
pids=""

for rem in $deb_hosts $rpm_hosts
do
   rsync -auv root@$rem:/tmp/release/$vers/\*.\{changes\,deb\} $releasedir/$vers
done

$bindir/sign_debs.sh $releasedir $vers $gpgkey changes
$bindir/sign_rpms.sh $releasedir $vers $gpgkey

# probably a better way, but
rm $versionfile

trap true INT EXIT

exit 0
