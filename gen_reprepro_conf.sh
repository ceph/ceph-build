#!/bin/sh

path="$1"
comp="$2"
shift
shift

if [ -e "$path/conf/dists" ]; then
    dists=`cat $path/conf/dists`
else
    dists="$*3"
fi

if [ -e "$path/conf/components" ]; then
    components=`cat $path/conf/components`
    if [ -n "$comp" ]; then
	if grep -v "\b$comp\b" $path/conf/components ; then
	    echo "adding component $comp"
	    components="$components $comp"
	    echo $components > $path/conf/components
	fi
    fi
else
    components="$comp"
fi

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
Origin: New Dream Network
Description: Ceph distributed file system
DebIndices: Packages Release . .gz .bz2
DscIndices: Sources Release .gz .bz2
SignWith: 03C3951A

EOF
done

echo done
