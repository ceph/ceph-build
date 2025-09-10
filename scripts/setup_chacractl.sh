#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab
"$WORKSPACE/scripts/setup_uv.sh"
PATH=$PATH:$HOME/.local/bin
uv tool install chacractl

chacra_url=$(curl -u "$SHAMAN_API_USER:$SHAMAN_API_KEY" https://shaman.ceph.com/api/nodes/next/)
cat > "$HOME/.chacractl" << EOF
url = "$chacra_url"
user = "$CHACRACTL_USER"
key = "$CHACRACTL_KEY"
ssl_verify = True
EOF
echo "$chacra_url"
