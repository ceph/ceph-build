#!/bin/bash -ex
# vim: ts=4 sw=4 expandtab
function setup_uv () {
  release_filename="uv-$(uname -m)-unknown-linux-gnu.tar.gz"
  release_url="https://github.com/astral-sh/uv/releases/latest/download/${release_filename}"

  TEMPDIR="$(mktemp -d)"
  cd "$TEMPDIR"
  curl -LO "$release_url"
  sudo tar --no-anchored --strip-components=1 -C /usr/local/bin -xzf "${TEMPDIR}/${release_filename}" uv uvx
  uv python list --only-installed
  rm -rf "$TEMPDIR"
}
# 
# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE[0]}")" ]; then
  setup_uv
fi
