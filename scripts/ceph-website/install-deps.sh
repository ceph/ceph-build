#!/bin/bash
set -x

# install nvm
if [[ ! $(command -v nvm) ]]; then
    # install nvm
    LATEST_NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r '.tag_name')
    echo "Installing nvm version ${LATEST_NVM_VERSION}"

    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${LATEST_NVM_VERSION}/install.sh | bash

    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
fi

echo "Installing nodejs from nvm with version $(cat .nvmrc)"
nvm install
nvm use
