#!/bin/bash -x

set -e

usage() {
    echo "usage: $0 repodir vers key"
}

repodir=$1
cephvers=$2
keyid=$3
bindir=`dirname $0`

[ -z "$repodir" ] && echo specify repodir && usage && exit 1
[ -z "$cephvers" ] && echo specify version && usage && exit 1
[ ! -d "$repodir/$cephvers" ] && echo missing $repodir/$cephvers && usage && exit 1

[ -z "$keyid" ] && echo specify keyid && exit 1

echo "signing rpms, version $cephvers key $keyid"

# Sign all the RPMs for this release
#rpm --addsign --define "_gpg_name $keyid" $rpm
#use expect wrapper to supply null passphrase

for rpm in `find ${repodir}/${cephvers} -name "*.rpm"`
do
    $bindir/rpm-autosign.exp --define "_gpg_name $keyid" $rpm
done

echo done
