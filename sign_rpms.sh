#!/bin/bash -x

set -e

usage() {
    echo "usage: $0 releasedir vers key"
}

releasedir=$1
cephvers=$2
keyid=$3
bindir=`dirname $0`

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$cephvers" ] && echo specify version && usage && exit 1
[ ! -d "$releasedir/$cephvers" ] && echo missing $releasedir/$cephvers && usage && exit 1

[ -z "$keyid" ] && echo specify keyid && exit 1

echo "signing rpms, version $cephvers key $keyid"

# Sign all the RPMs for this release
#rpm --addsign --define "_gpg_name $keyid" $rpm
#use expect wrapper to supply null passphrase

for rpm in `find ${releasedir}${cephvers}/rpm -name "*.rpm"`
do
    $bindir/rpm-autosign.exp --define "_gpg_name $keyid" $rpm
done

echo done
