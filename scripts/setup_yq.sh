#!/bin/bash
# vim: ts=4 sw=4 expandtab

function setup_yq () {
  # Check if yq is already installed
  if command -v yq >/dev/null 2>&1; then
    echo "yq already installed: $(yq --version)"
    return 0
  fi

  # Install yq
  command -v yq || (
    command -v apt && sudo apt install -y yq
    command -v dnf && sudo dnf install -y yq
  ) || true

  # Verify yq installation
  yq --version
}

# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE[0]}")" ]; then
  setup_yq
fi
