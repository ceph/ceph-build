#!/bin/bash
# vim: ts=4 sw=4 expandtab
set -ex

cd "$WORKSPACE"
VENV="${WORKSPACE}/.venv"
PATH=$PATH:$HOME/.local/bin
chacra_endpoint="ceph/${BRANCH}/${SHA1}/${OS_NAME}/${OS_VERSION_NAME}"
[ "$FORCE" = true ] && chacra_flags="--force" || chacra_flags=""

# Wait (bounded) until chacra has no build of the given repo pending or running.
wait_for_chacra_repo_idle() {
  local repo_url="$1"
  local timeout="${CHACRA_REPO_WAIT_TIMEOUT:-3600}"
  local deadline=$(( SECONDS + timeout ))
  local failures=0
  local state
  while true; do
    if state=$(curl -fsS -L --max-time 30 "$repo_url" | \
        jq -er '"needs_update=\(.needs_update) is_queued=\(.is_queued) is_updating=\(.is_updating)"'); then
      failures=0
      case "$state" in
        *=true*) echo "chacra repo is busy ($state), waiting before requesting an update" ;;
        *) return 0 ;;
      esac
    else
      failures=$(( failures + 1 ))
      if [ "$failures" -ge 5 ]; then
        echo "could not read the repo state from $repo_url, requesting the update anyway"
        return 0
      fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "TIMEOUT: chacra repo still busy after ${timeout}s, requesting the update anyway"
      return 0
    fi
    sleep 30
  done
}
if [ "$OS_PKG_TYPE" = "rpm" ]; then
  RPM_RELEASE=`grep Release dist/ceph/ceph.spec | sed 's/Release:[ \t]*//g' | cut -d '%' -f 1`
  RPM_VERSION=`grep Version dist/ceph/ceph.spec | sed 's/Version:[ \t]*//g'`
  PACKAGE_MANAGER_VERSION="$RPM_VERSION-$RPM_RELEASE"
  BUILDAREA="${WORKSPACE}/dist/ceph/rpmbuild"
  find dist/ceph/rpmbuild/SRPMS | grep rpm | chacractl binary ${chacra_flags} create ${chacra_endpoint}/source/flavors/${FLAVOR}
  find dist/ceph/rpmbuild/RPMS/* | grep rpm | chacractl binary ${chacra_flags} create ${chacra_endpoint}/${ARCH}/flavors/${FLAVOR}
  if [ -f ./cephadm ] ; then
      echo cephadm | chacractl binary ${chacra_flags} create ${chacra_endpoint}/${ARCH}/flavors/${FLAVOR}
  fi
elif [ "$OS_PKG_TYPE" = "deb" ]; then
  PACKAGE_MANAGER_VERSION="${VERSION}-1${OS_VERSION_NAME}"
  find ${WORKSPACE}/dist/ceph/ | \
    egrep "*(\.changes|\.deb|\.ddeb|\.dsc|ceph[^/]*\.gz)$" | \
    egrep -v "(Packages|Sources|Contents)" | \
    chacractl binary ${chacra_flags} create ${chacra_endpoint}/${ARCH}/flavors/${FLAVOR}
  BUILDAREA="${WORKSPACE}/dist/ceph/debs"
  if [ -f ./cephadm ] ; then
    echo cephadm | chacractl binary ${chacra_flags} create ${chacra_endpoint}/${ARCH}/flavors/${FLAVOR}
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
# All ARCH legs of a build feed the same chacra repo, and "repo update" clears
# the repo's is_queued/is_updating flags. Sent while another leg's repo build
# is still queued or running, it makes chacra start a second build of the same
# repo; the two then fight over the reprepro lock and each one skips whatever
# it could not add, leaving packages out of the index
# (https://tracker.ceph.com/issues/80977). Let that build finish first; the
# one requested below picks up everything uploaded so far.
wait_for_chacra_repo_idle "${CHACRA_URL}repos/${chacra_repo_endpoint}/"
# start repo creation
chacractl repo update ${chacra_repo_endpoint}

echo Check the status of the repo at: https://shaman.ceph.com/api/repos/${chacra_endpoint}/flavors/${FLAVOR}/
