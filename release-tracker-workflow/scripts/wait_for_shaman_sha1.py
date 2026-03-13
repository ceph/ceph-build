#!/usr/bin/env python3
"""Wait until a given git SHA1 appears on Shaman for branch/platform(s). Exits 0 when ready, 1 on timeout. Prints SHA1 on success."""
import argparse
import sys
import time
try:
    import requests
except ImportError:
    print("pip install requests", file=sys.stderr)
    sys.exit(2)

SHAMAN_BUILD_URL = "https://shaman.ceph.com/api/repos/ceph/{branch}/latest/{os_type}/{os_version}/flavors/{flavor}"

def sha1_on_platform(branch, platform, sha1, arch="x86_64"):
    parts = platform.split("-", 2)
    if len(parts) < 3:
        return False
    os_type, os_version, flavor = parts[0], parts[1], parts[2]
    url = SHAMAN_BUILD_URL.format(branch=branch, os_type=os_type, os_version=os_version, flavor=flavor)
    try:
        r = requests.get(url, timeout=30, verify=False)
        if not r.ok:
            return False
        for b in r.json():
            if arch in b.get("archs", []) and b.get("sha1") == sha1:
                return True
        return False
    except Exception:
        return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--branch", required=True)
    ap.add_argument("--sha1", required=True)
    ap.add_argument("--platform", default="ubuntu-jammy-default,centos-9-default")
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--arch", default="x86_64")
    args = ap.parse_args()
    branch = args.branch.strip().lower()
    sha1 = args.sha1.strip().lower()
    platforms = [p.strip() for p in args.platform.split(",") if p.strip()] or ["ubuntu-jammy-default", "centos-9-default"]
    start = time.monotonic()
    while True:
        if all(sha1_on_platform(branch, p, sha1, args.arch) for p in platforms):
            print(sha1)
            return 0
        if time.monotonic() - start >= args.timeout:
            print(f"Timeout: SHA1 {sha1} not on Shaman for {branch}", file=sys.stderr)
            return 1
        time.sleep(args.interval)

if __name__ == "__main__":
    sys.exit(main())
