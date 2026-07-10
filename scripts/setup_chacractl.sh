#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab
"$WORKSPACE/scripts/setup_uv.sh"
~/.local/bin/uv tool install chacractl

if [ -z "$chacra_url" ]; then
  # -f: shaman answers 404 ("no healthy chacra nodes available") when it has
  # no node to allocate; fail here instead of writing the HTML error page
  # into ~/.chacractl.
  chacra_url=$(curl -fs -u "$SHAMAN_API_USER:$SHAMAN_API_KEY" https://shaman.ceph.com/api/nodes/next/)
fi
cat > $HOME/.chacractl << EOF
url = "$chacra_url"
user = "$CHACRACTL_USER"
key = "$CHACRACTL_KEY"
ssl_verify = True
EOF
echo $chacra_url
