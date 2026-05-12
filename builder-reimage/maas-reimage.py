#!.venv/bin/python3
"""
MAAS Reimage Automation Script

Provides:
- Connect to MAAS
- Query machines
- List machines
- Deploy a machine
- Reimage a machine
- Reimage all machines
- List OS images
"""

import asyncio
import argparse
import configparser
import sys
import time
from datetime import datetime, timezone
from cryptography.fernet import Fernet

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
STATUS_WAIT_TIMEOUT = 600
POLL_INTERVAL = 10
DEFAULT_OWNER = "jitendra" # use --owner to tag manually

# -------------------------------------------------------------------------
# Small helpers
# -------------------------------------------------------------------------

def log(msg, log_file=None):
    """Print message and optionally append to a log file with a timestamp."""
    print(msg)
    if log_file:
        try:
            with open(log_file, "a") as f:
                f.write(f"{datetime.now().isoformat()} - {msg}\n")
        except Exception:
            print(f"(warning) Unable to write to log file: {log_file}")

def sanitize_owner(name):
    return name.replace(" ", "_").replace("@", "_")

async def safe_list_tags_for_machine(machine):
    """
    Return list of tag objects applied to the machine.
    Some MAAS clients expose machine.tags as a proxy; the reliable way is:
    await machine.tags.list()
    """
    try:
        return await machine.tags.list()
    except Exception:
        # fallback: try to read machine.tags attribute (may not be useful)
        mt = getattr(machine, "tags", None)
        if isinstance(mt, list):
            return mt
        return []

def get_normalized_status(machine):
    """
    Return lowercased status name using the most reliable available attribute.
    Handles both `status_name` and `status.name` forms.
    """
    status_name = getattr(machine, "status_name", None)
    if status_name:
        return str(status_name).lower()
    status_obj = getattr(machine, "status", None)
    if status_obj is not None:
        name = getattr(status_obj, "name", None)
        if name:
            return str(name).lower()
    return ""

# -------------------------------------------------------------------------
# Config + API key
# -------------------------------------------------------------------------

def load_config():
    """Load MAAS URL from maas.conf."""
    config = configparser.ConfigParser()
    config.read("maas.conf")
    try:
        return config.get("maas", "maas_url")
    except Exception:
        print("Error: Invalid maas.conf. Expected:\n\n[maas]\nmaas_url=http://<MAAS>/MAAS\n")
        sys.exit(1)

def load_api_key():
    """Decrypt and return the MAAS API key from local files."""
    try:
        with open("maas_api.key", "rb") as key_file:
            key = key_file.read()
        with open("maas_api_key.encrypted", "rb") as enc_file:
            encrypted = enc_file.read()
    except FileNotFoundError:
        print("Missing key files: maas_api.key or maas_api_key.encrypted")
        sys.exit(1)

    fernet = Fernet(key)
    return fernet.decrypt(encrypted).decode().strip()

# -------------------------------------------------------------------------
# MAAS connect with retries
# -------------------------------------------------------------------------

async def connect_maas(maas_url, api_key, retries=3):
    """Connect to MAAS and return client; show progress messages."""
    for attempt in range(1, retries + 1):
        try:
            log("Connecting to MAAS...")
            client = await connect(maas_url, apikey=api_key)
            log("Connected to MAAS.")
            return client
        except (ClientConnectorError, ClientOSError) as e:
            print(f"Connection attempt {attempt} failed: {e}")
        except ClientResponseError as e:
            print(f"MAAS error {e.status}: {e.message}")
        except (ServerDisconnectedError, asyncio.TimeoutError):
            print(f"MAAS connection dropped (attempt {attempt})")

        if attempt < retries:
            log("Retrying in 2 seconds...")
            await asyncio.sleep(2)

    print("Error: Unable to connect to MAAS after several attempts.")
    print("Please check:")
    print("  • Network or VPN connection")
    print("  • MAAS server hostname and port")
    print("  • MAAS service availability")
    sys.exit(1)

# -------------------------------------------------------------------------
# Cache + refresh helpers
# -------------------------------------------------------------------------

