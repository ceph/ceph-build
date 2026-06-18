#!/usr/bin/env python3

"""
Sync Jenkins node labels with jenkins_builders.yml

- Reads labels from inventory
- Resolves actual Jenkins node name (handles IP+hostname format)
- Fetches current labels from Jenkins
- Updates only if mismatch
"""

import yaml
import requests
import argparse
from urllib.parse import quote
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("--file", required=True)
parser.add_argument("--jenkins_url", required=True)
parser.add_argument("--user", required=True)
parser.add_argument("--token", required=True)
parser.add_argument("--node", required=True)

args = parser.parse_args()

# --- Normalize base URL ---
base_url = args.jenkins_url.rstrip('/')

# --- Read inventory ---
with open(args.file) as f:
    data = yaml.safe_load(f)

labels_map = data.get("jenkins_labels", {})
inventory_labels = labels_map.get(args.node, "").strip()

if not inventory_labels:
    print(f"[WARN] No labels found in inventory for {args.node}")
    exit(0)

# Normalize labels (sorted for consistent comparison)
inventory_labels = " ".join(sorted(inventory_labels.split()))

# --- Resolve Jenkins node name dynamically ---
short_name = args.node.split('.')[0]

api_url = f"{base_url}/computer/api/json"
r = requests.get(api_url, auth=(args.user, args.token))
r.raise_for_status()

nodes = r.json().get("computer", [])

node_name = None
for n in nodes:
    display_name = n.get("displayName", "")
    if short_name in display_name:
        node_name = display_name
        break

if not node_name:
    print(f"[WARN] No Jenkins node found for {short_name}; skipping label sync")
    exit(0)

# Encode node name (important for '+' → '%2B')
encoded_node = quote(node_name, safe='')

# --- Build config.xml URL ---
url = f"{base_url}/computer/{encoded_node}/config.xml"

print(f"[DEBUG] Matched Jenkins node: {node_name}")
print(f"[DEBUG] URL: {url}")

# --- Fetch Jenkins config.xml ---
r = requests.get(url, auth=(args.user, args.token))
r.raise_for_status()

xml_data = r.text

# Strip XML declaration if needed (handles XML 1.1 safely)
if xml_data.startswith("<?xml"):
    xml_data = xml_data.split("?>", 1)[1]

root = ET.fromstring(xml_data)

label_node = root.find("label")

if label_node is None:
    print(f"[ERROR] <label> tag not found for {node_name}")
    exit(1)

current_labels = label_node.text or ""
current_labels = " ".join(sorted(current_labels.split()))

# --- Compare ---
if current_labels == inventory_labels:
    print(f"[SYNC] {args.node}: labels already in sync")
    exit(0)

# --- Update labels ---
print(f"[SYNC] Updating {args.node}")
print(f"  OLD: {current_labels}")
print(f"  NEW: {inventory_labels}")

label_node.text = inventory_labels

updated_xml = ET.tostring(root, encoding="unicode")

# --- Push update ---
resp = requests.post(
    url,
    data=updated_xml,
    headers={"Content-Type": "application/xml"},
    auth=(args.user, args.token)
)

resp.raise_for_status()

print(f"[SYNC] {args.node} labels updated successfully")
