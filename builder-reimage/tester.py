#!/usr/bin/env python3
import asyncio
from maas.client import connect


MAAS_URL = "http://sepia-maas.front.sepia.ceph.com:5240/MAAS"
API_KEY  = "xVHTt7i4DaFKQB9NSF:x1wybSshyACdPWFbgd:AKrF3dz8GAmONo7OOAjVN5nVW1vtZiFz"

MACHINE_NAME = "irvingi08"             # <<< MACHINE TO TEST
TEST_OWNER   = "jitendra"              # <<< TAG NAME TO TEST


async def debug_tag_test():
    print("\nConnecting to MAAS...")
    client = await connect(MAAS_URL, apikey=API_KEY)

    print("\nFetching machines...")
    machines = await client.machines.list()

    machine = next((m for m in machines if m.hostname == MACHINE_NAME), None)
    if not machine:
        print(f"ERROR: Machine '{MACHINE_NAME}' not found.")
        return

    print(f"\nMachine found: {machine.hostname} ({machine.system_id})")

    # --------------------------
    # SHOW EXISTING TAGS
    # --------------------------
    print("\n=== BEFORE TAGGING ===")
    print("machine.tags =", machine.tags)

    print("\nclient.tags.list():")
    tags = await client.tags.list()
    for t in tags:
        print(" -", t, " name=", getattr(t, "name", None))

    # --------------------------
    # APPLY OWNER TAG
    # --------------------------
    sanitized = TEST_OWNER.replace(" ", "_").replace("@", "_")
    print(f"\nSanitized tag name = '{sanitized}'")

    # Create tag if missing
    if not any(getattr(t, "name", "") == sanitized for t in tags):
        print(f"Creating new tag '{sanitized}'...")
        await client.tags.create(name=sanitized)
    else:
        print(f"Tag '{sanitized}' already exists.")

    # Assign the tag
    tag_obj = await client.tags.get(name=sanitized)
    print(f"Assigning tag '{sanitized}' to machine '{machine.hostname}'...")
    await machine.tags.add(tag_obj)

    # Refresh machine
    print("Refreshing machine after tagging...")
    await machine.refresh()

    # --------------------------
    # SHOW UPDATED TAGS
    # --------------------------
    print("\n=== AFTER TAGGING ===")
    print("machine.tags =", machine.tags)

    tags = await client.tags.list()
    print("\nclient.tags.list():")
    for t in tags:
        print(" -", t, " name=", getattr(t, "name", None))

    print("\n=== DONE ===")


if __name__ == "__main__":
    asyncio.run(debug_tag_test())

