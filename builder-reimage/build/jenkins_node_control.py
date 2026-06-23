#!/usr/bin/env python3

"""
Manage Jenkins node offline state for builder reimage.

Actions:
  prepare_for_reimage
    Validate node state and mark it temporarily offline if needed.

  restore_after_reimage
    Restore node online if it was marked offline by this job.

Usage:
  jenkins_node_control.py --action <action> --jenkins_url <url> --user <user> --token <token> --node <node> --state-file <file> [--message <text>]
"""

import argparse
import json
import os
import sys
import time
from urllib.parse import quote

import requests


def get_crumb(session, base_url):
    crumb_url = f"{base_url}/crumbIssuer/api/json"
    r = session.get(crumb_url)
    if r.status_code == 404:
        return {}
    r.raise_for_status()
    data = r.json()
    return {data["crumbRequestField"]: data["crumb"]}


def normalize_base_url(url):
    return url.rstrip("/")


def resolve_node_name(session, base_url, short_name):
    api_url = f"{base_url}/computer/api/json"
    r = session.get(api_url)
    r.raise_for_status()

    for node in r.json().get("computer", []):
        display_name = node.get("displayName", "")
        if display_name == short_name:
            return display_name
        if display_name.endswith(f"+{short_name}"):
            return display_name
        if short_name in display_name:
            return display_name

    return None


def get_node_info(session, base_url, node_name):
    encoded = quote(node_name, safe="")
    api_url = (
        f"{base_url}/computer/{encoded}/api/json"
        "?tree=displayName,offline,temporarilyOffline,offlineCauseReason,"
        "executors[currentExecutable[url]],oneOffExecutors[currentExecutable[url]]"
    )
    r = session.get(api_url)
    r.raise_for_status()
    return r.json()


def node_is_busy(node_info):
    for executor in node_info.get("executors", []):
        if executor.get("currentExecutable"):
            return True

    for executor in node_info.get("oneOffExecutors", []):
        if executor.get("currentExecutable"):
            return True

    return False


def wait_until_idle(session, base_url, node_name, timeout=3600, interval=15):
    waited = 0

    while waited < timeout:
        node_info = get_node_info(session, base_url, node_name)

        if not node_is_busy(node_info):
            print(f"[INFO] {node_name} is now idle", flush=True)
            return True

        print(f"[INFO] {node_name} is currently running a job. Waiting for it to finish before reimage.", flush=True)
        time.sleep(interval)
        waited += interval

    print(f"[ERROR] Timed out waiting for {node_name} to become idle", flush=True)
    return False


def mark_offline(session, base_url, node_name, message, headers):
    encoded = quote(node_name, safe="")
    url = f"{base_url}/computer/{encoded}/toggleOffline"
    r = session.post(url, data={"offlineMessage": message}, headers=headers)
    r.raise_for_status()


def mark_online(session, base_url, node_name, headers):
    encoded = quote(node_name, safe="")
    url = f"{base_url}/computer/{encoded}/toggleOffline"
    r = session.post(url, headers=headers)
    r.raise_for_status()


def save_state(path, state):
    with open(path, "w") as f:
        json.dump(state, f)


def load_state(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", required=True, choices=["prepare_for_reimage", "restore_after_reimage"])
    parser.add_argument("--jenkins_url", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--node", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--message", default="Marked temporary offline for builder reimage activity")
    args = parser.parse_args()

    base_url = normalize_base_url(args.jenkins_url)
    short_name = args.node.split(".")[0]

    session = requests.Session()
    session.auth = (args.user, args.token)
    headers = get_crumb(session, base_url)

    if args.action == "prepare_for_reimage":
        node_name = resolve_node_name(session, base_url, short_name)
        if node_name is None:
            print(f"[WARN] No Jenkins node found for {short_name}; skipping offline preparation", flush=True)
            sys.exit(0)

        node_info = get_node_info(session, base_url, node_name)

        state = {
            "short_name": short_name,
            "node_name": node_name,
            "was_offline": bool(node_info.get("offline")),
            "marked_offline_by_job": False,
        }

        if node_info.get("offline"):
            print(f"[INFO] {short_name} is already offline in Jenkins", flush=True)
            save_state(args.state_file, state)

            if node_is_busy(node_info):
                print(f"[INFO] {short_name} is currently running a job. Waiting for it to finish before reimage.", flush=True)

            if not wait_until_idle(session, base_url, node_name):
                sys.exit(1)

            sys.exit(0)

        print(f"[ACTION] Marking {short_name} temporarily offline", flush=True)
        mark_offline(session, base_url, node_name, args.message, headers)

        state["marked_offline_by_job"] = True
        save_state(args.state_file, state)
        print(f"[SUCCESS] {short_name} marked temporarily offline", flush=True)

        if node_is_busy(node_info):
            print(f"[INFO] {short_name} is currently running a job. Waiting for it to finish before reimage.", flush=True)

        if not wait_until_idle(session, base_url, node_name):
            sys.exit(1)

        sys.exit(0)

    if args.action == "restore_after_reimage":
        state = load_state(args.state_file)
        if not state:
            print("[INFO] No Jenkins node state file found. Nothing to restore.")
            sys.exit(0)

        if state.get("was_offline"):
            print(f"[INFO] {state['short_name']} was already offline before this job. Leaving it offline.")
            sys.exit(0)

        if not state.get("marked_offline_by_job"):
            print(f"[INFO] {state['short_name']} was not marked offline by this job. Nothing to restore.")
            sys.exit(0)

        print(f"[ACTION] Bringing {state['short_name']} back online")
        mark_online(session, base_url, state["node_name"], headers)
        print(f"[SUCCESS] {state['short_name']} brought back online")
        sys.exit(0)


if __name__ == "__main__":
    main()
