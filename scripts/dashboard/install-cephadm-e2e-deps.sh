#!/usr/bin/env bash

set -ex

on_error() {
    if [ "$1" != "0" ]; then
        printf "\n\nERROR $1 thrown on line $2\n\n"
        printf "\n\nCollecting info...\n\n"
        sudo journalctl --since "10 min ago" --no-tail --no-pager -x
        printf "\n\nERROR: displaying podman logs:\n\n"
        podman logs -l
        printf "\n\nTEST FAILED.\n\n"
    fi
}

trap 'on_error $? $LINENO' ERR

sudo apt -y install libvirt-daemon-system libvirt-daemon-driver-qemu qemu-kvm libvirt-clients

sudo usermod -aG libvirt $(id -un)
newgrp libvirt  # Avoid having to log out and log in for group addition to take effect.
sudo systemctl enable --now libvirtd

# Add podman repo for ubuntu focal.
VERSION_ID='20.04'
sudo sh -c "echo 'deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /' > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list"
wget -nv https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable/xUbuntu_${VERSION_ID}/Release.key -O- | sudo apt-key add -
sudo apt update -y

# Install required deps.
sudo apt install -y nodejs npm openssh-server podman

KCLI_CONFIG_DIR="${HOME}/.kcli"
mkdir -p ${KCLI_CONFIG_DIR}
if [[ ! -f "${KCLI_CONFIG_DIR}/id_rsa" ]]; then
    ssh-keygen -t rsa -q -f "${KCLI_CONFIG_DIR}/id_rsa" -N ""
fi

: ${KCLI_CONTAINER_IMAGE:='docker.io/jolmomar/kcli'}

echo "#!/usr/bin/env bash

sudo podman run --net host --security-opt label=disable \
    -v ${KCLI_CONFIG_DIR}:/root/.kcli \
    -v ${PWD}:/workdir \
    -v /var/lib/libvirt/images:/var/lib/libvirt/images \
    -v /var/run/libvirt:/var/run/libvirt \
    -v /var/tmp:/ignitiondir \
    ${KCLI_CONTAINER_IMAGE} \""'${@}'"\"
" | sudo tee /usr/local/bin/kcli
sudo chmod +x /usr/local/bin/kcli

podman info
sudo podman container prune -f

kcli create pool -p /var/lib/libvirt/images default
kcli download image fedora34 -u https://fedora.mirror.liteserver.nl/linux/releases/34/Cloud/x86_64/images/Fedora-Cloud-Base-34-1.2.x86_64.qcow2
kcli create network -c 192.168.122.0/24 default
