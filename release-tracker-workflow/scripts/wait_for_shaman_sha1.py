#!/usr/bin/env python3
"""Wait for Shaman availability for branch/platform(s).

Modes:
  - With --sha1: wait until that exact SHA exists on all platforms.
  - Without --sha1: poll latest endpoints until all platforms converge to the
    same latest SHA.
Exits 0 when ready, 1 on timeout. Prints SHA1 on success.
"""
import argparse
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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--branch", required=True)
    ap.add_argument("--sha1", default="")
    ap.add_argument(
        "--platform",
        default="ubuntu-noble-default,centos-9-default",
        help="Comma-separated Shaman platform keys (os-osver-flavor), e.g. ubuntu-noble-default.",
    )
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--arch", default="x86_64")
    args = ap.parse_args()
    branch = args.branch.strip().lower()
    sha1 = args.sha1.strip().lower() if args.sha1 else ""
    platforms = [p.strip() for p in args.platform.split(",") if p.strip()] or ["ubuntu-noble-default", "centos-9-default"]
    start = time.monotonic()
    while True:
        if sha1:
            if all(sha1_on_platform(branch, p, sha1, args.arch) for p in platforms):
                print(sha1)
                return 0
        else:
            latest = [latest_sha_on_platform(branch, p, args.arch) for p in platforms]
            if all(latest) and len(set(latest)) == 1:
                print(latest[0])
                return 0
        if time.monotonic() - start >= args.timeout:
            if sha1:
                print(f"Timeout: SHA1 {sha1} not on Shaman for {branch}", file=sys.stderr)
            else:
                print(f"Timeout: no converged latest SHA on Shaman for {branch}", file=sys.stderr)
            return 1
        time.sleep(args.interval)

if __name__ == "__main__":
    sys.exit(main())
