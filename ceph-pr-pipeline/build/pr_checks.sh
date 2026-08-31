#!/bin/bash
#
# GitHub-API-based PR checks for ceph-pr-pipeline.  These reimplement the
# checks from ceph-pr-commits (Signed-off-by) and ceph-pr-submodules
# (Unmodified Submodules) plus the docs/container/gha/qa-only classification
# from build_utils.sh, using only the GitHub API -- no 4-5 minute ceph.git
# clone needed, so these statuses come back in seconds.
#
# Usage: pr_checks.sh <classify|signed|submodules>
#
# Required environment:
#   ghprbPullId       - PR number
#   ghprbTargetBranch - PR target branch (e.g. main)
#   GITHUB_USER/GITHUB_PASS - GitHub API credentials (read-only is fine)
# classify writes $WORKSPACE/pr_changes.properties (DOCS_ONLY=..., etc.).
# signed additionally reads DOCS_ONLY (exported by the pipeline from the
# classify stage) to decide which check to apply, mirroring ceph-pr-commits.

set -o errexit
set -o pipefail

GH_REPO=${GH_REPO:-"ceph/ceph"}
GH_API="https://api.github.com/repos/${GH_REPO}"

gh_api() {
    curl -sf -u "${GITHUB_USER}:${GITHUB_PASS}" \
        -H "Accept: application/vnd.github+json" "$@"
}

# Paginate a list endpoint ($1, e.g. "pulls/123/files") and emit one combined
# JSON array on stdout.  Pages are flattened to one-element-per-line NDJSON
# (jq -c '.[]') and reassembled with jq -s, which is valid regardless of how
# many elements each page has.  The commits endpoint caps at 250 entries and
# files at 3000, same limits the GHPRB-era shallow-clone checks effectively
# had.
gh_api_list() {
    local endpoint=$1
    local page=1
    local chunk count
    {
        while true; do
            chunk=$(gh_api "${GH_API}/${endpoint}?per_page=100&page=${page}")
            echo "$chunk" | jq -c '.[]'
            count=$(echo "$chunk" | jq 'length')
            if [ "$count" -lt 100 ]; then
                break
            fi
            page=$((page+1))
        done
    } | jq -s '.'
}

changed_files() {
    gh_api_list "pulls/${ghprbPullId}/files" | jq -r '.[].filename'
}

pr_commits() {
    # Non-merge commits only, like `git log --no-merges`.
    gh_api_list "pulls/${ghprbPullId}/commits" \
        | jq '[.[] | select((.parents | length) == 1)]'
}

# Mirror the *_pr_only helpers in scripts/build_utils.sh.
only_matching() {
    local -n patterns=$1
    local matched
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        matched=false
        for pat in "${patterns[@]}"; do
            # shellcheck disable=SC2053
            if [[ "$f" == $pat ]]; then
                matched=true
                break
            fi
        done
        if [ "$matched" = false ]; then
            return 1
        fi
    done <<< "$2"
    return 0
}

do_classify() {
    local files
    files="$(changed_files)"
    echo "Changed files:"
    echo "$files"

    local docs_patterns=(
        'doc/*' 'admin/*' 'src/sample.ceph.conf' 'CodingStyle' '*.rst' '*.md'
        'COPYING*' 'README.*' 'SubmittingPatches' '.readthedocs.yml'
        'PendingReleaseNotes'
    )
    local container_patterns=(
        'container/*' 'Dockerfile.build'
        'src/script/buildcontainer-setup.sh' 'src/script/build-with-container.py'
    )
    local gha_patterns=( '.github/*' )
    local qa_patterns=( 'qa/*' 'src/script/*' )

    local docs_only=false container_only=false gha_only=false qa_only=false
    if [ -n "$files" ]; then
        only_matching docs_patterns "$files" && docs_only=true
        only_matching container_patterns "$files" && container_only=true
        only_matching gha_patterns "$files" && gha_only=true
        only_matching qa_patterns "$files" && qa_only=true
    fi

    tee "${WORKSPACE}/pr_changes.properties" << EOF
DOCS_ONLY=${docs_only}
CONTAINER_ONLY=${container_only}
GHA_ONLY=${gha_only}
QA_ONLY=${qa_only}
EOF
}

do_signed() {
    local commits
    commits="$(pr_commits)"
    local wrong

    if [ "${DOCS_ONLY}" = true ]; then
        # Docs-only PRs: commit titles must start with "doc" (or
        # "<target>: doc" on stable branches).  See ceph-pr-commits.
        local doc_regex='^doc'
        if [ "${ghprbTargetBranch}" != "main" ]; then
            doc_regex="^(${ghprbTargetBranch}: )?doc"
        fi
        wrong=$(echo "$commits" | jq -r --arg re "$doc_regex" \
            '.[] | select((.commit.message | split("\n")[0] | test($re)) | not)
                 | .sha[0:12] + " " + (.commit.message | split("\n")[0])')
        if [ -n "$wrong" ]; then
            echo "The following commits only touch files under doc/ but their titles"
            echo "do not start with 'doc'.  See the 'Submitting Patches' guide:"
            echo "https://github.com/ceph/ceph/blob/main/SubmittingPatches.rst#commit-title"
            echo "$wrong"
            return 1
        fi
        echo "All commit titles look good."
        return 0
    fi

    wrong=$(echo "$commits" | jq -r \
        '.[] | select((.commit.message
                       | test("Signed-off-by: \\S.* <[^@]+@[^@]+\\.[^@]+>")) | not)
             | .sha[0:12] + " " + (.commit.message | split("\n")[0])')
    if [ -n "$wrong" ]; then
        echo "The following commits are not signed.  Please sign all commits as"
        echo "described in the 'Submitting Patches' guide:"
        echo "https://github.com/ceph/ceph/blob/main/SubmittingPatches.rst#1-sign-your-work"
        echo "$wrong"
        return 1
    fi
    echo "All commits are signed."
    return 0
}

do_submodules() {
    # Submodule paths as of the target branch.
    local submodule_paths
    submodule_paths=$(gh_api "${GH_API}/contents/.gitmodules?ref=${ghprbTargetBranch}" \
        | jq -r '.content' | base64 -d \
        | awk -F ' *= *' '$1 ~ /path$/ { print $2 }')
    echo "Submodule paths on ${ghprbTargetBranch}:"
    echo "$submodule_paths"

    local files modified=""
    files="$(changed_files)"
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if echo "$files" | grep -qx "$path"; then
            modified="$modified $path"
        fi
    done <<< "$submodule_paths"

    if [ -z "$modified" ]; then
        echo "No submodules modified."
        return 0
    fi

    echo "Project has modified submodules:${modified}"
    local commits
    commits="$(pr_commits)"
    for path in $modified; do
        local magic_word
        magic_word="$(basename "$path") submodule"
        if echo "$commits" | jq -e --arg w "$magic_word" \
            '.[] | select(.commit.message | contains($w))' > /dev/null; then
            echo "'${magic_word}' found in a commit message; change is planned."
        else
            echo "please include '${magic_word}' in your commit message, if this change is intentional."
            return 1
        fi
    done
    return 0
}

case "$1" in
    classify)   do_classify ;;
    signed)     do_signed ;;
    submodules) do_submodules ;;
    *)
        echo "usage: $0 <classify|signed|submodules>" >&2
        exit 2
        ;;
esac
