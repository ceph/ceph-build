#!/usr/bin/env bash

set -ex

on_error() {
    if [ "$1" != "0" ]; then
        printf "\n\nERROR $1 thrown on line $2\n\n"
        printf "\n\nCollecting info...\n\n"
        sudo journalctl --since "10 min ago" --no-tail --no-pager -x
        printf "\n\nERROR: displaying containers' logs:\n\n"
        docker ps -aq | xargs -r docker logs
        printf "\n\nTEST FAILED.\n\n"
    fi
}

trap 'on_error $? $LINENO' ERR

# Install required deps.
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release \
    openssh-server software-properties-common

# install nvm
if [[ ! $(command -v nvm) ]]; then
    LATEST_NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r '.tag_name')
    echo "Installing nvm version ${LATEST_NVM_VERSION}"

    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${LATEST_NVM_VERSION}/install.sh | bash

    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
fi

pushd src/pybind/mgr/dashboard/frontend

echo "Installing nodejs from nvm with version $(cat .nvmrc)"
nvm install
nvm use
popd

sudo apt install -y libvirt-daemon-system libvirt-daemon-driver-qemu qemu-kvm libvirt-clients

sudo usermod -aG libvirt $(id -un)
newgrp libvirt  # Avoid having to log out and log in for group addition to take effect.
sudo systemctl enable --now libvirtd

if dpkg -l | grep -qE '^ii\s+docker-ce'; then
    echo "Cleaning up old docker installation..."
    sudo systemctl stop docker docker.socket containerd || true
    sudo apt remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
    sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    sudo apt autoremove -y
    sudo apt update -y
fi

if [[ $(command -v podman) == '' ]]; then
    sudo apt install -y podman
fi

podman info
podman container prune -f

KCLI_CONFIG_DIR="${HOME}/.kcli"
mkdir -p ${KCLI_CONFIG_DIR}
if [[ ! -f "${KCLI_CONFIG_DIR}/id_rsa" ]]; then
    sudo ssh-keygen -t rsa -q -f "${KCLI_CONFIG_DIR}/id_rsa" -N "" <<< y
fi

: ${KCLI_CONTAINER_IMAGE:='quay.io/karmab/kcli:2543a61'}

podman pull ${KCLI_CONTAINER_IMAGE}

echo "#!/usr/bin/env bash

podman run --rm --net host --security-opt label=disable \
    -v ${KCLI_CONFIG_DIR}:/root/.kcli \
    -v ${PWD}:/workdir \
    -v /var/lib/libvirt/images:/var/lib/libvirt/images \
    -v /var/run/libvirt:/var/run/libvirt \
    -v /var/tmp:/ignitiondir \
    ${KCLI_CONTAINER_IMAGE} \""'${@}'"\"
" | sudo tee /usr/local/bin/kcli
sudo chmod +x /usr/local/bin/kcli

# KCLI cleanup function can be found here: https://github.com/ceph/ceph/blob/main/src/pybind/mgr/dashboard/ci/cephadm/start-cluster.sh
sudo mkdir -p /var/lib/libvirt/images/ceph-dashboard
kcli delete plan ceph -y || true
kcli delete network ceph-dashboard -y
kcli create pool -p /var/lib/libvirt/images/ceph-dashboard ceph-dashboard
kcli create network -c 192.168.100.0/24 ceph-dashboard
