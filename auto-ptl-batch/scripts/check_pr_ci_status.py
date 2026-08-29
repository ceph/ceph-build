#!/usr/bin/env python3
"""check_pr_ci_status.py - Commit status helpers for auto-ptl-batch.

Usage:
  check_pr_ci_status.py <pr1> [pr2 ...]
      Verify each PR HEAD has overall green commit status.
  check_pr_ci_status.py --post-status <sha> <description> <target_url>
      Post auto-ptl-batch=pending on a commit SHA (legacy form).
  check_pr_ci_status.py --post-status <state> <sha> <description> <target_url>
      Post auto-ptl-batch=<state> on a commit SHA
      (state: pending, success, failure, error).
  check_pr_ci_status.py --post-status-batch <state> <description> <target_url> <sha1> [sha2 ...]
      Post the same status on multiple commit SHAs.
  check_pr_ci_status.py --get-batch-status <sha>
      Print the latest auto-ptl-batch status for a commit SHA.

Env:    GITHUB_PASS  GitHub token (repo scope on ceph/ceph)
Exit:   check mode: 0 all green / 1 not green / 2 usage / 3 API or auth error
        post mode:  0 posted / 1 API error / 2 usage or validation error
        get mode:   0 found / 1 not found / 2 usage / 3 API error
"""

import re
import sys
import urllib.error

import github_api

_PR_NUM_RE = re.compile(r'^\d+$')
_SHA_RE = re.compile(r'^[0-9a-fA-F]{7,40}$')
_STATE_RE = re.compile(r'^(pending|success|failure|error)$')
BATCH_STATUS_CONTEXT = 'auto-ptl-batch'


def _latest_statuses_by_context(statuses):
    latest = {}
    for s in statuses:
        ctx = s.get("context", "")
        if ctx and ctx not in latest:
            latest[ctx] = s
    return latest


def check_pr(pr_num):
    try:
        pr = github_api.gh_get(
            "https://api.github.com/repos/ceph/ceph/pulls/" + str(pr_num)
        )
        sha = pr["head"]["sha"]
        combined = github_api.gh_get(
            "https://api.github.com/repos/ceph/ceph/commits/"
            + sha
            + "/status"
        )
    except urllib.error.HTTPError as exc:
        sys.stderr.write(
            "GitHub API error checking PR #"
            + str(pr_num)
            + ": "
            + str(exc)
            + "\n",
        )
        sys.exit(github_api.EXIT_API_ERROR)

    state = combined.get("state", "unknown")
    print("PR #" + str(pr_num) + ": [overall-ci] = " + state, flush=True)

    batch = get_batch_status(sha, quiet=True)
    if batch:
        print(
            "PR #"
            + str(pr_num)
            + ": ["
            + BATCH_STATUS_CONTEXT
            + "] = "
            + batch.get("state", "unknown"),
            flush=True,
        )

    # Helpful diagnostics when not green: show latest non-success contexts.
    if state != "success":
        latest = _latest_statuses_by_context(combined.get("statuses", []))
        for ctx in sorted(latest):
            c_state = latest[ctx].get("state", "missing")
            if c_state != "success":
                print(
                    "PR #"
                    + str(pr_num)
                    + ": ["
                    + ctx
                    + "] = "
                    + c_state,
                    flush=True,
                )
    return state == "success"


def get_batch_status(sha, quiet=False):
    if not _SHA_RE.match(sha):
        if not quiet:
            sys.stderr.write("Invalid commit SHA: " + sha + "\n")
            sys.exit(2)
        return None
    try:
        statuses = github_api.gh_get(
            "https://api.github.com/repos/ceph/ceph/commits/"
            + sha
            + "/statuses?per_page=100"
        )
    except urllib.error.HTTPError as exc:
        if not quiet:
            sys.stderr.write("GitHub API error: " + str(exc) + "\n")
            sys.exit(github_api.EXIT_API_ERROR)
        return None
    for s in statuses:
        if s.get("context") == BATCH_STATUS_CONTEXT:
            return s
    return None


