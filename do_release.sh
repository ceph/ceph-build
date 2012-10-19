#!/bin/sh -x

set -e

xterm=${xterm:-0}	# set to 1 to use xterm for remote sessions
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

# debs
$bindir/build_dsc.sh $releasedir $vers 1 $dists
$bindir/sign_debs.sh $releasedir $vers $gpgkey dsc

for rem in $deb_hosts
do
    ssh $rem sudo rm -r /tmp/release/\* \; sudo mkdir -p /tmp/release \; sudo rm -r /tmp/ceph-build.\* || true
    scp -rp $releasedir/$vers $rem:/tmp/release/$vers
    ssh $rem git clone git://github.com/ceph/ceph-build /tmp/ceph-build.$$
    if [ $xterm -eq 1 ]; then
	xterm -l -e ssh $rem sudo /tmp/ceph-build.$$/build_debs.sh /tmp/release /srv/debian-base $vers &
    else
	ssh $rem sudo /tmp/ceph-build.$$/build_debs.sh /tmp/release /srv/debian-base $vers > build.$rem 2>&1 &
    fi
    pids="$pids $!"
done

# rpms
for rem in $rpm_hosts
do
    ssh $rem sudo rm -r /tmp/release/\* \; sudo mkdir -p /tmp/release \; sudo rm -r /tmp/ceph-build.\* || true
    scp -rp $releasedir/$vers $rem:/tmp/release/$vers
    ssh $rem git clone git://github.com/ceph/ceph-build /tmp/ceph-build.$$
    if [ $xterm -eq 1 ]; then
	xterm -l -e ssh $rem sudo /tmp/ceph-build.$$/build_rpms.sh /tmp/release $vers &
    else
	ssh $rem sudo /tmp/ceph-build.$$/build_rpms.sh /tmp/release $vers > build.$rem 2>&1 &
    fi
    pids="$pids $!"
done

# wait
for p in $pids
do
    wait $p
done

# gather results
for rem in $deb_hosts
do
   rsync -auv $rem:/tmp/release/$vers/\*.\{changes\,deb\} $releasedir/$vers
done
for rem in $rpm_hosts
do
    rsync -auv --exclude "BUILD" $rem:/tmp/release/$vers/rpm/ $releasedir/$vers/rpm
done

# sign
$bindir/sign_debs.sh $releasedir $vers $gpgkey changes
$bindir/sign_rpms.sh $releasedir $vers $gpgkey

# probably a better way, but
rm $versionfile

trap true INT EXIT

exit 0
