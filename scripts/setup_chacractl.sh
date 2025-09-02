#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab
command -v pipx || (
  command -v apt && sudo apt install -y pipx
  command -v dnf && sudo dnf install -y pipx
)
pipx ensurepath
pipx install uv
~/.local/bin/uv tool install chacractl

if [ -z "$chacra_url" ]; then
  chacra_url=$(curl -u "$SHAMAN_API_USER:$SHAMAN_API_KEY" https://shaman.ceph.com/api/nodes/next/)
fi
cat > $HOME/.chacractl << EOF
url = "$chacra_url"
user = "$CHACRACTL_USER"
key = "$CHACRACTL_KEY"
ssl_verify = True
EOF
echo $chacra_url
