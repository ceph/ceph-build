#!/usr/bin/env python3

import json
import sys

from os import environ as env

result = {
    "url": env["BUILD_URL"],
    "project": "ceph",
    "repo": env["CEPH_REPO"],
    "branch": env["BRANCH"],
    "sha1": env["SHA1"],
    "distro": env["DIST"],
    "arch": env["ARCH"],
    "flavor": env["FLAVOR"],
    "timestamp": int(env["BUILD_STARTED"]),
    "status": env["BUILD_STATUS"],
}

if "BUILD_DURATION" in env:
    result["duration"] = int(env["BUILD_DURATION"])

if len(sys.argv) > 1:
    raw_stats = json.loads(open(sys.argv[1]).read())
    stats = {
        "cache_requested": raw_stats["compile_requests"],
        "cache_executed": raw_stats["requests_executed"],
        "cache_hits": sum(raw_stats["cache_hits"]["counts"].values()),
        "cache_misses": sum(raw_stats["cache_misses"]["counts"].values()),
    }
    result.update(stats)

print(json.dumps(result))
