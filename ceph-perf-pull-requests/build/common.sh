#!/bin/bash
# Shared helpers for ceph-perf jobs.
# Included (concatenated) before setup / run-cbt / compare / cleanup via JJB.

kill_cluster_procs() {
    local p
    for p in crimson-osd ceph-osd ceph-mon ceph-mgr rados; do
        sudo pkill -9 -x "$p" || true
    done
}

# Wipe SeaStore targets listed in $WORKSPACE/seastore-devs.txt:
# - /dev/nvme*: wipefs + leading zeros (never if mounted)
# - $WORKSPACE/seastore-imgs/* sparse images: delete
# Anything else is refused.
wipe_seastore_devs() {
    # Require WORKSPACE so we never operate on /seastore-imgs or similar.
    : "${WORKSPACE:?}"
    local devs_file="${WORKSPACE}/seastore-devs.txt"
    local img_dir="${WORKSPACE}/seastore-imgs"
    local dev mountpoints
    if test ! -s "$devs_file"; then
        rm -rf "$img_dir"
        return 0
    fi
    while IFS= read -r dev || test -n "$dev"; do
        test -n "$dev" || continue
        case "$dev" in
            /dev/nvme*)
                if test ! -b "$dev"; then
                    echo "skip wipe, not a block device: $dev" >&2
                    continue
                fi
                if ! command -v lsblk >/dev/null 2>&1; then
                    echo "REFUSING to wipe (lsblk not found to verify mounts): $dev" >&2
                    continue
                fi
                # Fail closed: if lsblk cannot report mount state, do not wipe.
                if ! mountpoints=$(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null); then
                    echo "REFUSING to wipe (lsblk failed to verify mounts): $dev" >&2
                    continue
                fi
                if printf '%s\n' "$mountpoints" | grep -q '[^[:space:]]'; then
                    echo "REFUSING to wipe mounted device: $dev" >&2
                    continue
                fi
                echo "Wiping SeaStore device $dev"
                sudo wipefs -a "$dev" || true
                sudo dd if=/dev/zero of="$dev" bs=1M count=100 status=none conv=fsync || true
                ;;
            "${WORKSPACE}/seastore-imgs"/*)
                echo "Removing SeaStore sparse image $dev"
                rm -f "$dev" || true
                ;;
            *)
                echo "REFUSING to wipe unexpected SeaStore path: $dev" >&2
                continue
                ;;
        esac
    done < "$devs_file"
    rm -rf "$img_dir"
}

cleanup_vstart() {
    # Prefer stopping from the active tree if present.
    local tree
    for tree in "${SRC_DIR:-}" ceph-pr ceph-main; do
        test -n "$tree" || continue
        if test -f "${WORKSPACE}/${tree}/build/ceph.conf"; then
            ( cd "${WORKSPACE}/${tree}/build" && ../src/stop.sh --crimson ) || true
            ( cd "${WORKSPACE}/${tree}/build" && ../src/stop.sh ) || true
        fi
    done
    kill_cluster_procs
}
