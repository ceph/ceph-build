#!/bin/bash
# vim: ts=4 sw=4 expandtab

function setup_pipx () {
  command -v pipx || (
    command -v apt && sudo apt install -y pipx
    command -v dnf && sudo dnf install -y pipx
  ) || true
  ! command -v pipx || pipx ensurepath
}

function setup_uv () {
  if command -v uv || [ -x ~/.local/bin/uv ]; then
    return 0
  fi
  setup_pipx
  if command -v pipx; then
    pipx install uv
  else
    # No pipx package, e.g. EL9 (retired from EPEL 9).
    python3 -m pip install --user uv
  fi
}

# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE[0]}")" ]; then
  setup_uv
fi
