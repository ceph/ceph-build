#!/bin/bash
set -ex

if [[ ! $(arch) =~ (i386|x86_64|amd64) ]]; then
    # google chrome is only available on amd64
    exit
fi

if grep -q  debian /etc/*-release; then
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

# kill any existing Xvfb process to avoid port conflict
sudo killall Xvfb || true
