#!/bin/bash

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

echo version $cephvers

for w in $what
do
    yes | debsign -k$keyid $releasedir/$cephvers/*.$w
done

