#!/usr/bin/env bash

set -ex

on_error() {
    if [ "$1" != "0" ]; then
        printf "\n\nERROR $1 thrown on line $2\n\n"
        printf "\n\nCollecting info...\n\n"
        sudo journalctl --since "10 min ago" --no-tail --no-pager -x
        printf "\n\nERROR: displaying containers' logs:\n\n"
        docker ps -aq | xargs docker logs
        printf "\n\nTEST FAILED.\n\n"
    fi
}

trap 'on_error $? $LINENO' ERR

# Install required deps.
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release \
    openssh-server software-properties-common

NODEJS_MAJOR_VERSION=12
DISTRO="$(lsb_release -cs)"
if [[ ! $(command -v node) || $(node --version | grep -oE "v([0-9])+" | cut -c 2-) < ${NODEJS_MAJOR_VERSION} ]]; then
    sudo add-apt-repository -y -r ppa:chris-lea/node.js
    sudo rm -f /etc/apt/sources.list.d/chris-lea-node_js-*.list
    sudo rm -f /etc/apt/sources.list.d/chris-lea-node_js-*.list.save

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
sudo apt install -y libvirt-daemon-system libvirt-daemon-driver-qemu qemu-kvm libvirt-clients

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
    ssh-keygen -t rsa -q -f "${KCLI_CONFIG_DIR}/id_rsa" -N ""
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

# KCLI cleanup function can be found here: https://github.com/ceph/ceph/blob/master/src/pybind/mgr/dashboard/ci/cephadm/start-cluster.sh
sudo mkdir -p /var/lib/libvirt/images/ceph-dashboard
kcli create pool -p /var/lib/libvirt/images/ceph-dashboard ceph-dashboard
kcli create network -c 192.168.100.0/24 ceph-dashboard
