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
#   CACHE_ENDPOINTS - space-separated S3 endpoint URLs (all serving the same
#                     zone, e.g. the RGWs on the doli LRC hosts); s3_setup
#                     sets CACHE_ENDPOINT to the first one that answers
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
    # Every endpoint serves the same RGW zone; take the first live one so a
    # single host being down doesn't fail the leg.
    local ep
    for ep in $CACHE_ENDPOINTS; do
        if curl -s -m 10 -o /dev/null "$ep"; then
            CACHE_ENDPOINT=$ep
            return 0
        fi
        echo "s3_setup: $ep not answering, trying next" >&2
    done
    echo "s3_setup: no cache endpoint reachable: $CACHE_ENDPOINTS" >&2
    return 1
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

# The bwc build image travels with the tree, under the tree's key plus an
# .image suffix, so the test legs run in exactly the image the tree was
# compiled in.  Every builder used to build its own copy of that image and
# bwc only compares a hash of the sources, so identically-tagged images
# differed across the fleet (2026-10-16: 2371 cached PR images in six
# distinct sizes) and a tree restored into another builder's copy failed to
# re-run cmake (FindBoost "0.0.0") or to load libboost_*.so.
s3_image_key() {
    echo "${CACHE_KEY%.tar.zst}.image.tar.zst"
}

s3_image_exists() {
    $AWSCLI --endpoint-url "$CACHE_ENDPOINT" \
        s3api head-object --bucket "$CACHE_BUCKET" --key "$(s3_image_key)"
}

# $1 - image reference to save (see bwc_image_name)
s3_image_put() {
    local image=$1
    [ -n "$image" ] || { echo "s3_image_put: no image to save" >&2; return 1; }
    podman image inspect --format 'saving {{.Id}} ({{.Size}} bytes) as {{index .RepoTags 0}}' "$image"
    # podman save emits uncompressed layer tars; -3 keeps up with the disk
    # and shrinks a ~5G image to roughly a third on the wire.  pipefail in
    # a subshell: the legs run without it, and a failed save must not leave
    # a truncated object that every test leg then chokes on.
    (
        set -o pipefail
        podman save "$image" \
            | zstd -T0 -3 \
            | $AWSCLI --endpoint-url "$CACHE_ENDPOINT" --cli-connect-timeout 60 \
                s3 cp --no-progress - "s3://${CACHE_BUCKET}/$(s3_image_key)"
    )
}

# Load the saved image.  Its tag replaces whatever this builder had under
# the same name, which is the point: bwc then finds "its" image present and
# passing the source check and runs in this one.
s3_image_get() {
    (
        set -o pipefail
        $AWSCLI --endpoint-url "$CACHE_ENDPOINT" --cli-connect-timeout 60 \
            s3 cp --no-progress "s3://${CACHE_BUCKET}/$(s3_image_key)" - \
            | zstd -T0 -d \
            | podman load
    )
}
