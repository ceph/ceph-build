#!/bin/bash

set -e

releasedir=$1
repo=$2
cephvers=$3

keyid=17ED316D

usage() {
    echo "usage: $0 releasedir repodir version"
}

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$repo" ] && echo specify reprepro dir && usage && exit 1
[ -z "$cephvers" ] && echo specify version && usage && exit 1
[ ! -d "$releasedir/$cephvers" ] && echo missing $releasedir/$cephvers && usage && exit 1

bindir=`dirname $0`

echo version $cephvers

#
#  Sign rpms and create repo index

#echo "signing rpms"
$bindir/sign_rpms.sh $repo $cephvers $keyid

# Construct repodata
#  repo/dist/*
#for dir in $repo/*/*
for dir in $repo/$cephvers/*/*
do
    echo "indexing $dir"
    if [ -d $dir ] ; then
        createrepo $dir
        gpg --batch --yes --detach-sign --armor -u $keyid $dir/repodata/repomd.xml
    fi
done

echo done
