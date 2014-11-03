#!/bin/sh

#
# This script ensures that a Python virtualenv is installed and available for
# a specific part of the build, including dependencies.
#

# Create the virtualenv
virtualenv venv
. venv/bin/activate

# Define and ensure the PIP cache
PIP_SDIST_INDEX="$HOME/.cache/pip"
mkdir -p $PIP_SDIST_INDEX

# Install the package by trying with the cache first, otherwise doing a download only, and then
# trying to install from the cache again.
if ! venv/bin/pip install --find-links="file://$PIP_SDIST_INDEX" --no-index amauta; then
    venv/bin/pip install --download-directory="$PIP_SDIST_INDEX" amauta
    venv/bin/pip install --find-links="file://$PIP_SDIST_INDEX" --no-index amauta
fi