async def get_cached_machines(client):
    """Return a cached copy of client.machines.list() for script lifetime."""
    if getattr(client, "_machines_cache", None) is None:
        log("Fetching machines list...")
        client._machines_cache = await client.machines.list()
    return client._machines_cache

async def refresh_machine(client, machine):
    """
    Refresh machine object. Prefer machine.refresh() if available.
    """
    try:
        ref = getattr(machine, "refresh", None)
        if callable(ref):
            maybe = ref()
            if asyncio.iscoroutine(maybe):
                await maybe
            return machine
    except Exception:
        pass

    try:
        return await client.machines.get(system_id=machine.system_id)
    except Exception:
        return machine

# -------------------------------------------------------------------------
# Tag-based ownership helpers
# -------------------------------------------------------------------------

async def ensure_tag_exists(client, tag_name, log_file=None):
    """Ensure a tag with `tag_name` exists in MAAS; create it if not."""
    try:
        tags = await client.tags.list()
        if not any(getattr(t, "name", t) == tag_name for t in tags):
            log(f"Creating tag '{tag_name}'...", log_file)
            await client.tags.create(name=tag_name)
        return True
    except Exception as e:
        log(f"[ERROR] Unable to ensure tag exists '{tag_name}': {e}", log_file)
        return False

async def assign_owner_tag(client, machine, owner_name, log_file=None):
    """
    Assign owner tag to machine using client.tags.get() and machine.tags.add(tag).
    Refresh machine after applying tag so later reads see it.
    """
    sanitized = sanitize_owner(owner_name)
    if not await ensure_tag_exists(client, sanitized, log_file):
        return False

    try:
        tag = await client.tags.get(name=sanitized)
        applied = await safe_list_tags_for_machine(machine)
        applied_names = [getattr(t, "name", None) for t in applied]
        if sanitized in applied_names:
            return True

        log(f"Assigning tag '{sanitized}' to {machine.hostname}...", log_file)
        await machine.tags.add(tag)
        # Refresh so tag is visible
        await refresh_machine(client, machine)
        return True
    except Exception as e:
        log(f"[ERROR] Failed to assign tag '{sanitized}' to {getattr(machine, 'hostname', machine)}: {e}", log_file)
        return False

async def get_owner_from_tags(client, machine, owner_pattern):
    """
    Determine owner by checking machine's applied tags.
    owner_pattern should be sanitized (e.g., DEFAULT_OWNER sanitized).
    Returns the matching tag name or '-' if none.
    """
    try:
        applied = await safe_list_tags_for_machine(machine)
        applied_names = [getattr(t, "name", None) for t in applied]
        if owner_pattern in applied_names:
            return owner_pattern
        # try prefix match too
        for n in applied_names:
            if n and n.startswith(owner_pattern):
                return n
    except Exception:
        pass
    return "-"

# -------------------------------------------------------------------------
# Query Machine
# -------------------------------------------------------------------------

async def query_machine(client, hostname, log_file=None, quiet=False):
    """
    Query machine details and print them.
    Owner detection is tag-based (matches sanitized DEFAULT_OWNER).
    """
    owner_tag = "-"  # initialize to avoid undefined variable on errors

    try:
        machines = await get_cached_machines(client)
    except Exception as e:
        log(f"[ERROR] Unable to fetch machines list: {e}", log_file)
        return None

    system_id = None
    for m in machines:
        if m.hostname == hostname:
            system_id = m.system_id
            break

    if not system_id:
        log(f"[ERROR] Machine '{hostname}' not found.", log_file)
        return None

    try:
        log(f"Fetching details for {hostname}...", log_file)
        machine = await client.machines.get(system_id=system_id)
    except Exception as e:
        log(f"[ERROR] Unable to fetch machine details: {e}", log_file)
        return None

    if not quiet:
        sanitized = sanitize_owner(DEFAULT_OWNER)
        owner_tag = await get_owner_from_tags(client, machine, sanitized)

        # Fetch all tags applied to this machine for display
        try:
            applied = await safe_list_tags_for_machine(machine)
            tag_names = [getattr(t, "name", None) for t in applied if getattr(t, "name", None)]
            tags_display = ", ".join(tag_names) if tag_names else "-"
        except Exception:
            tags_display = "-"

        # resolve status display
        status_display = getattr(machine, "status_name", None)
        if not status_display:
            st = getattr(machine, "status", None)
            status_display = getattr(st, "name", "-") if st else "-"

        log("\nMachine Details\n" + "-" * 60, log_file)
        log(
            f"Name:             {machine.hostname}\n"
            f"System ID:        {machine.system_id}\n"
            f"Status:           {status_display}\n"
            f"OS Distro:        {getattr(machine, 'distro_series', '-')}\n"
            f"OS Type:          {getattr(machine, 'osystem', '-')}\n"
           # f"Owner:            {owner_tag}\n"
           # f"Tags:             {tags_display}\n"
            f"Power Type:       {getattr(machine, 'power_type', '-')}\n"
            f"Power Status:     {getattr(machine, 'power_state', '-')}",
            log_file
        )

    return machine

