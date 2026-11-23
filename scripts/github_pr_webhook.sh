# Preamble for pull-request jobs fired by the generic webhook trigger.
# Concatenated after build_utils.sh.  Resolves the PR number from whichever
# payload fired the job (issue_comment or pull_request) or from the manual
# ghprbPullId parameter, authorizes the trigger the way
# ceph-pr-pipeline-trigger does, exports the ghprb* variables the build
# scripts use, and posts the commit status for the whole build from an EXIT
# trap.  Expects GITHUB_USER/GITHUB_PASS and GITHUB_STATUS_USER/
# GITHUB_STATUS_TOKEN bound from github-app-ceph-jenkins, and from the job:
#   PR_STATUS_CONTEXT  status context (required)
#   PR_STATUS_LABEL    text in the status description (default: the context)
#   PR_REPO            owner/name (default ceph/ceph)
#   STATUS_PREFIX      prepended to the context while testing

ghprbGhRepository="${PR_REPO:-ceph/ceph}"
ghprbPullId="${ghprbPullId:-${pr_number:-}}"
if [ -z "$ghprbPullId" ]; then
    echo "ERROR: no PR number (ghprbPullId or pr_number)"
    exit 1
fi
export ghprbGhRepository ghprbPullId

# GET a path under the repo's GitHub API.  Anything but a 200 is an error, so
# an API failure is never read as an answer.  Runs in a subshell with tracing
# off: the response bodies are large.
github_api_get() (
    set +x
    local out status
    out=$(curl -s -w '\n%{http_code}' -u "${GITHUB_USER}:${GITHUB_PASS}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${ghprbGhRepository}/$1") || true
    status="${out##*$'\n'}"
    if [ "$status" != "200" ]; then
        echo "ERROR: GitHub API ${ghprbGhRepository}/$1 returned ${status:-no response}" >&2
        return 1
    fi
    echo "${out%$'\n'*}"
)

# The webhook has no authorization layer in front of this job: the commenter
# (issue_comment) or PR author (pull_request) needs write/admin on the repo,
# or the PR must carry the ci-approved label.  Manual builds skip the check.
trigger_user="${comment_author:-${pr_author:-}}"
if [ -n "$trigger_user" ]; then
    permission_json=$(github_api_get "collaborators/${trigger_user}/permission") || exit 1
    permission=$(jq -r '.permission' <<< "$permission_json")
    if [ "$permission" != "admin" ] && [ "$permission" != "write" ]; then
        labels_json=$(github_api_get "issues/${ghprbPullId}/labels") || exit 1
        if ! jq -e 'any(.[]; .name == "ci-approved")' <<< "$labels_json" > /dev/null; then
            echo "${trigger_user} lacks write access and PR ${ghprbPullId} has no ci-approved label; not building"
            exit 0
        fi
    fi
fi

pr_json=$(github_api_get "pulls/${ghprbPullId}") || exit 1
# Report against the commit that was checked out, not the PR head as of now.
# The workspace is on the PR's merge ref, whose second parent is that commit;
# read the raw object because a shallow clone hides the parents.
ghprbActualCommit=""
checked_out=$(git rev-parse -q --verify HEAD || true)
if [ -n "$checked_out" ] && [ "$checked_out" = "$(git rev-parse -q --verify "refs/remotes/origin/pr/${ghprbPullId}/merge" || true)" ]; then
    ghprbActualCommit=$(git cat-file commit HEAD | sed -n '/^$/q; s/^parent //p' | sed -n 2p)
fi
ghprbActualCommit="${ghprbActualCommit:-$(jq -r '.head.sha // empty' <<< "$pr_json")}"
if [ -z "$ghprbActualCommit" ]; then
    echo "ERROR: could not resolve ${ghprbGhRepository} PR ${ghprbPullId}"
    exit 1
fi
ghprbSourceBranch=$(jq -r '.head.ref' <<< "$pr_json")
ghprbTargetBranch=$(jq -r '.base.ref' <<< "$pr_json")
ghprbPullTitle=$(jq -r '.title' <<< "$pr_json")
ghprbPullLink=$(jq -r '.html_url' <<< "$pr_json")
export ghprbActualCommit ghprbSourceBranch ghprbTargetBranch ghprbPullTitle ghprbPullLink
echo "PR ${ghprbGhRepository}#${ghprbPullId} (${ghprbSourceBranch} -> ${ghprbTargetBranch}) at ${ghprbActualCommit}"

export FORCE_GITHUB_PR_STATUS=true
pr_status_context="${STATUS_PREFIX:-}${PR_STATUS_CONTEXT}"
pr_status_label="${PR_STATUS_LABEL:-$PR_STATUS_CONTEXT}"
trap 'report_github_pr_status $? "$pr_status_context" "$pr_status_label"' EXIT
update_github_pr_status "pending" "${pr_status_label} running" "$pr_status_context"
