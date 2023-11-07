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
    sudo systemctl start docker
    sudo chgrp "$(id -un)" /var/run/docker.sock

    docker info
    docker container prune -f
}

configure_libvirt(){
    sudo usermod -aG libvirt $(id -un)
    sudo su -l $USER  # Avoid having to log out and log in for group addition to take effect.
    sudo systemctl enable --now libvirtd
    sudo systemctl restart libvirtd
    sleep 10 # wait some time for libvirtd service to restart
}

# install dependencies
sudo apt update -y
sudo apt install -y qemu-kvm libvirt-daemon-driver-qemu libvirt-clients libvirt-daemon-system  runc python3
sudo apt install -y python3-pip
pip3 install behave
configure_libvirt
install_docker

# install minikube
curl -LO https://storage.googleapis.com/minikube/releases/v1.31.2/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