# -------------------------------------------------------------------------
# List machines / distros
# -------------------------------------------------------------------------

async def list_machines(client, log_file=None):
    machines = await get_cached_machines(client)
    log(f"{'Hostname':20} | {'System ID':10} | {'Status':10} | {'OS':10}", log_file)
    log("-" * 65, log_file)
    for m in machines:
        status_display = getattr(m, "status_name", None) or getattr(getattr(m, "status", None), "name", "-")
        osname = getattr(m, "distro_series", "-")
        log(f"{m.hostname:20} | {m.system_id:10} | {status_display:10} | {osname:10}", log_file)

async def list_distros(client, log_file=None):
    try:
        log("Fetching available OS images...", log_file)
        resources = await client.boot_resources.list()
    except Exception as e:
        log(f"[ERROR] Unable to list boot resources: {e}", log_file)
        return

    log(f"{'ID':<5} | {'OS Type':<15} | {'Release':<15} | {'Architecture':<12}", log_file)
    log("-" * 60, log_file)
    for r in resources:
        name = getattr(r, "name", "-")
        os_type, release = "-", "-"
        if "/" in name:
            os_type, release = name.split("/", 1)
        log(f"{r.id:<5} | {os_type:<15} | {release:<15} | {r.architecture:<12}", log_file)

# -------------------------------------------------------------------------
# Status polling helper
# -------------------------------------------------------------------------

async def wait_for_status(client, system_id, expected, timeout=STATUS_WAIT_TIMEOUT):
    """
    Wait for a machine to reach the expected state (case-insensitive).
    """
    log(f"Waiting for machine {system_id} to reach '{expected}'...", None)
    start = time.time()
    poll = 2
    max_poll = 8
    expected_l = expected.lower()

    while time.time() - start < timeout:
        try:
            m = await client.machines.get(system_id=system_id)
        except Exception as e:
            print(f"Error fetching machine {system_id}: {e}")
            await asyncio.sleep(poll)
            poll = min(max_poll, poll + 1)
            continue

        current = get_normalized_status(m)
        if current == expected_l:
            log(f"{getattr(m, 'hostname', system_id)} reached expected status: {expected}", None)
            return True

        await asyncio.sleep(poll)
        poll = min(max_poll, poll + 1)

    print(f"Timeout waiting for {system_id} to reach {expected}.")
    return False

# -------------------------------------------------------------------------
# Deploy machine
# -------------------------------------------------------------------------

