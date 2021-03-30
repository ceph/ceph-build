#!/bin/bash
set -ex

if grep -q  debian /etc/*-release; then
    sudo apt-get install -y python3-scipy python3-routes
elif grep -q rhel /etc/*-release; then
    sudo yum install -y scipy python-routes python3-routes
fi
