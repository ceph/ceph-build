#!/bin/bash -ex

echo "Setting up Pulp client"
source "$WORKSPACE/scripts/setup_uv.sh"

export PATH="$HOME/.local/bin:$PATH"

PULP_SERVER_URL="https://pulp.apps.pok.os.sepia.ceph.com"

uv tool install pulp-cli --with pulp-cli-deb

echo "Configuring Pulp client"
uv run pulp config create --base-url "${PULP_SERVER_URL}" \
    --username "${PULP_USERNAME}" --password "${PULP_PASSWORD}" \
    --no-verify-ssl --overwrite 

echo "Checking Pulp client status"
if ! uv run pulp status; then
    echo "Error: Pulp client is not configured correctly."
    exit 1
fi

echo "Pulp client setup complete"
