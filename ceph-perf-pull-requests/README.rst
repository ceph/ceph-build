ceph-perf-pull-requests
=========================

Jenkins Job Builder definitions for CBT performance regression checks on Ceph pull
requests.

Layout
------

::

    ceph-perf-pull-requests/
      config/definitions/ceph-perf-pull-requests.yml   # JJB job wiring only
      build/
        common.sh                 # shared wipe / process helpers
        setup-pre.sh              # packages, pre-wipe
        prepare-workloads.py      # classic vs crimson YAML + SeaStore device pick
        prepare-workloads-*.sh    # embed the .py into the agent workspace
        setup-post.sh             # venv, github check in_progress
        run-cbt                   # one CBT archive run (env: SRC_DIR, WORKLOAD, ...)
        compare                   # compare.py + github check completed
        cleanup                   # postbuild wipe
        reboot                    # failure/abort reboot
      README.rst

Shell steps are inlined into the Jenkins job at ``jenkins-jobs update`` time via
``!include-raw-verbatim`` (same pattern as ``ceph-volume-cephadm-prs``). Template
parameters are passed with EnvInject (``OSD_FLAVOR``, check app ids, etc.).

Jobs
----

The ``ceph-perf`` project generates two freestyle jobs:

- ``ceph-perf-classic`` — classical ``ceph-osd`` via ``run-cbt.sh --classical``,
  workload from ``qa/suites/perf-basic/workloads/radosbench_4K_write.yaml``
- ``ceph-perf-crimson`` — ``crimson-osd`` via ``run-cbt.sh``, workloads from
  ``src/test/crimson/cbt/radosbench_4K_{read,write}.yaml``. **Always SeaStore**
  (never CyanStore). Prefers the **3 largest** unmounted NVMes when present
  (pilot node ``o02``, see https://tracker.ceph.com/issues/78071 — so three
  7.3T drives, never OS ``sda`` / small mounted disks). If fewer than 3 spare
  NVMes exist, creates three ~32GiB sparse images under
  ``$WORKSPACE/seastore-imgs/`` and still runs SeaStore.

Both run on ``performance`` nodes, build ``ceph-main`` and the PR merge ref
(``WITH_CRIMSON=ON``, ``vstart-base`` + ``crimson-osd``; compiler selection via
``run-make.sh`` / ``discover_compiler``, same idea as make-check). Only one perf
job runs at a time (``concurrent: false`` + shared throttle category ``ceph-perf``)
so classic and crimson cannot load the same machine together. The ``ceph-perf``
throttle category must exist in Jenkins (Throttle Concurrent Builds plugin).

Results are compared with ``cbt/compare.py``. A GitHub check
(``perf-test-{osd-flavor}``) gets a markdown report that includes node name,
store backend, and SHAs. The check fails if any compared workload regresses.

Triggering
----------

On a ``ceph/ceph`` pull request, comment (required; case-insensitive)::

    jenkins test classic perf
    jenkins test crimson perf

Builds are comment-only (``only-trigger-phrase: true``). You do **not** need the
``performance`` label — just post the comment above (one flavor per comment).
Each CBT run is bounded to 1 hour and the whole job to 8 hours so a hung
``radosbench`` cannot hold a performance node indefinitely.

See ``doc/dev/continuous-integration.rst`` in the Ceph tree for an overview of
how this job fits into CI.

What the job does
-----------------

1. Prepares flavor-specific workload YAML(s) under ``$WORKSPACE/perf-workloads/``
   (adds ``acceptable:`` with ~10% near-tolerance for compare.py). It also adds a
   short-term **warm-up** ``prefill_time`` (>= the measured window, min 30s) so
   the measurement does not run on a cold cluster: radosbench has no dedicated
   warm-up phase, and a cold/absent prefill adds variance (and can leave a read
   phase with no output). This applies to the crimson **read** workload and the
   classic **perf-basic write** workload (crimson write is left as the checked-in
   file). The prefill pass lands in ``prefill/`` and is not compared. The durable
   fix belongs in CBT / the checked-in Ceph CBT YAML.
2. For each of ``ceph-main`` and the PR merge ref: build once (reuse ``build/``
   for a second workload), run CBT, archive under
   ``{basedir}/{workload}/{store_tag}/<short-sha>/``.
3. Compare archives and post the GitHub check.
4. Archive reports + CBT results as Jenkins artifacts (kept ~60 days with the
   build console), so “View more details” keep working after the fact.

On failure/success the job drops partial CBT archives (so they are never reused),
stops cluster processes, and wipes the job’s SeaStore NVMes (``wipefs`` + leading
zeros; nvme-only, never if mounted). Compare regressions fail both the GitHub
check **and** the Jenkins build.

An archive is treated as complete (reusable, and accepted after a run) only if
the **measured** phase produced ``json_output.*`` (``write/``, ``rand/`` or
``seq/`` — ``prefill/`` alone does not count). This prevents reusing a run that
was SIGKILLed mid-read, which otherwise makes ``compare.py`` fail with
``FileNotFoundError`` on a missing ``json_output``.

