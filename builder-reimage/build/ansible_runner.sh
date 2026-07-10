#!/usr/bin/env bash
set -euo pipefail

# ansible_runner.sh
#
# Usage:
#   ansible_runner.sh <target_fqdn> <work_dir> <venv_dir> <os> <builder_token> <libvirt_flag>
#
#   libvirt_flag:
#       "true"  -> enable libvirt-specific configuration
#       "false" -> default behavior


# Use default Ansible output format
export ANSIBLE_STDOUT_CALLBACK=default

# Disable creation of retry files
export ANSIBLE_RETRY_FILES_ENABLED=False

# Fully qualified domain name of the target node
TARGET_FQDN="$1"

# Per-node workspace directory used for execution
WORK_DIR="$2"

# Virtual environment directory name
VENV_DIR="$3"

# Detected OS value (converted to lowercase)
OS_VALUE="${4,,}"

# Token used by builder playbook for authentication
BUILDER_TOKEN="$5"

# Libvirt flag passed from pipeline (normalized to true/false)
LIBVIRT=$(echo "${6:-false}" | tr '[:upper:]' '[:lower:]' | xargs)

# Debug logs for libvirt flag
echo "[ansible_runner][DEBUG] LIBVIRT raw value: '${6:-unset}'"
echo "[ansible_runner][DEBUG] LIBVIRT normalized: '${LIBVIRT}'"

# Path to Ansible repository (playbooks, roles)
ANSIBLE_DIR="${WORK_DIR}/repos/ansible"

# Path to main repository containing builder playbook
MAIN_DIR="${WORK_DIR}/repos/main"

# Path to store log files
LOG_DIR="${WORK_DIR}/ansible-logs"

# failure tracking
FAILED_PLAYBOOKS=()
FAILED_LOGS=()


# Ensure secrets path exists (independent of prepare_env.sh)

SECRETS_PATH="${WORK_DIR}/repos/secret-repo/ansible/secrets"

# Backward compatibility for playbook expecting this env var
export ANSIBLE_SECRETS_PATH="${ANSIBLE_SECRETS_PATH:-${SECRETS_PATH}}"

echo "[ansible_runner] ANSIBLE_SECRETS_PATH=${ANSIBLE_SECRETS_PATH}"


# consume paths exported by prepare_env.sh
INVENTORY_PATH="${INVENTORY_PATH:-${WORK_DIR}/repos/secret-repo/ansible/inventory}"
SECRETS_PATH="${SECRETS_PATH:-${WORK_DIR}/repos/secret-repo/ansible/secrets}"

# Vault comes from this file (created by Jenkinsfile)
VAULT_FILE="/home/jenkins-build/.vault_pass.txt"
VAULT_ARG="--vault-password-file=${VAULT_FILE}"

mkdir -p "${LOG_DIR}"

CONNECTIVITY_FAILED_FILE="${WORK_DIR}/ansible-connectivity-failed"
CONNECTIVITY_LOG="${LOG_DIR}/${TARGET_FQDN}-wait-online.log"

rm -f "${CONNECTIVITY_FAILED_FILE}"

# Activate virtualenv if present
if [[ -f "${WORK_DIR}/${VENV_DIR}/bin/activate" ]]; then
    echo "[ansible_runner] Activating venv: ${WORK_DIR}/${VENV_DIR}"
    # shellcheck disable=SC1090
    source "${WORK_DIR}/${VENV_DIR}/bin/activate"
else
    echo "[ansible_runner] WARNING: venv not found at ${WORK_DIR}/${VENV_DIR}. Continuing without venv."
fi

# Determine SSH user based on OS
if [[ "$OS_VALUE" =~ (rhel|centos|rocky|almai|9-stream|rhel10|centos70|8) ]]; then
    SSH_USER="cloud-user"
else
    SSH_USER="ubuntu"
fi

echo "[ansible_runner] SSH user selected = ${SSH_USER}"
echo "[ansible_runner] Using inventory = ${INVENTORY_PATH}"
echo "[ansible_runner] Using secrets = ${SECRETS_PATH}"

