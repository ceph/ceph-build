#!/usr/bin/env python3
# check_pr_ci_status.py - Verify PRs have green required CI contexts.
#
# Usage:  check_pr_ci_status.py <pr1> [pr2 ...]
# Env:    GITHUB_PASS  GitHub token (read:org + repo scope)
# Exit:   0 all required contexts are success / 1 one or more are not
import json
import os
import sys
import urllib.request

REQUIRED_CONTEXTS = frozenset(['make check', 'ceph API tests'])

_token = os.environ.get('GITHUB_PASS', '')
_headers = {'Accept': 'application/vnd.github+json'}
if _token:
    _headers['Authorization'] = 'token ' + _token


def _gh(url):
    req = urllib.request.Request(url, headers=_headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def check_pr(pr_num):
    pr = _gh('https://api.github.com/repos/ceph/ceph/pulls/' + str(pr_num))
    sha = pr['head']['sha']
    statuses = _gh(
        'https://api.github.com/repos/ceph/ceph/commits/'
        + sha + '/statuses?per_page=100'
    )
    latest = {}
    for s in statuses:
        ctx = s['context']
        if ctx not in latest:
            latest[ctx] = s
    all_green = True
    for ctx in REQUIRED_CONTEXTS:
        state = latest.get(ctx, {}).get('state', 'missing')
        print('PR #' + str(pr_num) + ': [' + ctx + '] = ' + state, flush=True)
        if state != 'success':
            all_green = False
    return all_green


def main():
    if len(sys.argv) < 2:
        sys.stderr.write('Usage: ' + sys.argv[0] + ' <pr1> [pr2 ...]\n')
        sys.exit(2)
    all_ok = True
    for pr in sys.argv[1:]:
        if not check_pr(pr.strip()):
            all_ok = False
    sys.exit(0 if all_ok else 1)


if __name__ == '__main__':
    main()
