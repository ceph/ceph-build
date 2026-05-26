import yaml
import requests
import argparse
import re

parser = argparse.ArgumentParser()
parser.add_argument("--file", required=True)
parser.add_argument("--jenkins_url", required=True)
parser.add_argument("--user", required=True)
parser.add_argument("--token", required=True)
args = parser.parse_args()

with open(args.file) as f:
    data = yaml.safe_load(f)

def update_node(node, labels):
    url = f"{args.jenkins_url}/computer/{node}/config.xml"

    r = requests.get(url, auth=(args.user, args.token))
    config = r.text

    new_label = " ".join(labels)

    updated = re.sub(
        r"<label>.*?</label>",
        f"<label>{new_label}</label>",
        config
    )

    requests.post(
        url,
        data=updated,
        headers={"Content-Type": "application/xml"},
        auth=(args.user, args.token)
    )

    print(f"Updated {node}: {new_label}")


for node, labels in data.get("jenkins_builder_labels", {}).items():
    update_node(node, labels)
