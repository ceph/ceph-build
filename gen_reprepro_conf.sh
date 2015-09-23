#!/bin/sh

set -e

bindir=`dirname $0`
path="$1"
key="$2"
[ -z "$key" ] && echo "usage: $0 <path> <gpgkeyid>" && exit 1

if [ ! -d $path -o ! -d $path/conf ] ; then
    mkdir -p $path/conf
fi

echo "$bindir" | grep -v -q '^/' && bindir=`pwd`"/$bindir"
dists=`cat $bindir/deb_dists`
components="main"

echo "dists $dists"
echo "components $components"

[ -e $path/conf/distributions ] && rm $path/conf/distributions

for dist in $dists
do
    cat <<EOF >> $path/conf/distributions
Codename: $dist
Suite: stable
Components: $components
Architectures: amd64 armhf arm64 i386 source
Origin: Inktank
Description: Ceph distributed file system
DebIndices: Packages Release . .gz .bz2
DscIndices: Sources Release .gz .bz2
Contents: .gz .bz2
SignWith: $key

EOF
done

echo done
