#!/usr/bin/env python3
"""Prepare flavor-specific CBT YAMLs and SeaStore device list.

Env:
  WORKSPACE   Jenkins workspace
  OSD_FLAVOR  classic | crimson
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import yaml


def inject_acceptable(doc: dict, acceptable: dict) -> None:
    for task in doc.get("tasks") or []:
        if not isinstance(task, dict) or "cbt" not in task:
            continue
        bench = task["cbt"].setdefault("benchmarks", {}).setdefault("radosbench", {})
        bench["acceptable"] = dict(acceptable)
        return
    raise SystemExit("no cbt/radosbench task found in workload YAML")


def warmup_read_prefill(doc: dict) -> str | None:
    """Warm the system with writes before a read measurement.

    radosbench has no dedicated warm-up phase: a read test does one short
    prefill write pass (default prefill_time: 3) then measures. Cold caches and
    a tiny working set add variance and can leave the read phase without output.
    Short-term stand-in for a real warm-up (per perf maintainer): lengthen the
    single prefill to at least the measured read window. Durable fix belongs in
    CBT (a native warm-up/2nd-prefill) or the checked-in Ceph CBT YAML.
    """
    for task in doc.get("tasks") or []:
        if not isinstance(task, dict) or "cbt" not in task:
            continue
        bench = task["cbt"].setdefault("benchmarks", {}).setdefault("radosbench", {})
        is_read = (
            bench.get("read_only")
            or "readmode" in bench
            or "prefill_time" in bench
            or "prefill_objects" in bench
        )
        if not is_read:
            return None  # write-only test: no read prefill to warm
        read_time = bench.get("read_time") or bench.get("time") or 30
        current = bench.get("prefill_time") or 0
        warmup = max(current, read_time, 30)
        bench["prefill_time"] = warmup
        return f"read_warmup_prefill_time={current}->{warmup}"
    return None


def warmup_write_prefill(doc: dict) -> str | None:
    """Warm the system with writes before a write measurement.

    radosbench has no dedicated warm-up phase, so a write test measures from a
    cold cluster (cold caches/allocator, unallocated store) which adds variance.
    Per perf maintainer, add a prefill write pass (>= the measured write window,
    min 30s) before the measurement. radosbench runs prefill -> write for a
    write_only test, so the measured 'write/' phase is unaffected while
    'prefill/' warms the system. Durable fix belongs in CBT / the Ceph CBT YAML.
    """
    for task in doc.get("tasks") or []:
        if not isinstance(task, dict) or "cbt" not in task:
            continue
        bench = task["cbt"].setdefault("benchmarks", {}).setdefault("radosbench", {})
        write_time = bench.get("write_time") or bench.get("time") or 30
        current = bench.get("prefill_time") or 0
        warmup = max(current, write_time, 30)
        bench["prefill_time"] = warmup
        return f"write_warmup_prefill_time={current}->{warmup}"
    raise SystemExit("no cbt/radosbench task found in workload YAML")


def device_has_mount(dev_path: str) -> bool:
    try:
        out = subprocess.check_output(
            ["lsblk", "-n", "-o", "MOUNTPOINT", dev_path],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return True  # fail closed
    return any(line.strip() for line in out.splitlines())


def main() -> int:
    ws = Path(os.environ["WORKSPACE"])
    flavor = os.environ["OSD_FLAVOR"]
    out = ws / "perf-workloads"
    out.mkdir(parents=True, exist_ok=True)
    main_src = ws / "ceph-main"
    # 10% near-tolerance to reduce single-shot false positives vs upstream 5%.
    acceptable = {
        "bandwidth": "(or (greater) (near 0.10))",
        "iops_avg": "(or (greater) (near 0.10))",
        "iops_stddev": "(or (less) (near 2.00))",
        "latency_avg": "(or (less) (near 0.10))",
        "cpu_cycles_per_op": "(or (less) (near 0.10))",
    }
    meta: list[str] = []
    devs_file = ws / "seastore-devs.txt"

    if flavor == "classic":
        src = main_src / "qa/suites/perf-basic/workloads/radosbench_4K_write.yaml"
        doc = yaml.safe_load(src.read_text())
        inject_acceptable(doc, acceptable)
        # perf-basic has no prefill; add a warm-up write pass before measuring.
        meta.append(f"radosbench_4K_write.yaml_{warmup_write_prefill(doc)}")
        (out / "radosbench_4K_write.yaml").write_text(
            yaml.safe_dump(doc, sort_keys=False)
        )
        meta.append(f"write_yaml_source={src}")
        meta.append("workloads=write")
        store_tag = "classic"
        devs_file.write_text("")
    else:
        for name in ("radosbench_4K_read.yaml", "radosbench_4K_write.yaml"):
            src = main_src / "src/test/crimson/cbt" / name
            doc = yaml.safe_load(src.read_text())
            inject_acceptable(doc, acceptable)
            note = warmup_read_prefill(doc)
            if note:
                meta.append(f"{name}_{note}")
            (out / name).write_text(yaml.safe_dump(doc, sort_keys=False))
            meta.append(f"{name}_source={src}")
        meta.append("workloads=read,write")
        # Crimson always uses SeaStore (never CyanStore). Prefer 3 spare NVMes;
        # otherwise create workspace sparse images so the job still runs SeaStore.
        store_tag = "seastore"
        nvmes: list[tuple[int, str]] = []
        for line in os.popen(
            "lsblk -dn -b -o NAME,TYPE,SIZE,MOUNTPOINT"
        ).read().splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            name, typ, size = parts[0], parts[1], parts[2]
            mnt = parts[3] if len(parts) > 3 else ""
            if typ != "disk" or not name.startswith("nvme") or mnt not in ("", "-"):
                continue
            path = f"/dev/{name}"
            if device_has_mount(path):
                meta.append(f"skip_mounted={path}")
                continue
            try:
                nvmes.append((int(size), path))
            except ValueError:
                continue
        nvmes.sort(key=lambda t: (-t[0], t[1]))
        if len(nvmes) >= 3:
            chosen = [path for _, path in nvmes[:3]]
            meta.append("seastore_backend=nvme")
            meta.append(
                "seastore_sizes_bytes="
                + ",".join(str(sz) for sz, _ in nvmes[:3])
            )
        else:
            img_dir = ws / "seastore-imgs"
            img_dir.mkdir(parents=True, exist_ok=True)
            # ~32GiB sparse files (same order as upstream cyanstore memstore_device_bytes).
            sparse_bytes = 34359738368
            chosen = []
            for i in range(3):
                img = img_dir / f"osd-{i}.img"
                # Create/resize sparse image without allocating full size.
                with open(img, "wb") as fh:
                    fh.truncate(sparse_bytes)
                chosen.append(str(img))
            meta.append("seastore_backend=sparse-file")
            meta.append(f"seastore_sparse_bytes={sparse_bytes}")
            meta.append(
                f"seastore_note=only {len(nvmes)} unmounted NVMe(s); "
                "using workspace sparse images"
            )
        devs = ",".join(chosen)
        src_sh = (main_src / "src/script/run-cbt.sh").read_text()
        old = (
            "MDS=0 MGR=1 OSD=3 MON=1 $source_dir/src/vstart.sh -n -X \\\n"
            "           --without-dashboard --cyanstore \\\n"
            '           -o "memstore_device_bytes=34359738368" \\\n'
            "           --crimson --nodaemon --redirect-output \\\n"
            '           --osd-args "--memory 4G"'
        )
        new = (
            "MDS=0 MGR=1 OSD=3 MON=1 $source_dir/src/vstart.sh -n -X \\\n"
            f"           --without-dashboard --seastore --seastore-devs {devs} \\\n"
            "           --crimson --nodaemon --redirect-output \\\n"
            '           --osd-args "--memory 4G"'
        )
        if old not in src_sh:
            raise SystemExit(
                "run-cbt.sh cyanstore vstart block not found; cannot enable SeaStore"
            )
        wrap = ws / "run-cbt-seastore.sh"
        wrap.write_text(src_sh.replace(old, new, 1))
        wrap.chmod(0o755)
        devs_file.write_text("\n".join(chosen) + "\n")
        meta.append(f"seastore_devs={devs}")

    (ws / "perf-store-tag").write_text(store_tag + "\n")
    meta_path = ws / "perf-meta.txt"
    meta_path.write_text(
        "\n".join(
            [
                f"flavor={flavor}",
                f"node={os.uname().nodename}",
                f"store={store_tag}",
                *meta,
                "acceptable_near=0.10",
            ]
        )
        + "\n"
    )
    print(meta_path.read_text())
    return 0


if __name__ == "__main__":
    sys.exit(main())
