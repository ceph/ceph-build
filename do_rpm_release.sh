#!/bin/sh -x

set -e
trap cleanup INT EXIT

default_dists="centos6"     # just 1 so far
subversion="1"              # not used so far
gpgkey='3CF7ABC8'           # ceph rpm test key
#rhosts="localhost 192.168.106.235"
rhosts="localhost"
versionfile=""

cleanup() {
    [ -n "$pids" ] && kill $pids
    rm $versionfile
    [ -n "$vers" ] && rm -rf $releasedir/$vers
}

usage() {
    echo "usage: $0 releasedir [dists]"
}

bindir=`dirname $0`
releasedir=$1
shift || true
dists="$*"

[ -z "$releasedir" ] && usage && exit 1
[ -z "$dists" ] && dists=$default_dists

versionfile=`mktemp`
rm $releasedir/* || true

$bindir/release_rpm_tarball.sh $releasedir $versionfile
vers=`cat $versionfile`
echo "vers = $vers"

cp ceph.spec $releasedir/$vers/.
$bindir/build_rpms.sh $releasedir $vers $subversion $dists

$bindir/sign_rpms.sh $releasedir $vers $gpgkey

$bindir/gen_yum_repo.sh $releasedir/$vers $gpgkey $dists

# stage the results
rpmdir=$releasedir/$vers/rpmbuild
for dir in $dists
do
    distdir=$releasedir/$vers/$dir
    mkdir -p $distdir
    cp -a $rpmdir/RPMS/* $distdir/.
done
rm -rf $rpmdir

# Notes:  The debian version at this points run the build on several remote 
# hosts (pbuilders ?) and syncs the results back.
# rsync -auv root@$rem:/tmp/release/$vers/\*.\{changes\,deb\} $releasedir/$vers
# This version builds locally.  We will sort out what machine we actually
# build on later.

rm $versionfile

trap true INT EXIT

exit 0
