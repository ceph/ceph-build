#!/usr/bin/env python3

"""
get_node_os.py

Description:
------------
This script reads the Jenkins builders inventory file and extracts:
  - The target operating system from the "installed-os-*" label
  - Whether the "libvirt" label is present

It returns the result in the format:
  <os_name>,<libvirt_flag>

Where:
  os_name        -> e.g. jammy, centos9
  libvirt_flag   -> "true" or "false"

This output is consumed by the Jenkins pipeline to:
  - determine which OS to use for MaaS reimage
  - optionally enable libvirt-specific configuration in Ansible

Usage:
------
  get_node_os.py <inventory_file> <node_name>
"""

import yaml
import sys

inventory_file = sys.argv[1]
node_input = sys.argv[2]

node_name = node_input if "." in node_input else node_input + ".front.sepia.ceph.com"

with open(inventory_file) as f:
    data = yaml.safe_load(f)

labels_map = data.get("jenkins_labels", {})
labels_str = labels_map.get(node_name, "")

labels = labels_str.split()

os_name = ""
libvirt = "false"

for label in labels:
    if label.startswith("installed-os-"):
        os_name = label.replace("installed-os-", "")
    if label == "libvirt":
        libvirt = "true"

# Print both values in structured way
print(f"{os_name},{libvirt}")
