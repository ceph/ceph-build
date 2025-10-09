#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab
function setup_container_runtime () {
  loginctl enable-linger "$(id -nu)"
  if command -v podman; then
    podman system info > /dev/null || podman system reset --force
    if [ "$(podman version -f "{{ lt .Client.Version \"4\" }}")" = "true" ]; then
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
     
    # remove any leftover containers that might be present because of
    # bad exits from podman (like an oom kill or something).
    # We've observed new jobs failing to run because they can't create
    # a container named ceph_build
    podman rm -f ceph_build 

    if [ "$(podman version -f "{{ lt .Client.Version \"5.6.1\" }}")" = "true" ] && \
    ! echo "928238bfcdc79a26ceb51d7d9759f99144846c0a  /etc/tmpfiles.d/podman.conf" | sha1sum --status --check -; then
      # Pull in this fix: https://github.com/containers/podman/pull/26986
      curl -sS -L -O https://github.com/containers/podman/raw/refs/tags/v5.6.1/contrib/tmpfile/podman.conf
      sudo mv podman.conf /etc/tmpfiles.d/
      sudo systemd-tmpfiles --remove
    fi
    if [ "$(podman version -f "{{ ge .Client.Version \"4\" }}")" = "true" ]; then
      PODMAN_DIR="$HOME/.local/share/containers"
      test -d "$PODMAN_DIR" && command -v restorecon && sudo restorecon -R -T0 -x "$PODMAN_DIR"
      PODMAN_STORAGE_DIR="$PODMAN_DIR/storage"
      if [ -d "$PODMAN_STORAGE_DIR" ]; then
        sudo chgrp -R "$(groups | cut -d' ' -f1)" "$PODMAN_STORAGE_DIR"
        if [ "$(podman unshare du -s --block-size=1G "$PODMAN_STORAGE_DIR" | awk '{print $1}')" -ge 50 ]; then
          time podman image prune --filter=until="$((24*7))h" --all --force
          time podman system prune --force
          if [ "$(podman version -f "{{ ge .Client.Version \"5\" }}")" = "true" ]; then
            time podman system check --repair --quick
          fi
        fi
      fi
    fi
  fi
}

# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE[0]}")" ]; then
  setup_container_runtime
fi