# Wait until the reimaged node is reachable by Ansible.
# MAAS may mark the node as deployed before SSH/cloud-init is fully ready.
# This prevents playbooks from starting too early and failing with connection errors.
wait_for_ansible_connectivity() {
    local attempts=0
    local max_attempts=40
    local interval=15

    echo "[ansible_runner] Waiting for SSH/Ansible connectivity on ${TARGET_FQDN}"

    until [[ $attempts -ge $max_attempts ]]; do
        attempts=$((attempts + 1))

        # Use Ansible ping to confirm SSH access and remote Python readiness.
        ANSIBLE_HOST_KEY_CHECKING=False ansible all \
            -i "${INVENTORY_PATH}" \
            --limit "${TARGET_FQDN}" \
            -m ping \
            -e "ansible_ssh_user=${SSH_USER}" \
            > "${CONNECTIVITY_LOG}" 2>&1

        rc=$?

        if [[ $rc -eq 0 ]]; then
            echo "[ansible_runner] ${TARGET_FQDN} is reachable by Ansible"
            return 0
        fi

        # Node is deployed but not ready yet, retry after a short wait.
        echo "[ansible_runner] ${TARGET_FQDN} not ready yet, attempt ${attempts}/${max_attempts}"
        tail -n 10 "${CONNECTIVITY_LOG}" || true

        sleep "${interval}"
    done

    # Fail clearly if the node never becomes reachable after deployment.
    echo "[ansible_runner] ERROR: ${TARGET_FQDN} did not become reachable by Ansible"
    echo "[ansible_runner] Last connectivity check output:"
    cat "${CONNECTIVITY_LOG}" || true

    touch "${CONNECTIVITY_FAILED_FILE}"
    return 1
}

# Admin user JSON builder
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

# Playbook runner with retries (3 attempts)
run_playbook() {
    local pb_name="$1"
    local cmd="$2"
    local logfile="${LOG_DIR}/${TARGET_FQDN}-${pb_name}.log"

    echo "[ansible_runner] Running ${pb_name} -> ${logfile}"

    attempts=0
    max_attempts=3

    until [[ $attempts -ge $max_attempts ]]; do
        attempts=$((attempts + 1))

        if eval "${cmd}" 2>&1 | tee "${logfile}"; then
            rc=0
        else
            rc=${PIPESTATUS[0]}
        fi

        if [[ $rc -eq 0 ]]; then
            echo "[ansible_runner] ${pb_name} succeeded on attempt ${attempts}"
            return 0
        fi

        echo "[ansible_runner] ${pb_name} failed (rc=${rc}), attempt ${attempts}/${max_attempts}"

        if [[ $attempts -lt $max_attempts ]]; then
            sleep $((attempts * 10))
        else
            echo "[ansible_runner] Max attempts reached for ${pb_name}"
            return 1
        fi
    done
}

# Ensure the node is actually reachable before running post-reimage playbooks.
if ! wait_for_ansible_connectivity; then
    FAILED_PLAYBOOKS+=("precheck-ansible-connectivity")
    FAILED_LOGS+=("${CONNECTIVITY_LOG}")
else

##############################################
# PLAYBOOK 1 — ansible_managed.yml
##############################################
if ! (
  cd "${ANSIBLE_DIR}"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook ansible_managed.yml \
        -i '${INVENTORY_PATH}' \
        --limit='${TARGET_FQDN}' \
        -e ansible_ssh_user='${SSH_USER}'"

  run_playbook "play1-ansible_managed" "${CMD}"
); then
    FAILED_PLAYBOOKS+=("play1-ansible_managed")
    FAILED_LOGS+=("${LOG_DIR}/${TARGET_FQDN}-play1-ansible_managed.log")
fi

##############################################
# PLAYBOOK 2 — users.yml
##############################################
if ! (
  cd "${ANSIBLE_DIR}"

  ADMIN_USERS_JSON="$(build_admin_users_json)"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook users.yml -v \
        -i '${INVENTORY_PATH}' \
        --limit='${TARGET_FQDN}' \
        --tags='user,pubkeys' \
        --extra-vars='${ADMIN_USERS_JSON}'"

  run_playbook "play2-users" "${CMD}"
); then
    FAILED_PLAYBOOKS+=("play2-users")
    FAILED_LOGS+=("${LOG_DIR}/${TARGET_FQDN}-play2-users.log")
