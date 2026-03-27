#!/usr/bin/env bash

set -ex

# install dependencies
sudo apt update -y
sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y qemu-kvm libvirt-daemon-driver-qemu libvirt-clients libvirt-daemon-system libvirt-daemon runc python3
sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y python3-pip

# install minikube
curl -LO https://storage.googleapis.com/minikube/releases/v1.31.2/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# delete any existing minikube setup
minikube delete
