#!/bin/bash

set -e

releasedir=$1
cephvers=$2
keyid=$3

[ -z "$releasedir" ] && echo specify releasedir && exit 1
[ -z "$cephvers" ] && echo specify version && exit 1
[ ! -d "$releasedir/$cephvers" ] && echo missing $releasedir/$cephvers && exit 1

[ -z "$keyid" ] && keyid="03C3951A"

echo version $cephvers

yes | debsign -k$keyid $releasedir/$cephvers/*.{changes,dsc}
