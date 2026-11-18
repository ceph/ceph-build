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

# The webhook has no authorization layer in front of this job: the commenter
# (issue_comment) or PR author (pull_request) needs write/admin on the repo,
# or the PR must carry the ci-approved label.  Manual builds skip the check.
trigger_user="${comment_author:-${pr_author:-}}"
if [ -n "$trigger_user" ]; then
    permission=$(curl -s -u "${GITHUB_STATUS_USER}:${GITHUB_STATUS_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${ghprbGhRepository}/collaborators/${trigger_user}/permission" | jq -r '.permission')
    if [ "$permission" != "admin" ] && [ "$permission" != "write" ]; then
        labels=$(curl -s -u "${GITHUB_USER}:${GITHUB_PASS}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${ghprbGhRepository}/issues/${ghprbPullId}/labels" | jq -r '.[].name')
        if ! grep -qxF "ci-approved" <<< "$labels"; then
            echo "${trigger_user} lacks write access and PR ${ghprbPullId} has no ci-approved label; not building"
            exit 0
        fi
    fi
fi

pr_json=$(curl -s -u "${GITHUB_USER}:${GITHUB_PASS}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${ghprbGhRepository}/pulls/${ghprbPullId}")
ghprbActualCommit=$(jq -r '.head.sha // empty' <<< "$pr_json")
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