``store_tag`` is ``classic`` or ``seastore`` so backends never reuse each
other’s baselines.

Developer guide: reading the results
------------------------------------

This section explains the GitHub check table in plain terms.

What question the check answers
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

**Did this PR make the fixed CBT workload(s) worse than current ``main`` on the
performance node, beyond the allowed tolerance?**

It is a regression smoke signal, not a full performance study and not a
functional correctness test.

Where things live
~~~~~~~~~~~~~~~~~

================== =================================== ============================================
Piece              Location                            Role
================== =================================== ============================================
Classic workload   Ceph ``qa/suites/perf-basic/``       ``radosbench_4K_write.yaml``
Crimson workload   Ceph ``src/test/crimson/cbt/``       ``radosbench_4K_read/write.yaml``
Job wiring         This directory (JJB YAML)           Build, run CBT, post GitHub check
CBT runner         ``https://github.com/ceph/cbt``     Runs ``rados bench``, collects metrics
Compare            ``cbt/compare.py``                  PR archive vs main archive → table
GitHub check       ``perf-test-classic`` / crimson     Report on the pull request
Jenkins artifacts  Build artifacts + console           Baseline/PR archives, report, meta
================== =================================== ============================================

Useful links:

- Classic write: https://github.com/ceph/ceph/blob/main/qa/suites/perf-basic/workloads/radosbench_4K_write.yaml
- Crimson read: https://github.com/ceph/ceph/blob/main/src/test/crimson/cbt/radosbench_4K_read.yaml
- Crimson write: https://github.com/ceph/ceph/blob/main/src/test/crimson/cbt/radosbench_4K_write.yaml
- Metric collectors: https://github.com/ceph/cbt/blob/main/benchmark/radosbench.py
- Acceptance evaluation: https://github.com/ceph/cbt/blob/main/benchmark/benchmark.py
- Compare / report: https://github.com/ceph/cbt/blob/main/compare.py
- Perf pilot node (SeaStore NVMe): https://tracker.ceph.com/issues/78071

What each workload runs
~~~~~~~~~~~~~~~~~~~~~~~

**Classic — 4K write** (``qa/suites/perf-basic/.../radosbench_4K_write.yaml``):

- Classical ``ceph-osd`` (``run-cbt.sh --classical``).
- Write-only 4K bench (``time: 300``, ``concurrent_ops: 4``, 256 PGs).
- ``acceptable:`` is injected by the job (perf-basic upstream has none).

**Crimson — 4K random read** (``radosbench_4K_read.yaml``):

- Prefill write (~3s) then random 4K read (~30s), ``concurrent_ops: 16``, 128 PGs.
- Two concurrent client processes.

**Crimson — 4K write** (``radosbench_4K_write.yaml``):

- Write-only 4K bench (~3s), same cluster shape.

Pass / fail rules
~~~~~~~~~~~~~~~~~

Jenkins workspace copies use ~**10%** near-tolerance (wider than the 5% baked into
the crimson CBT YAML upstream) to reduce single-shot false positives::

    bandwidth:        (or (greater) (near 0.10))
    iops_avg:         (or (greater) (near 0.10))
    latency_avg:      (or (less) (near 0.10))
    iops_stddev:      (or (less) (near 2.00))
    cpu_cycles_per_op:(or (less) (near 0.10))

Jenkins console log order (easy to misread)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CBT verbose logs look like::

    rand/host/1: bandwidth: (or (greater) (near 0.10)):: 203.5/220.4  => rejected

The fraction is **``result/baseline``** (PR first, main second), **not**
baseline/result. Prefer the GitHub table headers when in doubt.

What the baseline is
~~~~~~~~~~~~~~~~~~~~

The baseline is **not** “the commit before the PR.”

Each job:

1. Checks out current ``origin/main`` into ``ceph-main``.
2. Builds and runs CBT; archives under
   ``$WORKSPACE/cbt-results/{workload}/{store_tag}/<main-short-sha>/``.
3. Checks out the PR merge ref into ``ceph-pr`` and does the same under
   ``$WORKSPACE/ceph-pr/{workload}/{store_tag}/<pr-short-sha>/``.
4. Compares PR archives to main archives.

If a matching **baseline** archive already exists and is **complete** (its
measured phase has ``json_output.*``) on that node, the main CBT run is
**reused** (PR-side archives are rebuilt each run because the ``ceph-pr``
checkout wipes its workspace). When ``main`` moves, or the store backend
changes (new ``store_tag``), you get a new baseline directory.

Teuthology YAML translation
---------------------------

Benchmark definitions use teuthology's ``tasks`` format. ``run-cbt.sh`` calls
``t2c.py`` to extract the ``cbt`` task and emit a CBT configuration. That
translator lives in the Ceph repository with unit tests in ``test_t2c.py``; the
Jenkins job does not patch it at build time.
