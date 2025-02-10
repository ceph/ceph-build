#!/bin/bash
# vim: ts=4 sw=4 expandtab
set -ex

cd "$WORKSPACE"
VENV="${WORKSPACE}/.venv"
chacra_endpoint="ceph/${BRANCH}/${SHA1}/${OS_NAME}/${OS_VERSION_NAME}"
[ "$FORCE" = true ] && chacra_flags="--force" || chacra_flags=""
if [ "$OS_PKG_TYPE" = "rpm" ]; then
  RPM_RELEASE=`grep Release dist/ceph/ceph.spec | sed 's/Release:[ \t]*//g' | cut -d '%' -f 1`
  RPM_VERSION=`grep Version dist/ceph/ceph.spec | sed 's/Version:[ \t]*//g'`
  PACKAGE_MANAGER_VERSION="$RPM_VERSION-$RPM_RELEASE"
  BUILDAREA="${WORKSPACE}/dist/ceph/rpmbuild"
  find dist/ceph/rpmbuild/SRPMS | grep rpm | $VENV/bin/chacractl binary ${chacra_flags} create ${chacra_endpoint}/source/flavors/${FLAVOR}
  find dist/ceph/rpmbuild/RPMS/* | grep rpm | $VENV/bin/chacractl binary ${chacra_flags} create ${chacra_endpoint}/${ARCH}/flavors/${FLAVOR}
  if [ -f ${BUILDAREA}/RPMS/noarch/cephadm-*.rpm ] ; then
      rpm2cpio ${BUILDAREA}/RPMS/noarch/cephadm-*.rpm  | cpio -i --to-stdout *sbin/cephadm > cephadm
      echo cephadm | $VENV/bin/chacractl binary ${chacra_flags} create ${chacra_endpoint}/${ARCH}/flavors/${FLAVOR}
  fi
elif [ "$OS_PKG_TYPE" = "deb" ]; then
  PACKAGE_MANAGER_VERSION="${VERSION}-1${OS_VERSION_NAME}"
  find ${WORKSPACE}/dist/ceph/ | \
    egrep "*(\.changes|\.deb|\.ddeb|\.dsc|ceph[^/]*\.gz)$" | \
    egrep -v "(Packages|Sources|Contents)" | \
    $VENV/bin/chacractl binary ${chacra_flags} create ${chacra_endpoint}/${ARCH}/flavors/${FLAVOR}
  # FIXME need the real path here
  if [ -f release/${VERSION}/cephadm_${VERSION}*.deb ] ; then
    dpkg-deb --fsys-tarfile release/${VERSION}/cephadm_${VERSION}*.deb | tar -x -f - --strip-components=3 ./usr/sbin/cephadm
    echo cephadm | $VENV/bin/chacractl binary ${chacra_flags} create ${chacra_endpoint}/${ARCH}/flavors/${FLAVOR}
  fi
fi
# write json file with build info
  cat > $WORKSPACE/repo-extra.json << EOF
{
    "version":"$VERSION",
    "package_manager_version":"$PACKAGE_MANAGER_VERSION",
    "build_url":"$BUILD_URL",
    "root_build_cause":"$ROOT_BUILD_CAUSE",
    "node_name":"$NODE_NAME",
    "job_name":"$JOB_NAME"
}
EOF
chacra_repo_endpoint="${chacra_endpoint}/flavors/${FLAVOR}"
# post the json to repo-extra json to chacra
curl -X POST -H "Content-Type:application/json" --data "@$WORKSPACE/repo-extra.json" -u $CHACRACTL_USER:$CHACRACTL_KEY ${CHACRA_URL}repos/${chacra_repo_endpoint}/extra/
# start repo creation
$VENV/bin/chacractl repo update ${chacra_repo_endpoint}

echo Check the status of the repo at: https://shaman.ceph.com/api/repos/${chacra_endpoint}/flavors/${FLAVOR}/
