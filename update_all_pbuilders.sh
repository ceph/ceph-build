#!/bin/sh -x

set -e

bindir=`dirname $0`

pids=""
for rem in `cat $bindir/deb_hosts`
do
    echo rem $rem
    ssh $rem sudo rm -rf /tmp/ceph-build.\* \; sudo mkdir -p /srv/debian-base
    ssh $rem git clone git://github.com/ceph/ceph-build /tmp/ceph-build.$$
    ssh $rem sudo /tmp/ceph-build.$$/update_pbuilder.sh /srv/debian-base
    pids="$pids $!"
done

echo pids $pids
for p in $pids
do
    wait $p
done

