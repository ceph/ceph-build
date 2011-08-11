#!/bin/sh -e

mydir=`dirname $0`

dest=$1
shift

echo "dest $dest"

[ -d "$dest" ] || install -d -m0755 "$dest"
[ -d "$dest/dists" ] || install -d -m0755 "$dest/dists"
[ -d "$dest/pool" ] || install -d -m0755 "$dest/pool"

for src in $*
do
    echo "src $src"

    # combine pool
    for dir in `cd "$src" && ls -d pool/*/*/*`
    do
	echo "  dir $dir"
	[ -d "$dest/$dir" ] || install -d -m0755 "$dest/$dir"
	for file in `ls "$src/$dir"`
	do
	    echo "    file $file"
	    [ -e "$dest/$dir/$file" ] || ( cd $dest/$dir && ln -sf "../../../../../$src/$dir/$file" )
	done
    done

    # combine dists
    for dist in `ls $src/dists`
    do
	echo "dist $dist"
	[ -d "$dest/dists/$dist" ] || install -d -m0755 "$dest/dists/$dist"
	for arch in `ls $src/dists/$dist/main`
	do
	    echo "  arch $arch"
	    if [ -e "$src/dists/$dist/main/$arch/Packages" ]; then
		[ -d "$dest/dists/$dist/main/$arch" ] || install -d -m0755 "$dest/dists/$dist/main/$arch"
		cat "$src/dists/$dist/main/$arch/Packages" >> "$dest/dists/$dist/main/$arch/Packages.new"
	    fi
	done
    done
done

# finalize Packages
echo "merging"
archs=""
for dist in `ls $dest/dists`
do
    echo "dist $dist"
    for arch in `ls $dest/dists/$dist/main`
    do
	archs="$archs $arch"
	f="$dest/dists/$dist/main/$arch"
	echo "  arch $arch at $f"
	
	if [ -e "$f/Packages.new" ]; then
	    mv "$f/Packages.new" "$f/Packages"
	    gzip -c "$f/Packages" > "$f/Packages.gz"
	    bzip2 -c "$f/Packages" > "$f/Packages.bz2"
	else
	    echo rm -r "$f"
	fi
	
	cat <<EOF > "$f/Release"
Archive: stable
Component: main
Origin: New Dream Network
Architecture: $arch
Description: combined repo
EOF
    done

    # build Release for this distribution
    echo "building $dest/dists/$dist/Release"
    date=`date "+%a, %d %b %Y %X UTC" -u`
    cat <<EOF > "$dest/temp"
Origin: New Dream Network
Suite: stable
Codename: $dist
Date: $date
Architectures: $archs
Components: main
Description: combined repo
MD5Sum:
EOF
    rm -f "$dest/dists/$dist/Release"
    for f in `cd $dest/dists/$dist && find main -type f`
    do
	echo " "`md5sum $dest/dists/$dist/$f | cut -c 1-32`" "`stat --format=%s $dest/dists/$dist/$f`" $f" >> "$dest/temp"
    done
    echo "SHA1:" >> "$dest/temp"
    for f in `cd $dest/dists/$dist && find main -type f`
    do
	echo " "`sha1sum $dest/dists/$dist/$f | cut -c 1-40`" "`stat --format=%s $dest/dists/$dist/$f`" $f" >> "$dest/temp"
    done
    echo "SHA256:" >> "$dest/temp"
    for f in `cd $dest/dists/$dist && find main -type f`
    do
	echo " "`sha256sum $dest/dists/$dist/$f | cut -c 1-64`" "`stat --format=%s $dest/dists/$dist/$f`" $f" >> "$dest/temp"
    done
    mv "$dest/temp" "$dest/dists/$dist/Release"
    
    # sign it
    gpg --detach-sign --armor "$dest/dists/$dist/Release"
    mv "$dest/dists/$dist/Release.asc" "$dest/dists/$dist/Release.gpg"
done



