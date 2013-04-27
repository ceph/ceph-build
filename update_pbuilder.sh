#!/bin/sh -x

set -e

usage() {
    echo "usage: $0 basedir [dists...]"
}

bindir=`dirname $0`
echo "$bindir" | grep -v -q '^/' && bindir=`pwd`"/$bindir"

basedir=$1
shift
dists=$*

[ ! -d "$basedir" ] && echo specify dir for pbuilder images && usage && exit 1
[ -z "$dists" ] && dists=`cat $bindir/deb_dists`

for dist in $dists
do
    os="debian"
    [ "$dist" = "raring" ] && os="ubuntu"
    [ "$dist" = "precise" ] && os="ubuntu"
    [ "$dist" = "quantal" ] && os="ubuntu"
    [ "$dist" = "oneiric" ] && os="ubuntu"
    [ "$dist" = "natty" ] && os="ubuntu"
    [ "$dist" = "maverick" ] && os="ubuntu"
    [ "$dist" = "lucid" ] && os="ubuntu"
    
    if [ $os = "debian" ]; then
        mirror="http://http.us.debian.org/debian"
        othermirror=""
    else
        mirror=""
        othermirror="deb http://archive.ubuntu.com/ubuntu $dist main restricted universe multiverse"
    fi
    
    pbuilder --clean
    
    if [ -e $basedir/$dist.tgz ]; then
        echo updating $dist base.tgz
#        savelog -l -n  $basedir/$dist.tgz
#        cp $basedir/$dist.tgz.0 $basedir/$dist.tgz
        pbuilder update \
	    --basetgz $basedir/$dist.tgz \
	    --distribution $dist
    else
        echo building $dist base.tgz
        pbuilder create \
	    --basetgz $basedir/$dist.tgz \
	    --distribution $dist \
	    --mirror "$mirror" \
	    --othermirror "$othermirror"
    fi
done
