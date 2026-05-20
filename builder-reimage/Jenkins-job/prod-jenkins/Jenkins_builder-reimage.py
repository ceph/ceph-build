#!/usr/bin/env python3
"""
MAAS Reimage Automation Script (Enhanced)

Supports:
- Single machine (unchanged)
- Multiple machines: host1,host2
- Per-machine OS: host1:jammy,host2:focal
- Mixed mode: host1,host2:jammy
"""

import asyncio
import argparse
import sys
import time
from datetime import datetime
import os

from maas.client import connect
from aiohttp.client_exceptions import (
    ClientConnectorError,
    ServerDisconnectedError,
    ClientResponseError,
    ClientOSError
)

# -------------------------------------------------------------------------
# Global Defaults
# -------------------------------------------------------------------------
LOG_FILE_DEFAULT = "maas_reimage.log"
STATUS_WAIT_TIMEOUT = 1200
DEFAULT_OWNER = "jitendra"

MAAS_URL = "http://soko02.front.sepia.ceph.com:5240/MAAS"
MAAS_API_KEY = os.environ.get("MAAS_API_KEY")

if not MAAS_API_KEY:
    print("Error: MAAS_API_KEY env variable not set")
    sys.exit(1)

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------
def log(msg, log_file=None):
    print(msg)
    if log_file:
        with open(log_file, "a") as f:
            f.write(f"{datetime.now().isoformat()} - {msg}\n")

def get_normalized_status(machine):
    return str(
        getattr(machine, "status_name", "") or
        getattr(getattr(machine, "status", None), "name", "")
    ).lower()

# NEW: parse machine + OS mapping
def parse_machine_list(machine_arg, default_os=None):
    result = []

    items = [x.strip() for x in machine_arg.split(",") if x.strip()]

    for item in items:
        if ":" in item:
            host, os_val = item.split(":", 1)
            result.append((host.strip(), os_val.strip()))
        else:
            result.append((item.strip(), default_os))

    return result

# -------------------------------------------------------------------------
# Connect
# -------------------------------------------------------------------------
async def connect_maas():
    try:
        return await connect(MAAS_URL, apikey=MAAS_API_KEY)
    except Exception as e:
        print(f"Connection failed: {e}")
        sys.exit(1)

async def get_cached_machines(client):
    if getattr(client, "_machines_cache", None) is None:
        client._machines_cache = await client.machines.list()
    return client._machines_cache

# -------------------------------------------------------------------------
# Wait for status
# -------------------------------------------------------------------------
async def wait_for_status(client, system_id, expected):
    expected = expected.lower()
    start = time.time()

    while time.time() - start < STATUS_WAIT_TIMEOUT:
        m = await client.machines.get(system_id=system_id)
        if get_normalized_status(m) == expected:
            return True
        await asyncio.sleep(5)

    print(f"Timeout waiting for {system_id}")
    return False

# -------------------------------------------------------------------------
# Deploy
# -------------------------------------------------------------------------
async def deploy_machine(client, hostname, os_release, log_file):
    machines = await get_cached_machines(client)
    m = next((x for x in machines if x.hostname == hostname), None)

    if not m:
        log(f"[ERROR] {hostname} not found", log_file)
        return False

    m = await client.machines.get(system_id=m.system_id)

    status = get_normalized_status(m)

    if status == "deployed":
        log(f"[INFO] {hostname} already deployed", log_file)
        return True

    os_to_use = os_release or getattr(m, "distro_series", "focal")

    log(f"[ACTION] Deploying {hostname} with {os_to_use}", log_file)

    try:
        await m.deploy(distro_series=os_to_use)
    except Exception as e:
        log(f"[ERROR] Deploy failed: {e}", log_file)
        return False

    if await wait_for_status(client, m.system_id, "deployed"):
        log(f"[SUCCESS] {hostname} deployed", log_file)
        return True

    return False

# -------------------------------------------------------------------------
# Release
# -------------------------------------------------------------------------
async def release_machine(machine):
    if get_normalized_status(machine) == "deployed":
        await machine.release()

# -------------------------------------------------------------------------
# Reimage
# -------------------------------------------------------------------------
async def reimage_machine(client, hostname, os_release, log_file):
    machines = await get_cached_machines(client)
    m = next((x for x in machines if x.hostname == hostname), None)

    if not m:
        log(f"[ERROR] {hostname} not found", log_file)
        return False

    m = await client.machines.get(system_id=m.system_id)

    status = get_normalized_status(m)

    if status == "deployed":
        log(f"[ACTION] Releasing {hostname}", log_file)
        await release_machine(m)
        if not await wait_for_status(client, m.system_id, "ready"):
            return False

    return await deploy_machine(client, hostname, os_release, log_file)

# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------
async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", required=True)
    parser.add_argument("--machine")
    parser.add_argument("--os")
    parser.add_argument("--log-file")

    args = parser.parse_args()
    log_file = args.log_file or LOG_FILE_DEFAULT

    client = await connect_maas()
    client._machines_cache = await client.machines.list()

    # UPDATED: multi-machine support
    if args.action == "reimage":
        if not args.machine:
            print("Missing --machine")
            return

        machine_list = parse_machine_list(args.machine, args.os)

        success = 0
        failed = 0

        for hostname, os_val in machine_list:
            log(f"\n[START] {hostname} (OS={os_val})", log_file)
            try:
                result = await reimage_machine(client, hostname, os_val, log_file)
                if result:
                    success += 1
                else:
                    failed += 1
            except Exception as e:
                log(f"[ERROR] {hostname}: {e}", log_file)
                failed += 1

        log("\n===== SUMMARY =====", log_file)
        log(f"Total: {len(machine_list)}", log_file)
        log(f"Success: {success}", log_file)
        log(f"Failed: {failed}", log_file)

# -------------------------------------------------------------------------

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Interrupted by user.")
    except Exception as e:
        print(f"Fatal error: {e}")