async def deploy_machine(client, machine_ref, os_release=None, log_file=None):
    """
    Deploy (reimage) a machine. Accepts hostname (str) or machine object.
    NOTE: this function assumes owner tag is already applied when called from reimage flow.
    If user invokes deploy action directly, main() will ensure tag is applied before calling this.
    """
    if isinstance(machine_ref, str):
        # Avoid calling query_machine() (which prints full details) to prevent duplicate fetches.
        machines = await get_cached_machines(client)
        found = next((m for m in machines if m.hostname == machine_ref), None)
        if not found:
            log(f"[ERROR] Machine '{machine_ref}' not found.", log_file)
            return False
        machine = await client.machines.get(system_id=found.system_id)
    else:
        machine = machine_ref

    machine = await refresh_machine(client, machine)

    hostname = machine.hostname
    system_id = machine.system_id
    status = get_normalized_status(machine)

    if status == "deployed":
        log(f"[INFO] {hostname} is already deployed.", log_file)
        return True

    if status in ["failed", "broken", "error", "unknown"]:
        log(f"[ERROR] {hostname} cannot be reimaged (state: {status}).", log_file)
        return False

    os_to_use = os_release or getattr(machine, "distro_series", None) or "focal"
    log(f"[ACTION] Reimaging {hostname} using OS '{os_to_use}'...", log_file)

    try:
        await machine.deploy(distro_series=os_to_use)
    except Exception as e:
        log(f"[ERROR] Failed to trigger reimage for {hostname}: {e}", log_file)
        return False

    if not await wait_for_status(client, system_id, "deployed"):
        log(f"[ERROR] Reimage timeout for {hostname}.", log_file)
        return False

    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    log(f"[SUCCESS] Reimage completed for {hostname}.", log_file)
    log(f"[INFO] Deployment timestamp for {hostname}: {ts} IST", log_file)
    return True

# -------------------------------------------------------------------------
# Release machine
# -------------------------------------------------------------------------

async def release_machine(client, machine, log_file=None):
    status = get_normalized_status(machine)
    if status != "deployed":
        return True

    log(f"[ACTION] Releasing {machine.hostname}...", log_file)
    try:
        await machine.release()
        return True
    except Exception as e:
        log(f"[ERROR] Failed to release: {e}", log_file)
        return False

# -------------------------------------------------------------------------
# Reimage machine
# -------------------------------------------------------------------------

async def reimage_machine(client, hostname, os_release=None, log_file=None):
    # First, fetch machine (and print its details)
    machine = await query_machine(client, hostname, log_file)
    if not machine:
        return

    force_flag = getattr(args, "force", False)
    status = get_normalized_status(machine)

    if force_flag and status == "deploying":
        log(f"[FORCE] Aborting active deployment for {hostname}...", log_file)
        try:
            await machine.abort()
        except Exception as e:
            log(f"[ERROR] Unable to abort deployment for {hostname}: {e}", log_file)
            return

        if not await wait_for_status(client, machine.system_id, "ready"):
            log("[ERROR] Machine did not reach Ready state after abort.", log_file)
            return

        log(f"[FORCE] Deployment aborted. Releasing {hostname}...", log_file)
        try:
            await machine.release()
        except Exception:
            pass

        if not await wait_for_status(client, machine.system_id, "ready"):
            log("[ERROR] Machine did not reach Ready state after forced release.", log_file)
            return

        machine = await refresh_machine(client, machine)

    # Ensure owner tag is applied (only once here)
    if not await assign_owner_tag(client, machine, DEFAULT_OWNER, log_file):
        return

    # choose OS
    current_os = getattr(machine, "distro_series", None)
    if os_release:
        os_to_use = os_release
    elif current_os:
        os_to_use = current_os
    else:
        log(f"[ERROR] No OS detected for machine '{hostname}'. Provide --os.", log_file)
        return

    # if deployed -> release then wait for Ready
    status = get_normalized_status(machine)
    if status == "deployed":
        log(f"[ACTION] Releasing {machine.hostname} for reimage...", log_file)
        if not await release_machine(client, machine, log_file):
            return
        if not await wait_for_status(client, machine.system_id, "ready"):
            log("[ERROR] Machine did not reach Ready state after release.", log_file)
            return
        machine = await refresh_machine(client, machine)

    # trigger deploy (deploy_machine will not re-assign tag)
    if await deploy_machine(client, hostname, os_to_use, log_file):
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log(f"[SUCCESS] Reimage completed for {hostname}.", log_file)
        log(f"[INFO] Reimage timestamp for {hostname}: {ts} IST", log_file)

# -------------------------------------------------------------------------
# Reimage all machines
# -------------------------------------------------------------------------

