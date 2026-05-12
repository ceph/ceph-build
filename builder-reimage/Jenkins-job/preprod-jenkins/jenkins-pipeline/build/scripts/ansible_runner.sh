#!/usr/bin/env bash
set -euo pipefail

# ansible_runner.sh
#
# Usage:
#   ansible_runner.sh <target_fqdn> <work_dir> <venv_dir> <os> <builder_token>

TARGET_FQDN="$1"
WORK_DIR="$2"
VENV_DIR="$3"
OS_VALUE="${4,,}"        # normalize OS → lowercase (can be empty)
BUILDER_TOKEN="$5"

ANSIBLE_DIR="${WORK_DIR}/repos/ansible"
MAIN_DIR="${WORK_DIR}/repos/main"
LOG_DIR="${WORK_DIR}/ansible-logs"

# Vault now ALWAYS comes from this file (created by Jenkinsfile)
VAULT_FILE="/home/jenkins-build/.vault_pass.txt"
VAULT_ARG="--vault-password-file=${VAULT_FILE}"

mkdir -p "${LOG_DIR}"

##############################################
# Activate virtualenv if present
##############################################
if [[ -f "${WORK_DIR}/${VENV_DIR}/bin/activate" ]]; then
    echo "[ansible_runner] Activating venv: ${WORK_DIR}/${VENV_DIR}"
    # shellcheck disable=SC1090
    source "${WORK_DIR}/${VENV_DIR}/bin/activate"
else
    echo "[ansible_runner] WARNING: venv not found at ${WORK_DIR}/${VENV_DIR}. Continuing without venv."
fi

##############################################
# Determine SSH user based on OS
##############################################
if [[ "$OS_VALUE" =~ (rhel|centos|rocky|almai|9-stream|rhel10|centos70|8) ]]; then
    SSH_USER="cloud-user"
else
    SSH_USER="ubuntu"
fi

echo "[ansible_runner] SSH user selected = ${SSH_USER}"

##############################################
# Admin user JSON builder
##############################################
ADMIN_USERS=(
  "akraitma"
  "dgalloway"
  "dmick"
  "falcocer"
  "jitendra"
  "zack"
)

build_admin_users_json() {
    local json='{"managed_admin_users":['
    for u in "${ADMIN_USERS[@]}"; do
        json+="{\"name\":\"${u}\"},"
    done
    json="${json%,}]}"
    echo "${json}"
}

##############################################
# Playbook runner with retries (3 attempts)
##############################################
run_playbook() {
    local pb_name="$1"
    local cmd="$2"
    local logfile="${LOG_DIR}/${TARGET_FQDN}-${pb_name}.log"

    echo "[ansible_runner] Running ${pb_name} -> ${logfile}"

    attempts=0
    max_attempts=3

    until [[ $attempts -ge $max_attempts ]]; do
        attempts=$((attempts + 1))

        eval "${cmd}" 2>&1 | tee "${logfile}"
        rc=${PIPESTATUS[0]}

        if [[ $rc -eq 0 ]]; then
            echo "[ansible_runner] ${pb_name} succeeded on attempt ${attempts}"
            return
        fi

        echo "[ansible_runner] ${pb_name} failed (rc=${rc}), attempt ${attempts}/${max_attempts}"

        if [[ $attempts -lt $max_attempts ]]; then
            sleep $((attempts * 10))
        else
            echo "[ansible_runner] Max attempts reached for ${pb_name}; failing"
            exit "${rc}"
        fi
    done
}

##############################################
# PLAYBOOK 1 — ansible_managed.yml
# (NO VAULT)
##############################################
(
  cd "${ANSIBLE_DIR}"

  CMD="ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' ansible-playbook ansible_managed.yml \
        --limit='${TARGET_FQDN}' \
        -e ansible_ssh_user='${SSH_USER}'"

  run_playbook "play1-ansible_managed" "${CMD}"
)

##############################################
# PLAYBOOK 2 — users.yml
# (NO VAULT)
##############################################
(
  cd "${ANSIBLE_DIR}"

  ADMIN_USERS_JSON="$(build_admin_users_json)"

  CMD="ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' ansible-playbook users.yml -v \
        --limit='${TARGET_FQDN}' \
        --tags='user,pubkeys' \
        --ssh-extra-args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
        --extra-vars='${ADMIN_USERS_JSON}'"

  run_playbook "play2-users" "${CMD}"
)

##############################################
# PLAYBOOK 3 — jenkins-builder-disk.yml
# (NO VAULT)
##############################################
(
  cd "${ANSIBLE_DIR}"

  CMD="ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' ansible-playbook -vvv tools/jenkins-builder-disk.yml \
        --ssh-extra-args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \ 
        --limit='${TARGET_FQDN}'"

  run_playbook "play3-tools-disk" "${CMD}"
)

##############################################
# PLAYBOOK 4 — builder.yml
# (USES VAULT)
##############################################
(
  cd "${MAIN_DIR}/ansible"

  CMD="ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' ansible-playbook -vvv \
        ${VAULT_ARG} \
        -M ./library/ \
        examples/builder.yml \
        -e '{\"token\":\"${BUILDER_TOKEN}\", \"jenkins_credentials_uuid\":\"jenkins-build\", \"api_uri\":\"https://jenkins.ceph.com\"}' \
        -e permanent=true \
        --ssh-extra-args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
        --limit='${TARGET_FQDN}'"

  run_playbook "play4-main-builder" "${CMD}"
)

echo "[ansible_runner] All playbooks completed successfully for ${TARGET_FQDN}"
