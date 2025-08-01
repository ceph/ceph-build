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

sudo apt install -y libvirt-daemon-system libvirt-daemon-driver-qemu qemu-kvm libvirt-clients runc

sudo usermod -aG libvirt $(id -un)
newgrp libvirt  # Avoid having to log out and log in for group addition to take effect.
sudo systemctl enable --now libvirtd

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

KCLI_CONFIG_DIR="${HOME}/.kcli"
mkdir -p ${KCLI_CONFIG_DIR}
if [[ ! -f "${KCLI_CONFIG_DIR}/id_rsa" ]]; then
    sudo ssh-keygen -t rsa -q -f "${KCLI_CONFIG_DIR}/id_rsa" -N "" <<< y
fi

: ${KCLI_CONTAINER_IMAGE:='quay.io/karmab/kcli:2543a61'}

docker pull ${KCLI_CONTAINER_IMAGE}

echo "#!/usr/bin/env bash

docker run --net host --security-opt label=disable \
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
