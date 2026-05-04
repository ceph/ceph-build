#!/usr/bin/env python3
"""
group_prs.py  –  Discover, filter, and batch ceph/ceph PRs for auto-ptl-batch.

Reads configuration from environment variables, writes a JSON array of batch
objects to stdout, and logs progress to stderr.

Environment variables
---------------------
GITHUB_PASS           GitHub token (read:org + repo scope)
REQUIRED_LABELS       Comma-separated; every PR must carry all of these
                      (default: needs-QA)
EXCLUDE_LABELS        Comma-separated; any PR carrying any of these is skipped
                      (default: needs-rebase,ready-to-merge)
COMPONENT_SUITE_MAP   JSON object: component label value → teuthology suite name
                      (default: built-in map below)
CONFLICT_PATH_DEPTH   Directory depth for file-path conflict detection (default: 3)
                        3 → src/rgw/multisite/
                        2 → src/rgw/
                        0 → exact file match only
MAX_PRS_PER_BATCH     Hard cap on PRs per sub-batch (default: 5)
BASE_BRANCH_FILTER    If non-empty, only process PRs targeting this branch
UPDATED_WITHIN_DAYS   Only scan PRs updated within this many days (default: 90)

Idempotency
-----------
Before queuing a PR the script checks the GitHub commit status for context
'auto-ptl-batch' on the PR's HEAD SHA.  If the state is 'pending' (already
in ceph-ci) or 'success' (teuthology passed), the PR is skipped.  A new push
to the PR branch changes the HEAD SHA and resets eligibility automatically.

Output JSON schema
------------------
[
  {
    "component":    "rgw",
    "branch":       "main",
    "suite":        "rgw",
    "batch":        1,
    "prs":          [101, 102],
    "pr_shas":      {"101": "<full sha>", "102": "<full sha>"},
    "split_reason": "PR#101↔PR#105: src/rgw/multisite"   // only when split
  },
  ...
]
"""

import datetime
import json
import os
import sys
import urllib.error
import urllib.request
from collections import defaultdict

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

DEFAULT_REQUIRED_LABELS = 'needs-qa'
DEFAULT_EXCLUDE_LABELS  = 'needs-rebase,ready-to-merge,passed-qa'

DEFAULT_COMPONENT_SUITE_MAP = {
    'bluestore': 'rados',
    'build/ops': 'smoke',
    'cephfs':    'fs',
    'common':    'smoke',
    'core':      'rados',
    'crimson':   'crimson',
    'dashboard': 'dashboard',
    'mds':       'fs',
    'mgr':       'mgr',
    'mon':       'rados',
    'msgr':      'rados',
    'osd':       'rados',
    'pybind':    'smoke',
    'rados':     'rados',
    'rbd':       'rbd',
    'rgw':       'rgw',
    'tools':     'smoke',
}

DEFAULT_CONFLICT_PATH_DEPTH  = 3
DEFAULT_MAX_PRS_PER_BATCH    = 5
DEFAULT_UPDATED_WITHIN_DAYS  = 90

# GitHub commit-status context used by this pipeline for idempotency tracking.
BATCH_STATUS_CONTEXT = 'auto-ptl-batch'
# States that mean "this SHA is already queued or passed — do not re-batch".
SKIP_STATES = frozenset({'pending', 'success'})

# File paths and extensions that are considered documentation-only.
# A PR whose entire changed file set matches these patterns needs no
# teuthology suite and is excluded from this pipeline.
DOC_PATH_PREFIXES = ('doc/', 'Documentation/')
DOC_FILE_SUFFIXES = ('.rst', '.md', '.txt')

# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------

_token = os.environ.get('GITHUB_PASS', '')
_headers = {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
}
if _token:
    _headers['Authorization'] = 'Bearer ' + _token


