"""Shared GitHub REST helpers for auto-ptl-batch.

Credentials come from the environment only (GITHUB_PASS, optionally GITHUB_USER).
Jenkins should inject them via credentials-binding or withCredentials — never
pass tokens on the command line.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

EXIT_API_ERROR = 3
_API_VERSION = '2022-11-28'
_RETRYABLE = frozenset({403, 429})


def token():
    return os.environ.get('GITHUB_PASS', '').strip()


def require_token():
    if not token():
        sys.stderr.write(
            'GITHUB_PASS is not set. Bind credential github-readonly-token '
            '(JJB credentials-binding or pipeline withCredentials).\n',
        )
        sys.exit(EXIT_API_ERROR)


def _headers():
    headers = {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': _API_VERSION,
    }
    tok = token()
    if tok:
        headers['Authorization'] = 'Bearer ' + tok
    return headers


def _retry_after_seconds(exc):
    try:
        return int(exc.headers.get('Retry-After', '0'))
    except (TypeError, ValueError):
        return 0


def _request(method, url, body=None, timeout=20, retries=3):
    require_token()
    data = None
    headers = _headers()
    if body is not None:
        headers = dict(headers)
        headers['Content-Type'] = 'application/json'
        data = json.dumps(body).encode('utf-8')

    last_exc = None
    for attempt in range(retries):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            last_exc = exc
            if exc.code not in _RETRYABLE or attempt >= retries - 1:
                raise
            wait = _retry_after_seconds(exc)
            if wait <= 0:
                wait = min(60, 2 ** attempt)
            time.sleep(wait)

    raise last_exc


def gh_get(url, timeout=20, retries=3):
    return _request('GET', url, timeout=timeout, retries=retries)


def gh_post(url, body, timeout=20, retries=3):
    return _request('POST', url, body=body, timeout=timeout, retries=retries)


def gh_paginate(base_url, timeout=20, retries=3):
    """Fetch all pages from a GitHub list endpoint."""
    results = []
    page = 1
    while True:
        sep = '&' if '?' in base_url else '?'
        data = gh_get(
            f'{base_url}{sep}per_page=100&page={page}',
            timeout=timeout,
            retries=retries,
        )
        if not data:
            break
        results.extend(data)
        if len(data) < 100:
            break
        page += 1
    return results
