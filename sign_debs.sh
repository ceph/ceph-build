#!/bin/bash -x

set -e

usage() {
    echo "usage: $0 releasedir vers key [filetypetosign] [resultdir]"
}

releasedir=$1
cephvers=$2
keyid=$3
what=$4
resultdir=$5

[ -z "$what" ] && what="dsc changes"

[ -z "$releasedir" ] && echo specify releasedir && usage && exit 1
[ -z "$cephvers" ] && echo specify version && usage && exit 1
[ ! -d "$releasedir/$cephvers" ] && echo missing $releasedir/$cephvers && usage && exit 1
if [ -n "$resultdir" ] ; then
    resultdir=$releasedir/$cephvers/$resultdir
    [ ! -d "$resultdir" ] && echo missing $resultdir && usage && exit 1
fi


[ -z "$keyid" ] && echo specify keyid && exit 1

echo version $cephvers

echo "signing $releasedir/$cephvers/*.$w"
for w in $what
do
    if [ -n "$resultdir" -a -d "$resultdir" ] ; then
        ( cd $resultdir ; yes | debsign -k$keyid *.$w )
    else
        yes | debsign -k$keyid $releasedir/$cephvers/*.$w
    fi
done