def _gh_get(url):
    req = urllib.request.Request(url, headers=_headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def _gh_paginate(base_url):
    """Fetch all pages from a GitHub list endpoint."""
    results = []
    page    = 1
    while True:
        sep  = '&' if '?' in base_url else '?'
        data = _gh_get(f'{base_url}{sep}per_page=100&page={page}')
        if not data:
            break
        results.extend(data)
        if len(data) < 100:
            break
        page += 1
    return results


def get_pr_detail(pr_num):
    return _gh_get(f'https://api.github.com/repos/ceph/ceph/pulls/{pr_num}')


def get_pr_files(pr_num):
    """Return frozenset of changed file paths for a PR."""
    files = _gh_paginate(
        f'https://api.github.com/repos/ceph/ceph/pulls/{pr_num}/files'
    )
    return frozenset(f['filename'] for f in files)


def get_latest_batch_status(sha):
    """
    Return the state string of the most recent auto-ptl-batch commit status
    for the given SHA, or None if no status has been posted yet.
    """
    try:
        statuses = _gh_get(
            f'https://api.github.com/repos/ceph/ceph/commits/{sha}/statuses'
            f'?per_page=100'
        )
    except urllib.error.HTTPError:
        return None
    for s in statuses:
        if s.get('context') == BATCH_STATUS_CONTEXT:
            return s['state']
    return None


# ---------------------------------------------------------------------------
# Conflict detection
# ---------------------------------------------------------------------------

def path_at_depth(filepath, depth):
    """
    Truncate a file path to `depth` components.
    'src/rgw/multisite/sync.cc' at depth=3 → 'src/rgw/multisite'
    depth=0 returns the full path (exact-file matching).
    """
    if depth == 0:
        return filepath
    return '/'.join(filepath.split('/')[:depth])


def conflict_path_set(file_set, depth):
    return frozenset(path_at_depth(f, depth) for f in file_set)


def is_doc_only(file_set):
    """
    Return True when every changed file in a PR is documentation.
    Such PRs need no package build or teuthology run and are excluded
    from this pipeline regardless of component label.
    """
    if not file_set:
        return False
    return all(
        any(f.startswith(p) for p in DOC_PATH_PREFIXES)
        or any(f.endswith(s) for s in DOC_FILE_SUFFIXES)
        for f in file_set
    )


def build_conflict_graph(pr_file_map, depth):
    """
    Compare every PR pair within the group.

    Returns:
        edges    – {pr_num: set of conflicting pr_nums}
        evidence – {(a, b): [shared paths]}  where a < b
    """
    edges    = defaultdict(set)
    evidence = {}
    prs      = list(pr_file_map.keys())
    pr_paths = {pr: conflict_path_set(files, depth) for pr, files in pr_file_map.items()}

    for i in range(len(prs)):
        for j in range(i + 1, len(prs)):
            a, b   = prs[i], prs[j]
            shared = pr_paths[a] & pr_paths[b]
            if shared:
                edges[a].add(b)
                edges[b].add(a)
                evidence[(a, b)] = sorted(shared)[:5]

    return dict(edges), evidence


def greedy_color(pr_nums, conflict_edges, max_batch):
    """
    Greedy graph colouring: assign PRs to sub-batches so that no two
    conflicting PRs share a batch, and each batch contains ≤ max_batch PRs.

    Returns a list of lists (sub-batches), preserving original PR order
    within each batch.
    """
    batches = []
    for pr in pr_nums:
        placed = False
        for batch in batches:
            if len(batch) >= max_batch:
                continue
            if any(other in conflict_edges.get(pr, set()) for other in batch):
                continue
            batch.append(pr)
            placed = True
            break
        if not placed:
            batches.append([pr])
    return batches


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _env_str(var, default):
    """Return env var value, falling back to default if unset, empty, or 'null'."""
    val = os.environ.get(var, '').strip()
    return val if val and val.lower() != 'null' else str(default)


def _env_int(var, default):
    """Return env var as int, falling back to default if unset, empty, or 'null'."""
    try:
        return int(_env_str(var, default))
    except ValueError:
        return default


def _env_label_set(var, default):
    return set(
        x.strip()
        for x in _env_str(var, default).split(',')
        if x.strip()
    )


def main():
    required_labels = _env_label_set('REQUIRED_LABELS', DEFAULT_REQUIRED_LABELS)
    exclude_labels  = _env_label_set('EXCLUDE_LABELS',  DEFAULT_EXCLUDE_LABELS)
    suite_map     = json.loads(
        _env_str('COMPONENT_SUITE_MAP', json.dumps(DEFAULT_COMPONENT_SUITE_MAP))
    )
    depth              = _env_int('CONFLICT_PATH_DEPTH',  DEFAULT_CONFLICT_PATH_DEPTH)
    max_batch          = _env_int('MAX_PRS_PER_BATCH',    DEFAULT_MAX_PRS_PER_BATCH)
    updated_within     = _env_int('UPDATED_WITHIN_DAYS',  DEFAULT_UPDATED_WITHIN_DAYS)
    branch_filter      = _env_str('BASE_BRANCH_FILTER',   '').strip()
    cutoff             = (datetime.datetime.utcnow()
                          - datetime.timedelta(days=updated_within)).strftime('%Y-%m-%dT%H:%M:%SZ')

    def log(msg):
        print(msg, file=sys.stderr, flush=True)

    # -----------------------------------------------------------------------
    # 1. Fetch all open issues and filter to eligible PRs
    # -----------------------------------------------------------------------
    log(f'Fetching open issues from ceph/ceph updated since {cutoff} ...')
    issues   = _gh_paginate(
        f'https://api.github.com/repos/ceph/ceph/issues?state=open&since={cutoff}&sort=updated&direction=desc'
    )
    eligible = []
    skipped  = []

    for issue in issues:
        if 'pull_request' not in issue:
            continue

        num    = issue['number']
        labels = {lbl['name'] for lbl in issue.get('labels', [])}

        missing = required_labels - labels
        if missing:
            skipped.append((num, f'missing required labels: {sorted(missing)}'))
            continue

        blocked = exclude_labels & labels
        if blocked:
            skipped.append((num, f'has excluded labels: {sorted(blocked)}'))
            continue

        # Component labels in ceph/ceph are bare names: 'rgw', 'rbd', 'cephfs', etc.
        # Match any PR label that is a key in suite_map.
        component = next((lbl for lbl in labels if lbl in suite_map), None)
        if not component:
            skipped.append((num, 'no component label matching COMPONENT_SUITE_MAP'))
            continue

        if component not in suite_map:
            skipped.append((num, f'component "{component}" not in COMPONENT_SUITE_MAP'))
            continue

        try:
            detail = get_pr_detail(num)
        except urllib.error.HTTPError as exc:
            skipped.append((num, f'GH API error fetching PR detail: {exc}'))
            continue

        base     = detail['base']['ref']
        head_sha = detail['head']['sha']

        if branch_filter and base != branch_filter:
            skipped.append((num, f'base branch "{base}" excluded by BASE_BRANCH_FILTER'))
            continue

        # Idempotency: skip if this exact SHA was already batched and is still
        # pending (in ceph-ci) or passed (teuthology success).
        batch_state = get_latest_batch_status(head_sha)
        if batch_state in SKIP_STATES:
            skipped.append((num, f'commit status {BATCH_STATUS_CONTEXT}={batch_state}'
                                 f' on SHA {head_sha[:8]} – already batched'))
            continue

        eligible.append({
            'number':    num,
            'component': component,
            'branch':    base,
            'suite':     suite_map[component],
            'head_sha':  head_sha,
        })

    # Log a per-reason summary instead of one line per PR to keep output readable.
    skip_summary = {}
    for _num, reason in skipped:
        # Normalise to the reason category (strip the dynamic label list).
        category = reason.split(':')[0]
        skip_summary[category] = skip_summary.get(category, 0) + 1
    for category, count in sorted(skip_summary.items()):
        log(f'  Skipped {count} PR(s): {category}')
    log(f'Eligible PRs ({len(eligible)}): {[p["number"] for p in eligible]}')

    if not eligible:
        log('No eligible PRs found.')
        print('[]')
        return

    # -----------------------------------------------------------------------
    # 2. Group by (component, base_branch)
    # -----------------------------------------------------------------------
    # Build a SHA lookup so the Jenkinsfile can post commit statuses without
    # extra API calls.
    sha_map = {pr['number']: pr['head_sha'] for pr in eligible}

    groups = defaultdict(list)
    for pr in eligible:
        groups[(pr['component'], pr['branch'])].append(pr['number'])

    # -----------------------------------------------------------------------
    # 3. Fetch changed files, detect conflicts, split into sub-batches
    # -----------------------------------------------------------------------
    output = []

    for (component, branch), pr_nums in sorted(groups.items()):
        suite = suite_map[component]
        log(f'Group (component={component}, branch={branch}): PRs {pr_nums}')

        pr_file_map = {}
        for pr_num in pr_nums:
            log(f'  Fetching changed files for PR#{pr_num} ...')
            try:
                pr_file_map[pr_num] = get_pr_files(pr_num)
            except urllib.error.HTTPError as exc:
                log(f'  WARNING: cannot fetch files for PR#{pr_num}: {exc}'
                    ' – skipping conflict check for this PR')
                pr_file_map[pr_num] = frozenset()

        # Exclude documentation-only PRs: they need no package build or
        # teuthology suite and should be merged through a lighter process.
        doc_only = [pr for pr, files in pr_file_map.items() if is_doc_only(files)]
        if doc_only:
            for pr in doc_only:
                log(f'  Skipping PR#{pr}: documentation-only changes'
                    ' (no teuthology suite needed)')
            pr_nums  = [pr for pr in pr_nums  if pr not in doc_only]
            pr_file_map = {pr: f for pr, f in pr_file_map.items() if pr not in doc_only}

        if not pr_nums:
            log(f'  No non-doc PRs remain in group ({component}, {branch}) – skipping.')
            continue

        conflict_edges, evidence = build_conflict_graph(pr_file_map, depth)

        for (a, b), paths in evidence.items():
            log(f'  Conflict PR#{a}↔PR#{b}: {paths}')

        sub_batches = greedy_color(pr_nums, conflict_edges, max_batch)
        log(f'  → {len(sub_batches)} sub-batch(es): {sub_batches}')

        for idx, batch_prs in enumerate(sub_batches, 1):
            obj = {
                'component': component,
                'branch':    branch,
                'suite':     suite,
                'batch':     idx,
                'prs':       batch_prs,
                # pr_shas: str(pr_num) → HEAD SHA, used by Jenkinsfile to post
                # commit statuses without extra API calls.
                'pr_shas':   {str(p): sha_map[p] for p in batch_prs},
            }

            if len(sub_batches) > 1:
                reasons = []
                for pr in batch_prs:
                    for other in conflict_edges.get(pr, set()):
                        if other not in batch_prs:
                            key   = (min(pr, other), max(pr, other))
                            paths = evidence.get(key, [])
                            reasons.append(
                                f'PR#{pr}↔PR#{other}: {", ".join(paths[:3])}'
                            )
                if reasons:
                    obj['split_reason'] = '; '.join(sorted(set(reasons)))

            output.append(obj)

    log(f'Total sub-batches: {len(output)}')
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    main()