def post_batch_status(state, sha, description, target_url):
    if not _STATE_RE.match(state):
        sys.stderr.write("Invalid status state: " + state + "\n")
        sys.exit(2)
    if not _SHA_RE.match(sha):
        sys.stderr.write("Invalid commit SHA: " + sha + "\n")
        sys.exit(2)
    if not description:
        sys.stderr.write("Description must not be empty\n")
        sys.exit(2)
    if not target_url.startswith("https://"):
        sys.stderr.write("target_url must be an https URL\n")
        sys.exit(2)

    body = {
        "state": state,
        "context": BATCH_STATUS_CONTEXT,
        "description": description[:140],
        "target_url": target_url,
    }
    url = "https://api.github.com/repos/ceph/ceph/statuses/" + sha
    try:
        github_api.gh_post(url, body)
    except urllib.error.HTTPError as exc:
        sys.stderr.write("GitHub API error: " + str(exc) + "\n")
        return False
    print(
        "Posted "
        + BATCH_STATUS_CONTEXT
        + "="
        + state
        + " on "
        + sha[:12],
        flush=True,
    )
    return True


def post_batch_status_many(state, description, target_url, shas):
    failed = False
    for sha in shas:
        sha = sha.strip()
        if not sha:
            continue
        if not post_batch_status(state, sha, description, target_url):
            failed = True
    sys.exit(1 if failed else 0)


def main():
    github_api.require_token()

    if len(sys.argv) < 2:
        sys.stderr.write(
            "Usage: "
            + sys.argv[0]
            + " <pr1> [pr2 ...]\n       "
            + sys.argv[0]
            + " --post-status <sha> <description> <target_url>\n       "
            + sys.argv[0]
            + " --post-status <state> <sha> <description> <target_url>\n       "
            + sys.argv[0]
            + " --post-status-batch <state> <description> <target_url> <sha1> [sha2 ...]\n       "
            + sys.argv[0]
            + " --get-batch-status <sha>\n"
        )
        sys.exit(2)

    if sys.argv[1] == "--get-batch-status":
        if len(sys.argv) != 3:
            sys.stderr.write(
                "Usage: " + sys.argv[0] + " --get-batch-status <sha>\n"
            )
            sys.exit(2)
        status = get_batch_status(sys.argv[2].strip())
        if not status:
            print(
                BATCH_STATUS_CONTEXT
                + ": not set on "
                + sys.argv[2].strip()[:12],
                flush=True,
            )
            sys.exit(1)
        print(
            BATCH_STATUS_CONTEXT
            + "="
            + status.get("state", "unknown")
            + " "
            + (status.get("description") or ""),
            flush=True,
        )
        if status.get("target_url"):
            print("target_url=" + status["target_url"], flush=True)
        sys.exit(0)

    if sys.argv[1] == "--post-status-batch":
        if len(sys.argv) < 6:
            sys.stderr.write(
                "Usage: "
                + sys.argv[0]
                + " --post-status-batch <state> <description> <target_url> <sha1> [sha2 ...]\n"
            )
            sys.exit(2)
        state = sys.argv[2].strip()
        description = sys.argv[3].strip()
        target_url = sys.argv[4].strip()
        shas = sys.argv[5:]
        post_batch_status_many(state, description, target_url, shas)

    if sys.argv[1] == "--post-status":
        if len(sys.argv) == 5 and _SHA_RE.match(sys.argv[2].strip()):
            if not post_batch_status(
                "pending",
                sys.argv[2].strip(),
                sys.argv[3].strip(),
                sys.argv[4].strip(),
            ):
                sys.exit(1)
            sys.exit(0)
        if len(sys.argv) == 6 and _STATE_RE.match(sys.argv[2].strip()):
            if not post_batch_status(
                sys.argv[2].strip(),
                sys.argv[3].strip(),
                sys.argv[4].strip(),
                sys.argv[5].strip(),
            ):
                sys.exit(1)
            sys.exit(0)
        sys.stderr.write(
            "Usage: "
            + sys.argv[0]
            + " --post-status <sha> <description> <target_url>\n       "
            + sys.argv[0]
            + " --post-status <state> <sha> <description> <target_url>\n"
        )
        sys.exit(2)

    all_ok = True
    for pr in sys.argv[1:]:
        pr_num = pr.strip()
        if not _PR_NUM_RE.match(pr_num):
            sys.stderr.write("Invalid PR number: " + pr_num + "\n")
            sys.exit(2)
        if not check_pr(pr_num):
            all_ok = False
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
