#!/usr/bin/env python3

import json
import sys

from os import environ as env
from pathlib import Path
from typing import Union

result: dict[str, Union[int,str]] = {
    "url": env["BUILD_URL"],
    "project": "ceph",
    "repo": env["CEPH_REPO"],
    "branch": env["BRANCH"],
    "sha1": env["SHA1"],
    "distro": env["DIST"],
    "arch": env["ARCH"],
    "flavor": env["FLAVOR"],
    "status": env["BUILD_STATUS"],
}

if "BUILD_STARTED" in env:
    result["timestamp"] = int(float(env["BUILD_STARTED"]))
if "BUILD_DURATION" in env:
    result["duration"] = int(float(env["BUILD_DURATION"]))

if len(sys.argv) > 1:
    stats_file = Path(sys.argv[1])
    if stats_file.exists():
        raw_stats = json.loads(stats_file.read_text())
        stats = {
            "cache_requested": raw_stats["compile_requests"],
            "cache_executed": raw_stats["requests_executed"],
            "cache_hits": sum(raw_stats["cache_hits"]["counts"].values()),
            "cache_misses": sum(raw_stats["cache_misses"]["counts"].values()),
        }
        result.update(stats)

print(json.dumps(result))
