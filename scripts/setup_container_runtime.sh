#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab
function setup_container_runtime () {
  loginctl enable-linger "$(id -nu)"
  if command -v podman; then
    PODMAN_MAJOR_VERSION=$(podman version -f json | jq -r '.Client.Version|split(".")[0]')
    if [ "$PODMAN_MAJOR_VERSION" -lt 4 ]; then
      echo "Found a very old podman; removing"
      command -v dnf && sudo dnf remove -y podman
      command -v apt && sudo apt remove -y podman
    fi
  fi

  if ! command -v podman; then
    if command -v dnf; then
      sudo dnf install -y podman
    elif command -v apt-cache; then
      sudo apt-get update -q
      VERSION=$(apt-cache show podman | grep Version: | sort -r | awk '/^Version:/{print $2; exit}')
      if [[ "${VERSION:0:1}" -ge 4 ]]; then
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y podman
      elif ! command -v docker; then
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y docker.io
      fi
    fi
  fi

  if command -v podman; then
    PODMAN_MAJOR_VERSION=$(podman version -f json | jq -r '.Client.Version|split(".")[0]')
    if [ "$PODMAN_MAJOR_VERSION" -ge 4 ]; then
      PODMAN_DIR="$HOME/.local/share/containers"
      test -d "$PODMAN_DIR" && command -v restorecon && sudo restorecon -R -T0 -x "$PODMAN_DIR"
      PODMAN_STORAGE_DIR="$PODMAN_DIR/storage"
      if [ -d "$PODMAN_STORAGE_DIR" ]; then
        sudo chgrp -R "$(groups | cut -d' ' -f1)" "$PODMAN_STORAGE_DIR"
        if [ "$(podman unshare du -s --block-size=1G "$PODMAN_STORAGE_DIR" | awk '{print $1}')" -ge 50 ]; then
          time podman image prune --filter=until="$((24*7))h" --all --force
          time podman system prune --force
          test "$PODMAN_MAJOR_VERSION" -ge 5 && time podman system check --repair --quick
        fi
      fi
    fi
  fi
}

# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE[0]}")" ]; then
  setup_container_runtime
fi
