#!/bin/bash
#
# Build-tree cache for ceph-pr-pipeline.  The build stage compiles ceph (with
# tests) once, tars up the checkout+build tree, and uploads it to S3; the test
# legs (make check, API tests) download it on their own builders instead of
# rebuilding.  Because objects are keyed by PR head sha, a re-run of any leg
# for the same sha reuses the existing build instead of compiling again.
#
# Requires build_utils.sh to be sourced first (create_venv_dir /
# install_python_packages).
#
# Environment:
#   CACHE_ENDPOINT - S3 endpoint URL
#   CACHE_BUCKET   - bucket name
#   CACHE_KEY      - object key, e.g. pr-builds/12345/<head sha>.tar.zst
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY - bucket credentials

s3_setup() {
    if ! command -v zstd > /dev/null; then
        sudo apt-get install -y zstd || sudo yum install -y zstd
    fi
    if [ -z "$AWSCLI" ]; then
        local pkgs=( "awscli" )
        local venv
        venv=$(create_venv_dir)
        install_python_packages "$venv" "pkgs[@]"
        AWSCLI=${venv}/bin/aws
    fi
}

s3_cache_exists() {
    $AWSCLI --endpoint-url "$CACHE_ENDPOINT" \
        s3api head-object --bucket "$CACHE_BUCKET" --key "$CACHE_KEY"
}

# $1 - directory to archive (e.g. ceph)
s3_cache_put() {
    local dir=$1
    local tarball
    tarball=$(mktemp -p "$WORKSPACE" cache-XXXX.tar.zst)
    # zstd -3 with all cores: fast enough to not matter next to the build,
    # small enough to move between builders quickly.
    tar -C "$dir" --use-compress-program="zstd -T0 -3" -cf "$tarball" .
    ls -lh "$tarball"
    $AWSCLI --endpoint-url "$CACHE_ENDPOINT" --cli-connect-timeout 60 \
        s3 cp --no-progress "$tarball" "s3://${CACHE_BUCKET}/${CACHE_KEY}"
    rm -f "$tarball"
}

# $1 - directory to extract into (created if missing)
s3_cache_get() {
    local dir=$1
    mkdir -p "$dir"
    $AWSCLI --endpoint-url "$CACHE_ENDPOINT" --cli-connect-timeout 60 \
        s3 cp --no-progress "s3://${CACHE_BUCKET}/${CACHE_KEY}" - \
        | tar -C "$dir" --use-compress-program="zstd -T0 -d" -xf -
}