async def reimage_all(client, os_release=None, log_file=None):
    try:
        machines = await get_cached_machines(client)
    except Exception as e:
        log(f"[ERROR] Unable to fetch machines list: {e}", log_file)
        return

    for m in machines:
        hostname = m.hostname
        target_os = os_release or getattr(m, "distro_series", "focal")
        log(f"[INFO] Starting reimage for {hostname}", log_file)
        try:
            await reimage_machine(client, hostname, target_os, log_file)
        except Exception as e:
            log(f"[ERROR] Reimage error for {hostname}: {e}", log_file)

# -------------------------------------------------------------------------
# Find last deployed
# -------------------------------------------------------------------------

async def find_last_deployed_machine(client):
    try:
        machines = await get_cached_machines(client)
    except Exception:
        return None

    time_fields = [
        "deployed_at", "deployment_finished_at", "deployment_completed",
        "deployment_started", "deployment_started_at"
    ]

    candidates = []
    for m in machines:
        status = get_normalized_status(m)
        if status != "deployed":
            continue

        timestamp = None
        for field in time_fields:
            val = getattr(m, field, None)
            if val:
                try:
                    if isinstance(val, str):
                        val = val.replace("Z", "+00:00")
                        timestamp = datetime.fromisoformat(val)
                    elif isinstance(val, datetime):
                        timestamp = val
                except Exception:
                    continue
        if timestamp:
            candidates.append((timestamp, m))

    if candidates:
        candidates.sort(key=lambda x: x[0], reverse=True)
        return candidates[0][1]

    for m in machines:
        if get_normalized_status(m) == "deployed":
            return m

    return None

# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------

async def main():
    global args
    global DEFAULT_OWNER

    parser = argparse.ArgumentParser(description="MAAS Reimage Automation Script")
    parser.add_argument("--action", required=True,
                        choices=[
                            "list", "list-distros", "query", "status",
                            "deploy", "reimage", "reimage-all", "last-deployed"
                        ])
    parser.add_argument("--machine", help="Hostname for query, deploy, or reimage")
    parser.add_argument("--os", help="Target OS release")
    parser.add_argument("--log-file", help="Path to log file")
    parser.add_argument("--force", action="store_true",
                        help="Force reimage even if machine is deploying")
    parser.add_argument("--owner", help="Owner username (fallback: DEFAULT_OWNER)")

    args = parser.parse_args()

    if args.owner:
        DEFAULT_OWNER = args.owner

    maas_url = load_config()
    api_key = load_api_key()

    client = await connect_maas(maas_url, api_key)

    # initialize cache immediately
    try:
        client._machines_cache = await client.machines.list()
    except Exception:
        client._machines_cache = None

    log_file = args.log_file or LOG_FILE_DEFAULT

    if args.action == "list":
        await list_machines(client, log_file)

    elif args.action == "query":
        if not args.machine:
            print("Missing --machine")
        else:
            await query_machine(client, args.machine, log_file)

    elif args.action == "status":
        if not args.machine:
            print("Missing --machine")
        else:
            await query_machine(client, args.machine, log_file)

    elif args.action == "list-distros":
        await list_distros(client, log_file)

    elif args.action == "deploy":
        if not args.machine:
            print("Missing --machine")
        else:
            # ensure owner tag when user runs deploy directly
            # fetch machine object (no extra printed details)
            machines = await get_cached_machines(client)
            found = next((m for m in machines if m.hostname == args.machine), None)
            if not found:
                log(f"[ERROR] Machine '{args.machine}' not found.", log_file)
            else:
                machine_obj = await client.machines.get(system_id=found.system_id)
                await assign_owner_tag(client, machine_obj, DEFAULT_OWNER, log_file)
                await deploy_machine(client, args.machine, args.os, log_file)

    elif args.action == "reimage":
        if not args.machine:
            print("Missing --machine")
        else:
            await reimage_machine(client, args.machine, args.os, log_file)

    elif args.action == "reimage-all":
        await reimage_all(client, args.os, log_file)

    elif args.action == "last-deployed":
        machine = await find_last_deployed_machine(client)
        if machine:
            log(f"Last deployed machine: {machine.hostname} ({machine.system_id})", log_file)
        else:
            log("No deployed machines found.", log_file)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Interrupted by user.")
    except Exception as e:
        print(f"Fatal error: {e}")
