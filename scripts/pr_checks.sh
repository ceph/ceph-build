#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab

# NOTE: These functions will only work on a Pull Request job!
pr_only_for() {
  # $1 is passed by reference to avoid having to call with ${array[@]} and
  # receive by creating another local array ("$@")
  local -n local_patterns=$1
  local files
  pushd .
  # cd to ceph repo if we need to.
  # The ceph-pr-commits job checks out ceph.git and ceph-build.git but most
  # other jobs do not.
  if ! [[ "$(git config --get remote.origin.url)" =~ "ceph/ceph.git" ]]; then
    cd "$WORKSPACE/ceph"
  fi
  if [ -f $(git rev-parse --git-dir)/shallow ]; then
    # We can't do a regular `git diff` in a shallow clone.  There is no other way to check files changed.
    files="$(curl -s -u ${GITHUB_USER}:${GITHUB_PASS} https://api.github.com/repos/${ghprbGhRepository}/pulls/${ghprbPullId}/files | jq '.[].filename' | tr -d '"')"
  else
    files="$(git diff --name-only origin/${ghprbTargetBranch}...origin/pr/${ghprbPullId}/head)"
  fi
  popd
  echo -e "changed files:\n$files"
  # 0 is true, 1 is false
  local all_match=0
  for f in $files; do
    local match=1
    for p in "${local_patterns[@]}"; do
      # pattern loop: if one pattern matches, skip the others
      if [[ $f == $p ]]; then match=0; break; fi
    done
    # file loop: if this file matched no patterns, the group fails
    # (one mismatch spoils the whole bushel)
    if [[ $match -eq 1 ]] ; then all_match=1; break; fi
  done
  return $all_match
}

docs_pr_only() {
  DOCS_ONLY=false
  local patterns=(
    'doc/*'
    'admin/*'
    'src/sample.ceph.conf'
    'CodingStyle'
    '*.rst'
    '*.md'
    'COPYING*'
    'README.*'
    'SubmittingPatches'
    '.readthedocs.yml'
    'PendingReleaseNotes'
  )
  if pr_only_for patterns; then DOCS_ONLY=true; fi
}

container_pr_only() {
  CONTAINER_ONLY=false
  local patterns=(
    'container/*'
    'Dockerfile.build'
    'src/script/buildcontainer-setup.sh'
    'src/script/build-with-container.py'
  )
  if pr_only_for patterns; then CONTAINER_ONLY=true; fi
}