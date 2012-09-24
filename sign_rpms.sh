#!/bin/bash -x

set -e

usage() {
    echo "usage: $0 releasedir vers key [filetypetosign]"
}

releasedir=$1
cephvers=$2
keyid=$3
what=$4

[ -z "$what" ] && what="dsc changes"

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$cephvers" ] && echo specify version && usage && exit 1
[ ! -d "$releasedir/$cephvers" ] && echo missing $releasedir/$cephvers && usage && exit 1

[ -z "$keyid" ] && echo specify keyid && exit 1

echo version $cephvers key $keyid

# Sign all the RPMs
rpm_list=`find $releasedir/$cephvers -name "*.rpm" -print`
rpm --addsign --define "_gpg_name $keyid" $rpm_list

# Sign the repository
#for repo in `find $releasedir/$cephvers -type d -name "repodata" -print`
#do
#    gpg --detach-sign --armor -u $keyid $repo/repomd.xml
#done
