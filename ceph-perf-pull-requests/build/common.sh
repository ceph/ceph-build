#!/bin/bash
# Shared helpers for ceph-perf jobs.
# Included (concatenated) before setup / run-cbt / compare / cleanup via JJB.

kill_cluster_procs() {
    local p
    for p in crimson-osd ceph-osd ceph-mon ceph-mgr rados; do
        sudo pkill -9 -x "$p" || true
    done
}

# Wipe *contents* of SeaStore block devices listed in $WORKSPACE/seastore-devs.txt.
# Accepts only /dev/nvme* and /dev/loop* (vstart requires writable block devices).
# Never detaches loop devices or deletes backing images here — those stay for the
# whole job; see teardown_seastore_devs for final cleanup. Pre-CBT wipe used to
# `rm` sparse .img paths, which broke SeaStore (ceph-perf-crimson #41).
wipe_seastore_devs() {
    : "${WORKSPACE:?}"
    local devs_file="${WORKSPACE}/seastore-devs.txt"
    local dev mountpoints
    if test ! -s "$devs_file"; then
        return 0
    fi
    while IFS= read -r dev || test -n "$dev"; do
        test -n "$dev" || continue
        case "$dev" in
            /dev/nvme*|/dev/loop*)
                if test ! -b "$dev"; then
                    echo "skip wipe, not a block device: $dev" >&2
                    continue
                fi
                if ! command -v lsblk >/dev/null 2>&1; then
                    echo "REFUSING to wipe (lsblk not found to verify mounts): $dev" >&2
                    continue
                fi
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
            *)
                echo "REFUSING to wipe unexpected SeaStore path: $dev" >&2
                continue
                ;;
        esac
    done < "$devs_file"
}

# Detach loop devices and remove sparse backing images (end of job / next job start).
teardown_seastore_devs() {
    : "${WORKSPACE:?}"
    local devs_file="${WORKSPACE}/seastore-devs.txt"
    local img_dir="${WORKSPACE}/seastore-imgs"
    local dev
    if test -s "$devs_file"; then
        while IFS= read -r dev || test -n "$dev"; do
            test -n "$dev" || continue
            case "$dev" in
                /dev/loop*)
                    echo "Detaching SeaStore loop device $dev"
                    sudo losetup -d "$dev" || true
                    ;;
            esac
        done < "$devs_file"
    fi
    rm -rf "$img_dir"
}

# True if $1 is a writable block device. For /dev/loop*, also require an
# attached BACK-FILE: a detached loop node still passes `[ -b ] && [ -w ]`
# (vstart's check) after chmod a+rw, but SeaStore would see an empty device.
seastore_dev_ready() {
    local dev=$1
    local back
    test -b "$dev" && test -w "$dev" || return 1
    case "$dev" in
        /dev/loop*)
            back=$(sudo losetup -n -O BACK-FILE "$dev" 2>/dev/null || true)
            # losetup prints a blank BACK-FILE line when the node is free.
            printf '%s' "$back" | grep -q '[^[:space:]]'
            ;;
        *)
            return 0
            ;;
    esac
}

# Ensure every seastore-devs entry is a writable block device (vstart requirement).
# Re-attaches workspace images to free loop devices if a prior wipe/teardown left
# them detached. Fails the job loudly if SeaStore cannot run.
ensure_seastore_devs() {
    : "${WORKSPACE:?}"
    local devs_file="${WORKSPACE}/seastore-devs.txt"
    local img_dir="${WORKSPACE}/seastore-imgs"
    local dev img i new_devs="" replaced=0
    if test ! -s "$devs_file"; then
        return 0
    fi
    i=0
    while IFS= read -r dev || test -n "$dev"; do
        test -n "$dev" || continue
        if seastore_dev_ready "$dev"; then
            new_devs="${new_devs}${dev}"$'\n'
            i=$((i + 1))
            continue
        fi
        img="${img_dir}/osd-${i}.img"
        if test ! -f "$img"; then
            echo "ERROR: SeaStore device $dev missing and no backing image $img" >&2
            return 1
        fi
        echo "Re-attaching SeaStore image $img (was $dev)"
        # detach stale association if any
        sudo losetup -d "$dev" 2>/dev/null || true
        dev=$(sudo losetup --show -f "$img") || {
            echo "ERROR: losetup failed for $img" >&2
            return 1
        }
        sudo chmod a+rw "$dev" || true
        if ! seastore_dev_ready "$dev"; then
            echo "ERROR: $dev is not a ready SeaStore block device after losetup" >&2
            return 1
        fi
        new_devs="${new_devs}${dev}"$'\n'
        replaced=1
        i=$((i + 1))
    done < "$devs_file"
    if test "$replaced" -eq 1; then
        printf '%s' "$new_devs" > "$devs_file"
        # Refresh the run-cbt wrapper seastore-devs list if present.
        if test -f "${WORKSPACE}/run-cbt-seastore.sh"; then
            local csv
            csv=$(printf '%s' "$new_devs" | paste -sd, -)
            # Replace --seastore-devs <old> with current csv (single occurrence).
            sed -i -E "s|--seastore-devs [^ \\\]+|--seastore-devs ${csv}|" \
                "${WORKSPACE}/run-cbt-seastore.sh"
        fi
    fi
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
