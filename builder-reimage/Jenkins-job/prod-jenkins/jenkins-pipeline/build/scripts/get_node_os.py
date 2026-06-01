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
