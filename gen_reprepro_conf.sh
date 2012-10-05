#!/bin/sh

set -e

path="$1"

if [ ! -d $path ] ; then
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
Architectures: i386 amd64 source
Origin: Inktank
Description: Ceph distributed file system
DebIndices: Packages Release . .gz .bz2
DscIndices: Sources Release .gz .bz2
Contents: .gz .bz2
SignWith: 17ED316D

EOF
done

echo done
