#!/bin/bash
set -ex

if [[ ! $(arch) =~ (i386|x86_64|amd64) ]]; then
    # google chrome is only available on amd64
    exit
fi

if grep -q  debian /etc/*-release; then
    NODEJS_MAJOR_VERSION=14
    DISTRO="$(lsb_release -cs)"
    if [[ ! $(command -v node) || $(node --version | grep -oE "v([0-9])+" | cut -c 2-) < ${NODEJS_MAJOR_VERSION} ]]; then
        sudo apt-get purge nodejs -y
        sudo dpkg --remove --force-remove-reinstreq libnode-dev
        sudo dpkg --remove --force-remove-reinstreq libnode72:amd64

        NODEJS_KEYRING=/usr/share/keyrings/nodesource.gpg
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource.gpg.key | gpg --dearmor | sudo tee "${NODEJS_KEYRING}" >/dev/null
        gpg --no-default-keyring --keyring "${NODEJS_KEYRING}" --list-keys

        NODEJS_VERSION="node_${NODEJS_MAJOR_VERSION}.x"
        echo "deb [signed-by=${NODEJS_KEYRING}] https://deb.nodesource.com/${NODEJS_VERSION} ${DISTRO} main" | sudo tee /etc/apt/sources.list.d/nodesource.list
        echo "deb-src [signed-by=${NODEJS_KEYRING}] https://deb.nodesource.com/${NODEJS_VERSION} ${DISTRO} main" | sudo tee -a /etc/apt/sources.list.d/nodesource.list

        sudo apt update -y
        sudo apt install -y nodejs
        sudo rm -f /etc/apt/sources.list.d/nodesource.list
    fi
    sudo bash -c 'echo "deb [arch=amd64] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list'
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo apt-key add -
    sudo apt-get update
    sudo apt-get install -y google-chrome-stable
    sudo apt-get install -y python3-requests python3-openssl python3-jinja2 \
        python3-jwt python3-scipy python3-routes
    sudo apt-get install -y xvfb libxss1
    sudo rm /etc/apt/sources.list.d/google-chrome.list
elif grep -q rhel /etc/*-release; then
    sudo dd of=/etc/yum.repos.d/google-chrome.repo status=none <<EOF
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://dl-ssl.google.com/linux/linux_signing_key.pub
EOF
    sudo yum install -y google-chrome-stable
    sudo rm /etc/yum.repos.d/google-chrome.repo
    sudo yum install -y python-requests pyOpenSSL python-jinja2 python-jwt scipy python-routes python3-routes
    sudo yum install -y xorg-x11-server-Xvfb.x86_64
fi