fi

##############################################
# PLAYBOOK 3 — common.yml
##############################################
if ! (
  cd "${ANSIBLE_DIR}"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook common.yml \
        -i '${INVENTORY_PATH}' \
        --limit='${TARGET_FQDN}' \
        -e ansible_ssh_user='${SSH_USER}'"

  run_playbook "play3-common" "${CMD}"
); then
    FAILED_PLAYBOOKS+=("play3-common")
    FAILED_LOGS+=("${LOG_DIR}/${TARGET_FQDN}-play3-common.log")
fi

##############################################
# PLAYBOOK 4 — container-host.yml
##############################################
if ! (
  cd "${ANSIBLE_DIR}"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook container-host.yml \
        -i '${INVENTORY_PATH}' \
        --limit='${TARGET_FQDN}' \
        -e ansible_ssh_user='${SSH_USER}'"

  run_playbook "play4-container-host" "${CMD}"
); then
    FAILED_PLAYBOOKS+=("play4-container-host")
    FAILED_LOGS+=("${LOG_DIR}/${TARGET_FQDN}-play4-container-host.log")
fi

##############################################
# PLAYBOOK 5 — jenkins-builder-disk.yml
##############################################
if ! (
  cd "${ANSIBLE_DIR}"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook -v tools/jenkins-builder-disk.yml \
        -i '${INVENTORY_PATH}' \
        --limit='${TARGET_FQDN}'"

  run_playbook "play5-tools-disk" "${CMD}"
); then
    FAILED_PLAYBOOKS+=("play5-tools-disk")
    FAILED_LOGS+=("${LOG_DIR}/${TARGET_FQDN}-play5-tools-disk.log")
fi

##############################################
# PLAYBOOK 6 — builder.yml (USES VAULT)
##############################################
EXTRA_VARS=""

if [[ "${LIBVIRT}" == "true" ]]; then
    echo "[ansible_runner] libvirt detected for ${TARGET_FQDN}"
    EXTRA_VARS="-e libvirt=true"
fi

if ! (
  cd "${MAIN_DIR}/ansible"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook -v \
        -i '${INVENTORY_PATH}' \
        ${VAULT_ARG} \
        -M ./library/ \
        examples/builder.yml \
        -e '{\"token\":\"${BUILDER_TOKEN}\", \"jenkins_credentials_uuid\":\"jenkins-build\", \"api_uri\":\"https://jenkins.ceph.com\"}' \
        -e permanent=true \
        ${EXTRA_VARS} \
        --limit='${TARGET_FQDN}'"

  echo "[ansible_runner][DEBUG] EXTRA_VARS=${EXTRA_VARS}"
  echo "[ansible_runner][DEBUG] FINAL CMD=${CMD}"

  run_playbook "play6-main-builder" "${CMD}"
); then
    FAILED_PLAYBOOKS+=("play6-main-builder")
    FAILED_LOGS+=("${LOG_DIR}/${TARGET_FQDN}-play6-main-builder.log")
fi

fi

echo "========================================"
echo "[ansible_runner] FINAL EXECUTION SUMMARY"
echo "========================================"

if [[ ${#FAILED_PLAYBOOKS[@]} -eq 0 ]]; then
    echo "All playbooks completed successfully for ${TARGET_FQDN}"
    exit 0
fi

echo "Failed playbooks detected:"

for i in "${!FAILED_PLAYBOOKS[@]}"; do
    echo "----------------------------------------"
    echo "Playbook : ${FAILED_PLAYBOOKS[$i]}"
    echo "Log file : ${FAILED_LOGS[$i]}"
    echo "Extracting failure details..."

    # Extract Ansible failures
    grep -E "FAILED!|fatal:" "${FAILED_LOGS[$i]}" || echo "No detailed failure lines found"
done

echo "========================================"
echo "Build FAILED due to above errors"
echo "========================================"

exit 1
