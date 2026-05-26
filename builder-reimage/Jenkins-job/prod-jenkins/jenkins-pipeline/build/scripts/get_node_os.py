import yaml
import sys

inventory_file = sys.argv[1]
node_input = sys.argv[2]

# Always convert to FQDN
node_name = node_input if "." in node_input else node_input + ".front.sepia.ceph.com"

with open(inventory_file) as f:
    data = yaml.safe_load(f)

labels_map = data.get("jenkins_labels", {})

labels_str = labels_map.get(node_name)

if not labels_str:
    print("")
    sys.exit(0)

labels = labels_str.split()

for label in labels:
    if label.startswith("installed-os-"):
        print(label.replace("installed-os-", ""))
        sys.exit(0)

print("")
