#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab
ceph_version_git=$(git describe --abbrev=8 --match 'v*' | sed s/^v//)

if command -v podman; then
  PODMAN=podman
elif [[ "$(groups)" =~ .*\ docker\ .* ]]; then
  PODMAN=docker
else
  PODMAN="sudo docker"
fi

printf "FROM ubuntu:24.04\nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg-dev devscripts && apt-get clean && rm -rf /var/lib/apt/lists/*" | $PODMAN build -t ubuntu_builder -
$PODMAN run --rm -v $PWD:/ceph:z -e DEBEMAIL=contact@ceph.com ubuntu_builder:latest bash -c "cd /ceph && dch -v $ceph_version_git-1 'autobuilder' < /dev/null"

rm -rf dist release
mkdir -p release
echo $ceph_version_git > release/version

# declare an associative array to map file extensions to tar flags
declare -A compression=( ["bz2"]="j" ["gz"]="z" ["xz"]="J" )
for cmp in "${!compression[@]}"; do
  rm -f ceph-*.tar.$cmp
done
echo building tarball
./make-dist $ceph_version_git
for cmp in "${!compression[@]}"; do
  extension="tar.$cmp"
  ceph_version_tarball=$(ls ceph-*.$extension | cut -c 6- | sed "s/.$extension//" || true)
  flag="${compression[$cmp]}"
  extract_flags="${flag}xf"
  compress_flags="${flag}cf"
  if [ "$ceph_version_tarball" != "" ]; then break; fi
done
echo tarball vers $ceph_version_tarball

echo extracting
mkdir -p release/$ceph_version_git
cd release/$ceph_version_git

# FIXME: is the rpm patch stuff below ever necessary?
# mkdir -p release/$ceph_version_git/rpm
# cp rpm/*.patch release/$ceph_version_git/rpm || true

tar $extract_flags $WORKSPACE/ceph/ceph-$ceph_version_tarball.$extension

[ "$ceph_version_tarball" != "$ceph_version_git" ] && mv ceph-$ceph_version_tarball ceph-$ceph_version_git

tar zcf ceph_$ceph_version_git.orig.tar.gz ceph-$ceph_version_git
# FIXME delete this if it's not needed
ln ceph_$ceph_version_git.orig.tar.gz ceph-$ceph_version_git.tar.gz

tar jcf ceph-$ceph_version_git.tar.bz2 ceph-$ceph_version_git

# copy debian dir, too. Prevent errors with `true` when using cmake
cp -a $WORKSPACE/ceph/debian debian || true
cd $WORKSPACE/ceph

# copy in spec file, too. If using cmake, the spec file
# will already exist.
cp ceph.spec release/$ceph_version_git || true

(
  cd release/${ceph_version_git}
  mkdir -p ceph-${ceph_version_git}/debian
  cp -r debian/* ceph-${ceph_version_git}/debian/
  $PODMAN run --rm -v $PWD:/ceph:z ubuntu_builder:latest bash -c "cd /ceph && dpkg-source -b ceph-${ceph_version_git}"
)

mkdir -p dist
# Debian Source Files
mv release/$ceph_version_git/*.dsc dist/.
mv release/$ceph_version_git/*.diff.gz dist/. || true
mv release/$ceph_version_git/*.orig.tar.gz dist/.
# RPM Source Files
mkdir -p dist/rpm/
mv release/$ceph_version_git/rpm/*.patch dist/rpm/ || true
mv release/$ceph_version_git/ceph.spec dist/.
mv release/$ceph_version_git/*.tar.* dist/.

mv release/version dist/.

echo "SHA1=$(git rev-parse HEAD)" > dist/sha1
echo "BRANCH=${BRANCH}" > dist/branch

# - CEPH_EXTRA_RPMBUILD_ARGS are consumed by build_rpm before
#   the switch to cmake;
# - CEPH_EXTRA_CMAKE_ARGS is for after cmake
# - DEB_BUILD_PROFILES is consumed by build_debs()
cat > dist/other_envvars << EOF
CEPH_EXTRA_RPMBUILD_ARGS=${CEPH_EXTRA_RPMBUILD_ARGS}
CEPH_EXTRA_CMAKE_ARGS=${CEPH_EXTRA_CMAKE_ARGS}
DEB_BUILD_PROFILES=${DEB_BUILD_PROFILES}
EOF
