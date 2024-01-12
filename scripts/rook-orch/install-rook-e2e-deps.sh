#!/usr/bin/env bash

set -ex

install_docker(){
    DISTRO="$(lsb_release -cs)"
    if [[ $(command -v docker) == '' ]]; then
	# Set up docker official repo and install docker.
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
	echo \
            "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        ${DISTRO} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
	sudo apt update -y
	sudo apt install -y docker-ce docker-ce-cli containerd.io
    fi
    sudo groupadd docker || true
    sudo usermod -aG docker $(id -un)
    sudo systemctl unmask docker
    sudo systemctl start docker
    sudo chgrp "$(id -un)" /var/run/docker.sock

    docker info
    docker container prune -f
}

# delete any existing minikube setup
minikube delete

# delete any existing libvirt socket
sudo rm -rf /var/run/libvirt/libvirt-sock

# install dependencies
sudo apt update -y
sudo apt install --reinstall -y qemu-kvm libvirt-daemon-driver-qemu libvirt-clients libvirt-daemon-system  runc python3
sudo apt install --reinstall -y python3-pip
python -m pip install behave
install_docker

# install minikube
curl -LO https://storage.googleapis.com/minikube/releases/v1.31.2/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
