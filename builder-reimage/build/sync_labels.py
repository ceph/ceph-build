#!/usr/bin/env python3

"""
Sync Jenkins node labels with jenkins_builders.yml

- Reads labels from inventory
- Fetches current labels from Jenkins
- Updates only if mismatch
"""

import yaml
import requests
import argparse
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("--file", required=True)
parser.add_argument("--jenkins_url", required=True)
parser.add_argument("--user", required=True)
parser.add_argument("--token", required=True)
parser.add_argument("--node", required=True)

args = parser.parse_args()

# --- Read inventory ---
with open(args.file) as f:
    data = yaml.safe_load(f)

labels_map = data.get("jenkins_labels", {})
inventory_labels = labels_map.get(args.node, "").strip()

if not inventory_labels:
    print(f"[WARN] No labels found in inventory for {args.node}")
    exit(0)

# Normalize
inventory_labels = " ".join(sorted(inventory_labels.split()))

# --- Fetch Jenkins config ---
base_url = args.jenkins_url.rstrip('/')
node_name = args.node.split('.')[0]

url = f"{base_url}/computer/{node_name}/config.xml"

r = requests.get(url, auth=(args.user, args.token))
r.raise_for_status()

xml_data = r.text

root = ET.fromstring(xml_data)
label_node = root.find("label")

current_labels = label_node.text or ""
current_labels = " ".join(sorted(current_labels.split()))

# --- Compare ---
if current_labels == inventory_labels:
    print(f"[SYNC] {args.node}: labels already in sync")
    exit(0)

# --- Update ---
print(f"[SYNC] Updating {args.node}")
print(f"  OLD: {current_labels}")
print(f"  NEW: {inventory_labels}")

label_node.text = inventory_labels

updated_xml = ET.tostring(root, encoding="unicode")

resp = requests.post(
    url,
    data=updated_xml,
    headers={"Content-Type": "application/xml"},
    auth=(args.user, args.token)
)

resp.raise_for_status()

print(f"[SYNC] {args.node} labels updated successfully")
