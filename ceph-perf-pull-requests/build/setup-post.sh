#!/bin/bash
# Continues setup after prepare-workloads.py has been written into $WORKSPACE.
set -euxo pipefail

python3 "${WORKSPACE}/prepare-workloads.py"

if python3 -m venv "${WORKSPACE}/gh-venv"; then
    :
else
    virtualenv -q --python python3 "${WORKSPACE}/gh-venv"
fi
# shellcheck disable=SC1091
. "${WORKSPACE}/gh-venv/bin/activate"
pip install -U pip setuptools wheel
pip install cython
pip install -r "${WORKSPACE}/cbt/requirements.txt" mdutils
python3 -c "import yaml, lxml, matplotlib, mdutils, cython, setuptools"
pip install git+https://github.com/ceph/githubcheck.git
pip install 'pyjwt<2.11'

echo "please hold tight..." | github-check \
  --owner "${CHECK_REPO_OWNER}" \
  --repo "${CHECK_REPO_NAME}" \
  --pkey-file "${GITHUB_CHECK_PKEY_PEM}" \
  --app-id "${CHECK_APP_ID}" \
  --install-id "${CHECK_INSTALL_ID}" \
  --name "${CHECK_NAME}" \
  --sha "${ghprbActualCommit}" \
  --external-id "${BUILD_ID}" \
  --details-url "${BUILD_URL}" \
  --status in_progress \
  --title "${CHECK_NAME}" \
  --summary running
