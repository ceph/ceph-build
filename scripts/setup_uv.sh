#!/bin/bash
# vim: ts=4 sw=4 expandtab

function setup_pipx () {
  command -v pipx || (
    command -v apt && sudo apt install -y pipx
    command -v dnf && sudo dnf install -y pipx
  ) || true
  pipx ensurepath
}

function setup_uv () {
  setup_pipx
  pipx install uv
}

# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE[0]}")" ]; then
  setup_uv
fi
