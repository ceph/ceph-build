#!/bin/bash
set -euo pipefail

TARGET_FQDN="$1"
WORK_DIR="$2"
VENV_DIR="$3"
OS="$4"
BUILDER_TOKEN="$5"
VAULT_PASS="$6"
PLAYBOOK="${7:-}"   # ✅ Optional argument

# Paths
ANSIBLE_DIR="$WORK_DIR/repos/ansible"
INVENTORY="$WORK_DIR/repos/secret-repo/ansible/inventory"
VAULT_FILE="$WORK_DIR/.vault_pass.txt"

# Activate venv
source "$WORK_DIR/.venv/bin/activate"

# Write vault password
echo "$VAULT_PASS" > "$VAULT_FILE"

# Default playbooks (old behavior)
DEFAULT_PLAYBOOKS=(
  "ansible_managed.yml"
  "users.yml"
  "jenkins-builder-disk.yml"
  "builder.yml"
)

# ✅ Decide what to run
if [[ -n "$PLAYBOOK" ]]; then
  PLAYBOOKS=("$PLAYBOOK")
else
  PLAYBOOKS=("${DEFAULT_PLAYBOOKS[@]}")
fi

echo "[INFO] Target: $TARGET_FQDN"
echo "[INFO] Using inventory: $INVENTORY"

cd "$ANSIBLE_DIR"

for pb in "${PLAYBOOKS[@]}"; do
  echo "[INFO] Running playbook: $pb"

  ansible-playbook \
    -i "$INVENTORY" \
    --private-key "/tmp/key_${TARGET_FQDN%%.*}" \
    --limit "$TARGET_FQDN" \
    --extra-vars "builder_token=$BUILDER_TOKEN os=$OS" \
    -e "ansible_user=ubuntu" \
    --vault-password-file "$VAULT_FILE" \
    "playbooks/$pb"

done

echo "[INFO] Completed playbook execution"
