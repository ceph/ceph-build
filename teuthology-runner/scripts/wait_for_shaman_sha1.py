#!/usr/bin/env python3
"""Wait for Shaman availability for branch/platform(s).

Modes:
  - With --sha1: wait until that exact SHA exists on all platforms.
  - Without --sha1 and without --use-available-sha: resolve branch tip via
    git ls-remote and wait for that exact SHA on all platforms.
  - Without --sha1 and with --use-available-sha: pick the newest SHA that is
    already available on Shaman, without waiting.
Exits 0 when ready, 1 on timeout. Prints SHA1 on success.
"""
import argparse
import subprocess
import sys
import time
try:
    import requests
except ImportError:
    print("pip install requests", file=sys.stderr)
    sys.exit(2)

SHAMAN_BUILD_URL = "https://shaman.ceph.com/api/repos/ceph/{branch}/{sha1}/{os_type}/{os_version}/flavors/{flavor}/"
SHAMAN_LATEST_URL = "https://shaman.ceph.com/api/repos/ceph/{branch}/latest/{os_type}/{os_version}/flavors/{flavor}/"


def _fetch_builds(url):
    r = requests.get(url, timeout=30)
    if not r.ok:
        return []
    payload = r.json()
    return payload if isinstance(payload, list) else [payload]


def sha1_on_platform(branch, platform, sha1, arch="x86_64"):
    parts = platform.split("-", 2)
    if len(parts) < 3:
        return False
    os_type, os_version, flavor = parts[0], parts[1], parts[2]
    url = SHAMAN_BUILD_URL.format(
        branch=branch,
        sha1=sha1,
        os_type=os_type,
        os_version=os_version,
        flavor=flavor,
    )
    try:
        builds = _fetch_builds(url)
        for b in builds:
            if arch in b.get("archs", []) and b.get("sha1") == sha1:
                return True
        return False
    except Exception:
        return False


def latest_sha_on_platform(branch, platform, arch="x86_64"):
    parts = platform.split("-", 2)
    if len(parts) < 3:
        return None
    os_type, os_version, flavor = parts[0], parts[1], parts[2]
    url = SHAMAN_LATEST_URL.format(branch=branch, os_type=os_type, os_version=os_version, flavor=flavor)
    try:
        builds = _fetch_builds(url)
        for b in builds:
            if arch in b.get("archs", []) and b.get("sha1"):
                return b.get("sha1")
        return None
    except Exception:
        return None


def resolve_branch_tip_sha(repo, branch):
    try:
        out = subprocess.check_output(
            ["git", "ls-remote", repo, f"refs/heads/{branch}"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=30,
        ).strip()
    except Exception:
        return None
    if not out:
        return None
    sha = out.split()[0].strip().lower()
    if len(sha) < 7:
        return None
    return sha


def latest_shas_on_platform(branch, platform, arch="x86_64"):
    parts = platform.split("-", 2)
    if len(parts) < 3:
        return []
    os_type, os_version, flavor = parts[0], parts[1], parts[2]
    url = SHAMAN_LATEST_URL.format(branch=branch, os_type=os_type, os_version=os_version, flavor=flavor)
    try:
        builds = _fetch_builds(url)
        out = []
        for b in builds:
            if arch in b.get("archs", []) and b.get("sha1"):
                out.append(b.get("sha1"))
        return out
    except Exception:
        return []


def newest_common_latest_sha(branch, platforms, arch="x86_64"):
    platform_shas = [latest_shas_on_platform(branch, p, arch) for p in platforms]
    if not all(platform_shas):
        return None
    common = set(platform_shas[0])
    for shas in platform_shas[1:]:
        common &= set(shas)
    if not common:
        return None
    # Keep platform order from the first platform list (newest first).
    for sha in platform_shas[0]:
        if sha in common:
            return sha
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--branch", required=True)
    ap.add_argument("--sha1", default="")
    ap.add_argument(
        "--platform",
        default="rocky-10-default,ubuntu-jammy-default,centos-9-default",
        help="Comma-separated Shaman platform keys (os-osver-flavor), e.g. ubuntu-noble-default.",
    )
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--arch", default="x86_64")
    ap.add_argument("--repo", default="https://github.com/ceph/ceph.git")
    ap.add_argument(
        "--use-available-sha",
        action="store_true",
        help="Without --sha1, pick newest SHA common across platforms without waiting.",
    )
    args = ap.parse_args()
    branch = args.branch.strip().lower()
    sha1 = args.sha1.strip().lower() if args.sha1 else ""
    platforms = [p.strip() for p in args.platform.split(",") if p.strip()] or ["rocky-10-default", "ubuntu-jammy-default", "centos-9-default"]

    # Fast path: no polling. Return newest currently available common SHA.
    if not sha1 and args.use_available_sha:
        chosen = newest_common_latest_sha(branch, platforms, args.arch)
        if chosen:
            print(chosen)
            return 0
        print(f"No common available SHA on Shaman for {branch}", file=sys.stderr)
        return 1

    if not sha1:
        sha1 = resolve_branch_tip_sha(args.repo.strip(), branch)
        if not sha1:
            print(
                f"Could not resolve branch tip via git ls-remote for repo={args.repo} branch={branch}",
                file=sys.stderr,
            )
            return 1

    start = time.monotonic()
    while True:
        if sha1:
            if all(sha1_on_platform(branch, p, sha1, args.arch) for p in platforms):
                print(sha1)
                return 0
        if time.monotonic() - start >= args.timeout:
            if sha1:
                print(f"Timeout: SHA1 {sha1} not on Shaman for {branch}", file=sys.stderr)
            return 1
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
