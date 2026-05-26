import yaml
import sys

inventory_file = sys.argv[1]
node_input = sys.argv[2]

# Normalize node name to FQDN if needed
if "." not in node_input:
    node_name = node_input + ".front.sepia.ceph.com"
else:
    node_name = node_input

with open(inventory_file) as f:
    data = yaml.safe_load(f)

labels_map = data.get("jenkins_labels", {})

labels_str = labels_map.get(node_name)

if not labels_str:
    print("ERROR: No labels found for node")
    sys.exit(1)

# Split space separated labels
labels = labels_str.split()

for label in labels:
    if label.startswith("installed-os-"):
        os_name = label.replace("installed-os-", "")
        print(os_name)
        sys.exit(0)

print("ERROR: installed-os label not found")
sys.exit(1)
