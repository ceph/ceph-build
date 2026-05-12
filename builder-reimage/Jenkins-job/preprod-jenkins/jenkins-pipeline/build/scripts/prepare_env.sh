#!/usr/bin/env bash
set -euo pipefail

# prepare_env.sh
# Usage:
#   prepare_env.sh <target_fqdn> <work_dir> <ssh_available> <ansible_repo> <main_repo> <secrets_repo>
#
# Example:
#   prepare_env.sh irvingi04.front.sepia.ceph.com /var/lib/jenkins/ci-work true git@github.com:org/repo-ansible.git ...

TARGET_FQDN="$1"
WORK_DIR="$2"
SSH_AVAILABLE="${3:-false}"
MAIN_REPO="${4:-git@github.com:ceph/ceph-build.git}"  ## ceph-build
ANSIBLE_REPO="${5:-git@github.com:ceph/ceph-cm-ansible.git}" ## ceph-ci-ansible
SECRETS_REPO="${6:-git@github.com:ceph/ceph-sepia-secrets.git}" ## ceph-sepia-secrets

SHORTNAME="${TARGET_FQDN%%.*}"

REPOS_DIR="${WORK_DIR}/repos"
ANSIBLE_DIR="${REPOS_DIR}/ansible"
MAIN_DIR="${REPOS_DIR}/main"
SECRETS_DIR="${REPOS_DIR}/secret-repo"
VENV_DIR="${WORK_DIR}/.venv"

mkdir -p "${REPOS_DIR}"
cd "${REPOS_DIR}"

log() { echo "[prepare_env] $*"; }

adjust_url() {
  local url="$1"
  if [ "${SSH_AVAILABLE}" = "true" ]; then
    echo "${url}"
  else
    # convert git@github.com:org/repo.git -> https://github.com/org/repo.git
    echo "${url}" | sed 's|git@github.com:|https://github.com/|'
  fi
}

clone_repo() {
  local url="$1"
  local dir="$2"
  if [ -d "${dir}/.git" ]; then
    log "Updating existing repo ${dir}"
    (cd "${dir}" && git fetch --all --prune)
  else
    log "Cloning ${url} -> ${dir}"
    if [ "${SSH_AVAILABLE}" = "true" ] && [ -f /tmp/jenkins_git_key ]; then
      GIT_SSH_COMMAND='ssh -i /tmp/jenkins_git_key -o StrictHostKeyChecking=no' git clone --depth 1 "${url}" "${dir}"
    else
      git clone --depth 1 "${url}" "${dir}"
    fi
  fi
}

ANSIBLE_URL=$(adjust_url "${ANSIBLE_REPO}")
MAIN_URL=$(adjust_url "${MAIN_REPO}")
SECRETS_URL=$(adjust_url "${SECRETS_REPO}")

clone_repo "${ANSIBLE_URL}" "${ANSIBLE_DIR}"
clone_repo "${MAIN_URL}" "${MAIN_DIR}"
clone_repo "${SECRETS_URL}" "${SECRETS_DIR}"

# Ensure venv exists (created by Jenkinsfile in WORK_DIR). If not, create here.
if [ ! -d "${VENV_DIR}/bin" ]; then
  log "Virtualenv not found at ${VENV_DIR}, creating..."
  python3 -m venv "${VENV_DIR}"
  source "${VENV_DIR}/bin/activate"
  pip install --upgrade pip
  pip install -r "${ANSIBLE_DIR}/requirements.txt" 2>/dev/null || true
else
  source "${VENV_DIR}/bin/activate"
fi

# Check ansible installation in venv or system
if command -v ansible-playbook >/dev/null 2>&1; then
  log "Ansible already installed."
else
  log "Ansible not found, attempting to install into venv..."

  # Determine package manager depending on OS
  install_ansible_system() {
    if command -v apt-get >/dev/null 2>&1; then
      log "Detected apt-based system. Installing ansible..."
      sudo apt-get update && sudo apt-get install -y ansible || true

    elif command -v dnf >/dev/null 2>&1; then
      log "Detected dnf-based system (RHEL8+/Rocky/Alma). Installing ansible-core..."
      sudo dnf install -y ansible-core || sudo dnf install -y ansible || true

    elif command -v yum >/dev/null 2>&1; then
      log "Detected yum-based system (RHEL7/CentOS7). Installing ansible..."
      sudo yum install -y ansible || true

    else
      log "No supported package manager found. Cannot install ansible."
    fi
  }

  if [ -n "${VENV_DIR}" ] && [ -f "${VENV_DIR}/bin/activate" ]; then
    pip install ansible || {
      log "Failed to install ansible in venv; trying system install (requires sudo)"
      install_ansible_system
    }
  else
    log "No venv available; attempting system install (requires sudo)"
    install_ansible_system
  fi
fi

# Create idempotent symlinks for /etc/ansible/secrets and /etc/ansible/hosts
ensure_symlink() {
  local src="$1"
  local dst="$2"
  if [ -L "${dst}" ]; then
    log "Symlink ${dst} already exists"
    return 0
  fi
  if [ -e "${dst}" ]; then
    log "Target ${dst} exists and is not a symlink — leaving it untouched"
    return 0
  fi
  # ensure parent directory exists
  sudo mkdir -p "$(dirname "${dst}")"
  sudo ln -s "${src}" "${dst}"
  log "Created symlink ${dst} -> ${src}"
}

# Ensure /etc/ansible exists
sudo mkdir -p /etc/ansible || true

sudo rm -f /etc/ansible/secrets
ensure_symlink "${SECRETS_DIR}/ansible/secrets" "/etc/ansible/secrets"
sudo rm -f /etc/ansible/hosts
ensure_symlink "${SECRETS_DIR}/ansible/inventory" "/etc/ansible/hosts"

# Optional: Warn if target FQDN is not present in inventory file
if ! grep -q -E "^${TARGET_FQDN}\\b" /etc/ansible/hosts 2>/dev/null; then
  log "Warning: ${TARGET_FQDN} not found in /etc/ansible/hosts. Ensure dynamic inventory or update inventory."
fi

log "prepare_env completed for ${TARGET_FQDN} (shortname=${SHORTNAME})"
