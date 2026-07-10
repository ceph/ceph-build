#!/usr/bin/env bash
set -euo pipefail

# prepare_env.sh
# Usage:
#   prepare_env.sh <target_fqdn> <work_dir> <ssh_available> <main_repo> <ansible_repo> <secrets_repo> [ceph_build_branch]

TARGET_FQDN="$1"
WORK_DIR="$2"
SSH_AVAILABLE="${3:-false}"
MAIN_REPO="${4:-git@github.com:ceph/ceph-build.git}"
ANSIBLE_REPO="${5:-git@github.com:ceph/ceph-cm-ansible.git}"
SECRETS_REPO="${6:-git@github.com:ceph/ceph-sepia-secrets.git}"
CEPH_BUILD_BRANCH="${7:-main}"

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
    echo "${url}" | sed 's|git@github.com:|https://github.com/|'
  fi
}

# SSH access relies on the caller exporting GIT_SSH_COMMAND pointing at the
# deploy key (the Jenkinsfile does this before invoking us).
clone_repo() {
  local url="$1"
  local dir="$2"
  local branch="${3:-}"
  if [ -d "${dir}/.git" ]; then
    log "Updating existing repo ${dir}"
    (cd "${dir}" && git fetch --all --prune)
  else
    log "Cloning ${url}${branch:+ (branch ${branch})} -> ${dir}"
    git clone --depth 1 ${branch:+--branch "${branch}"} "${url}" "${dir}"
  fi
}

ANSIBLE_URL=$(adjust_url "${ANSIBLE_REPO}")
MAIN_URL=$(adjust_url "${MAIN_REPO}")
SECRETS_URL=$(adjust_url "${SECRETS_REPO}")

clone_repo "${ANSIBLE_URL}" "${ANSIBLE_DIR}"
clone_repo "${MAIN_URL}" "${MAIN_DIR}" "${CEPH_BUILD_BRANCH}"
clone_repo "${SECRETS_URL}" "${SECRETS_DIR}"

# Ensure venv exists
if [ ! -d "${VENV_DIR}/bin" ]; then
  log "Virtualenv not found at ${VENV_DIR}, creating..."
  python3 -m venv "${VENV_DIR}"
  source "${VENV_DIR}/bin/activate"
  pip install --upgrade pip
  pip install -r "${ANSIBLE_DIR}/requirements.txt" 2>/dev/null || true
else
  source "${VENV_DIR}/bin/activate"
fi

# Check ansible installation
if command -v ansible-playbook >/dev/null 2>&1; then
  log "Ansible already installed."
else
  log "Ansible not found, attempting to install into venv..."

  install_ansible_system() {
    if command -v apt-get >/dev/null 2>&1; then
      log "Detected apt-based system. Installing ansible..."
      sudo apt-get update && sudo apt-get install -y ansible || true

    elif command -v dnf >/dev/null 2>&1; then
      log "Detected dnf-based system. Installing ansible-core..."
      sudo dnf install -y ansible-core || sudo dnf install -y ansible || true

    elif command -v yum >/dev/null 2>&1; then
      log "Detected yum-based system. Installing ansible..."
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

# -------------------------------------------------------------------
# NEW: Workspace-local ansible configuration (replaces /etc/ansible)
# -------------------------------------------------------------------

INVENTORY_PATH="${SECRETS_DIR}/ansible/inventory"
SECRETS_PATH="${SECRETS_DIR}/ansible/secrets"
ANSIBLE_CFG="${WORK_DIR}/ansible.cfg"

# Validate inventory presence
if [ ! -e "${INVENTORY_PATH}" ]; then
  log "ERROR: Inventory not found at ${INVENTORY_PATH}"
  exit 1
fi

# Create ansible.cfg in workspace
cat > "${ANSIBLE_CFG}" <<EOF
[defaults]
inventory = ${INVENTORY_PATH}
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
interpreter_python = auto
roles_path = ${ANSIBLE_DIR}/roles
EOF

export ANSIBLE_CONFIG="${ANSIBLE_CFG}"
export INVENTORY_PATH
export SECRETS_PATH
export ANSIBLE_SECRETS_PATH="${SECRETS_PATH}"

log "Using ANSIBLE_CONFIG=${ANSIBLE_CONFIG}"
log "Inventory path: ${INVENTORY_PATH}"
log "Secrets path: ${SECRETS_PATH}"

# Optional: Warn if target not present in inventory
if ! grep -R -q -E "^${TARGET_FQDN}\\b" "${INVENTORY_PATH}" 2>/dev/null; then
  log "Warning: ${TARGET_FQDN} not found in inventory. Ensure dynamic inventory or update inventory."
fi

log "prepare_env completed for ${TARGET_FQDN} (shortname=${SHORTNAME})"
