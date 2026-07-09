#!/bin/bash -ex

echo "Setting up Pulp client"
if [ -z "$PULP_SERVER_URL" ] || [ -z "$PULP_USERNAME" ] || [ -z "$PULP_PASSWORD" ]; then
    echo "PULP_SERVER_URL, PULP_USERNAME, or PULP_PASSWORD is not set"
    exit 1
fi

export PATH="$HOME/.local/bin:$PATH"
source "$WORKSPACE/scripts/setup_uv.sh"

echo "Installing Pulp client"
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
