import yaml
import sys

file = sys.argv[1]
node = sys.argv[2]

with open(file) as f:
    data = yaml.safe_load(f)

labels = data.get("jenkins_builder_labels", {}).get(node, [])

for l in labels:
    if l.startswith("installed-os-"):
        print(l.replace("installed-os-", ""))
        sys.exit(0)

print("ERROR: No installed-os-* label found")
sys.exit(1)
