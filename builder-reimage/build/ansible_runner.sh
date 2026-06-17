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

        eval "${cmd}" 2>&1 | tee "${logfile}"
        rc=${PIPESTATUS[0]}

        if [[ $rc -eq 0 ]]; then
            echo "[ansible_runner] ${pb_name} succeeded on attempt ${attempts}"
            return 0
        fi

        echo "[ansible_runner] ${pb_name} failed (rc=${rc}), attempt ${attempts}/${max_attempts}"

        if [[ $attempts -lt $max_attempts ]]; then
            sleep $((attempts * 10))
        else
            echo "[ansible_runner] Max attempts reached for ${pb_name}"

            # NEW: Track failure instead of exiting
            FAILED_PLAYBOOKS+=("${pb_name}")
            FAILED_LOGS+=("${logfile}")

            return 1
        fi
    done
}

##############################################
# PLAYBOOK 1 — ansible_managed.yml
##############################################
{
  cd "${ANSIBLE_DIR}"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook ansible_managed.yml \
        -i '${INVENTORY_PATH}' \
        --limit='${TARGET_FQDN}' \
        -e ansible_ssh_user='${SSH_USER}'"

  run_playbook "play1-ansible_managed" "${CMD}" || true
}

##############################################
# PLAYBOOK 2 — users.yml
##############################################
{
  cd "${ANSIBLE_DIR}"

  ADMIN_USERS_JSON="$(build_admin_users_json)"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook users.yml -v \
        -i '${INVENTORY_PATH}' \
        --limit='${TARGET_FQDN}' \
        --tags='user,pubkeys' \
        --extra-vars='${ADMIN_USERS_JSON}'"

  run_playbook "play2-users" "${CMD}" || true
}

##############################################
# PLAYBOOK 3 — jenkins-builder-disk.yml
##############################################
{
  cd "${ANSIBLE_DIR}"

  CMD="ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_STDOUT_CALLBACK=json ansible-playbook -v tools/jenkins-builder-disk.yml \
        -i '${INVENTORY_PATH}' \
        --limit='${TARGET_FQDN}'"

  run_playbook "play3-tools-disk" "${CMD}" || true
}

##############################################
# PLAYBOOK 4 — builder.yml (USES VAULT)
##############################################
EXTRA_VARS=""

if [[ "${LIBVIRT}" == "true" ]]; then
    echo "[ansible_runner] libvirt detected for ${TARGET_FQDN}"
    EXTRA_VARS="-e libvirt=true"
fi

{
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

  run_playbook "play4-main-builder" "${CMD}" || true
}

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

    python3 - "${FAILED_LOGS[$i]}" <<'PY'
import json
import sys

log_file = sys.argv[1]

with open(log_file, errors="replace") as f:
    content = f.read()

found = False

# Try to extract the JSON payload from mixed log output
start = content.find("{")
end = content.rfind("}")

if start != -1 and end != -1 and end > start:
    try:
        data = json.loads(content[start:end + 1])

        for play in data.get("plays", []):
            for task_entry in play.get("tasks", []):
                task = task_entry.get("task", {})
                task_name = task.get("name", "unknown task")

                for host, result in task_entry.get("hosts", {}).items():
                    is_failure = (
                        result.get("failed")
                        or result.get("unreachable")
                        or result.get("rc", 0) not in (0, None)
                        or "exception" in result
                    )

                    if is_failure:
                        found = True
                        print(f"Task    : {task_name}")
                        print(f"Host    : {host}")

                        msg = result.get("msg")
                        if msg:
                            print(f"Message : {msg}")

                        stderr = result.get("stderr")
                        if stderr:
                            print(f"Stderr  : {stderr}")

                        stdout = result.get("stdout")
                        if stdout:
                            print(f"Stdout  : {stdout}")

                        exception = result.get("exception")
                        if exception:
                            print(f"Exception : {exception}")

                        rc = result.get("rc")
                        if rc not in (None, 0):
                            print(f"Return code : {rc}")

                        print("----------------------------------------")
    except Exception:
        pass

# Fallback: show the last part of the log if structured details were not found
if not found:
    print("No structured failure details found. Showing last 80 log lines:")
    print("----------------------------------------")
    tail_lines = content.splitlines()[-80:]
    for line in tail_lines:
        print(line)
    print("----------------------------------------")
PY

echo "========================================"
echo "Build FAILED due to above errors"
echo "========================================"

exit 1
