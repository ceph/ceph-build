#!/usr/bin/env python3
"""check_pr_ci_status.py - Verify PR HEAD has overall green commit status.

Usage:  check_pr_ci_status.py <pr1> [pr2 ...]
Env:    GITHUB_PASS  GitHub token (read:org + repo scope)
Exit:   0 all PR HEAD SHAs are overall green / 1 one or more are not
"""

import json
import os
import sys
import urllib.request

_token = os.environ.get("GITHUB_PASS", "")
_headers = {"Accept": "application/vnd.github+json"}
if _token:
    _headers["Authorization"] = "token " + _token


def _gh(url):
    req = urllib.request.Request(url, headers=_headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def _latest_statuses_by_context(statuses):
    latest = {}
    for s in statuses:
        ctx = s.get("context", "")
        if ctx and ctx not in latest:
            latest[ctx] = s
    return latest


def check_pr(pr_num):
    pr = _gh("https://api.github.com/repos/ceph/ceph/pulls/" + str(pr_num))
    sha = pr["head"]["sha"]
    combined = _gh(
        "https://api.github.com/repos/ceph/ceph/commits/"
        + sha
        + "/status"
    )
    state = combined.get("state", "unknown")
    print("PR #" + str(pr_num) + ": [overall-ci] = " + state, flush=True)

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


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: " + sys.argv[0] + " <pr1> [pr2 ...]\n")
        sys.exit(2)
    all_ok = True
    for pr in sys.argv[1:]:
        if not check_pr(pr.strip()):
            all_ok = False
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
