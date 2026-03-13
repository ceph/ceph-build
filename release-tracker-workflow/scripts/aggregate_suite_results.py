#!/usr/bin/env python3
"""Fetch job results from Paddles for a run and output aggregated pass/fail table. Usage: aggregate_suite_results.py --run RUN_NAME [--paddles-url URL] [--out FILE]"""
import argparse
import sys
try:
    import requests
except ImportError:
    print("pip install requests", file=sys.stderr)
    sys.exit(2)

DEFAULT_PADDLES = "http://paddles.front.sepia.ceph.com/"

def get_jobs(paddles_url, run_name, fields=None):
    fields = fields or ["job_id", "status", "description"]
    if "job_id" not in fields:
        fields = list(fields) + ["job_id"]
    uri = f"{paddles_url.rstrip('/')}/runs/{run_name}/jobs/?fields={','.join(fields)}"
    try:
        r = requests.get(uri, timeout=60)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        print(f"Failed to get jobs: {e}", file=sys.stderr)
        return None

def suite_from_desc(desc):
    return (desc or "unknown").split("/")[0] if "/" in (desc or "") else (desc or "unknown").split()[0] if desc else "unknown"

def aggregate(jobs):
    by_suite = {}
    for j in jobs:
        desc = j.get("description") or ""
        status = (j.get("status") or "unknown").lower()
        suite = suite_from_desc(desc)
        if suite not in by_suite:
            by_suite[suite] = {"pass": 0, "fail": 0}
        if status == "pass":
            by_suite[suite]["pass"] += 1
        else:
            by_suite[suite]["fail"] += 1
    return {s: "PASS" if c["fail"] == 0 and c["pass"] > 0 else "FAIL" for s, c in by_suite.items()}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--paddles-url", default=DEFAULT_PADDLES)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    jobs = get_jobs(args.paddles_url, args.run)
    if jobs is None:
        sys.exit(1)
    if not jobs:
        table = "No jobs found"
    else:
        agg = aggregate(jobs)
        table = "\n".join(["Suite | Status", "------|------"] + [f"{k} | {v}" for k, v in sorted(agg.items())])
    print(table)
    if args.out:
        with open(args.out, "w") as f:
            f.write(table)
    return 0

if __name__ == "__main__":
    sys.exit(main())
