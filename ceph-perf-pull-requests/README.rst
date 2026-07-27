ceph-perf-pull-requests
=========================

Jenkins Job Builder definitions for CBT performance regression checks on Ceph pull
requests.

Jobs
----

The ``ceph-perf`` project generates two freestyle jobs:

- ``ceph-perf-classic`` — same Crimson-inclusive build as ``ceph-pull-requests``,
  CBT run with ``run-cbt.sh --classical`` (classical ``ceph-osd``)
- ``ceph-perf-crimson`` — same build, CBT run with default ``run-cbt.sh``
  (``crimson-osd`` via ``vstart.sh --crimson``)

Both run on ``performance`` nodes, build ``ceph-main`` and the PR merge ref
(``WITH_CRIMSON=ON``, ``vstart-base`` + ``crimson-osd``; compiler selection via
``run-make.sh`` / ``discover_compiler``, same idea as make-check), then execute
**both** workloads from ``ceph-main``:

- ``src/test/crimson/cbt/radosbench_4K_read.yaml`` — 4K random read
- ``src/test/crimson/cbt/radosbench_4K_write.yaml`` — 4K write

Results are compared with ``cbt/compare.py``. A GitHub check
(``perf-test-{osd-flavor}``) gets a combined markdown report with separate
sections for read and write. The check fails if **either** workload regresses.

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

For each of ``ceph-main`` and the PR merge ref the job:

1. Builds Ceph once (the second workload reuses ``build/``).
2. Runs CBT for **read**, archiving under ``{basedir}/read/<short-sha>/``.
3. Runs CBT for **write**, archiving under ``{basedir}/write/<short-sha>/``.

Then ``compare.py`` runs twice (read archive pair, write archive pair) and the
markdown outputs are merged into one GitHub check body. Example shape:

**4K random read** — ``all 20 tests passed``

============== ==================== ========== ======== ========
run            metric               baseline   result   accepted
============== ==================== ========== ======== ========
prefill/host/0 bandwidth            …          …        
prefill/host/0 iops_avg             …          …        
…              …                    …          …        
rand/host/1    latency_avg          …          …        
============== ==================== ========== ======== ========

**4K write** — ``all 10 tests passed``

============== ==================== ========== ======== ========
run            metric               baseline   result   accepted
============== ==================== ========== ======== ========
write/host/0   bandwidth            …          …        
write/host/0   iops_avg             …          …        
…              …                    …          …        
write/host/1   latency_avg          …          …        
============== ==================== ========== ======== ========

Blank ``accepted`` means OK; ``:x:`` / ❌ means the metric failed the rule.

Benchmark YAMLs are always taken from **ceph-main** (not the PR tree) so both
sides use the same workload definition and acceptance rules.

Developer guide: reading the results
------------------------------------

This section explains the GitHub check table in plain terms.

What question the check answers
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

**Did this PR make the fixed 4K CBT workloads worse than current ``main`` on the
performance node, beyond the allowed tolerance?**

It is a regression smoke signal, not a full performance study and not a
functional correctness test.

Where things live
~~~~~~~~~~~~~~~~~

================ ================================= ============================================
Piece            Location                          Role
================ ================================= ============================================
Workload + rules Ceph ``src/test/crimson/cbt/``    ``radosbench_4K_{read,write}.yaml``
Job wiring       This directory (JJB YAML)         Build, run CBT, post GitHub check
CBT runner       ``https://github.com/ceph/cbt``   Runs ``rados bench``, collects metrics
Compare          ``cbt/compare.py``                PR archive vs main archive → table
GitHub check     ``perf-test-classic`` /           Report on the pull request
                 ``perf-test-crimson``
================ ================================= ============================================

Useful links:

- Read workload: https://github.com/ceph/ceph/blob/main/src/test/crimson/cbt/radosbench_4K_read.yaml
- Write workload: https://github.com/ceph/ceph/blob/main/src/test/crimson/cbt/radosbench_4K_write.yaml
- Metric collectors: https://github.com/ceph/cbt/blob/main/benchmark/radosbench.py
- Acceptance evaluation: https://github.com/ceph/cbt/blob/main/benchmark/benchmark.py
- Compare / report: https://github.com/ceph/cbt/blob/main/compare.py

What each workload runs
~~~~~~~~~~~~~~~~~~~~~~~

**4K random read** (``radosbench_4K_read.yaml``):

- Small local cluster (3 OSDs, replicated pool).
- Prefill write (~3s) so there is data to read.
- Random 4K read (~30s).
- Two concurrent client processes (``concurrent_procs: 2``).

**4K write** (``radosbench_4K_write.yaml``):

- Same cluster shape.
- Write-only 4K bench (~3s); no separate prefill/read phase.
- Two concurrent client processes.

Why the row counts are 20 and 10
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Each compared cell is one **(phase × client process × metric)** tuple.

Five metrics:

=================== ================================================= ============
Metric              Meaning                                           Better means
=================== ================================================= ============
bandwidth           Throughput                                        Higher
iops_avg            Average IOPS                                      Higher
iops_stddev         IOPS variance / noise                             Lower
latency_avg         Average latency                                   Lower
cpu_cycles_per_op   CPU cycles per op (from ``perf`` if collected)    Lower
=================== ================================================= ============

- Read: phases ``prefill`` + ``rand``, 2 clients, 5 metrics → **20 rows**
  (names like ``prefill/toko02/0``, ``rand/toko02/1``).
- Write: phase ``write`` only, 2 clients, 5 metrics → **10 rows**
  (names like ``write/toko02/0``).

``cpu_cycles_per_op`` may show ``0.0`` when ``perf`` data was not collected; that
usually passes as a no-op comparison.

How to read the GitHub table columns
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

======== =========================================================
Column   Meaning
======== =========================================================
run      Phase / machine / client process (``rand/host/0``)
metric   Which number
baseline Value from **current ceph** ``main``
result   Value from **this PR**
accepted Blank = OK; ``:x:`` / ❌ = failed the acceptance rule
======== =========================================================

Pass / fail rules (``acceptable:`` in the YAML)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

::

    bandwidth:        (or (greater) (near 0.05))   # ≥ baseline, or within ~5%
    iops_avg:         (or (greater) (near 0.05))
    latency_avg:      (or (less) (near 0.05))      # ≤ baseline, or within ~5%
    iops_stddev:      (or (less) (near 2.00))      # ≤ baseline, or within ~2×
    cpu_cycles_per_op:(or (less) (near 0.05))

Small regressions up to about 5% on throughput/latency are allowed;
noise (``iops_stddev``) may grow up to about 2× baseline.

Jenkins console log order (easy to misread)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CBT verbose logs look like::

    rand/host/1: bandwidth: (or (greater) (near 0.05)):: 203.5/220.4  => rejected

The fraction is **``result/baseline``** (PR first, main second), **not**
baseline/result. In the example above the PR is slower than main, so rejection
is correct. Prefer the GitHub table headers when in doubt.

What the baseline is
~~~~~~~~~~~~~~~~~~~~

The baseline is **not** “the commit before the PR.”

Each job:

1. Checks out current ``origin/main`` into ``ceph-main``.
2. Builds and runs CBT; archives under
   ``$WORKSPACE/cbt-results/{read,write}/<main-short-sha>/``.
3. Checks out the PR merge ref into ``ceph-pr`` and does the same under
   ``$WORKSPACE/ceph-pr/{read,write}/<pr-short-sha>/``.
4. Compares PR archives to main archives.

If a main short-SHA archive already exists and is non-empty on that node, the
main CBT run for that workload is **reused** (not rebuilt). When ``main`` moves,
you get a new baseline directory — numbers can look very different from an
earlier run on the same PR. Node noise can also move results on the same SHA.

How to add or change metrics
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

1. Edit the ``acceptable:`` block in the Ceph workload YAML(s) if the metric is
   already collected by CBT.
2. To collect a **new** measurement, implement a getter in
   ``cbt/benchmark/radosbench.py`` and wire evaluation in
   ``cbt/benchmark/benchmark.py``.
3. ``compare.py`` only reports; it does not define metrics.

Teuthology YAML translation
---------------------------

Benchmark definitions under ``src/test/crimson/cbt/`` use teuthology's
``tasks`` format. ``run-cbt.sh`` calls ``t2c.py`` to extract the ``cbt`` task
and emit a CBT configuration. That translator (including ``yaml.safe_load`` for
input parsing) lives in the Ceph repository with unit tests in
``test_t2c.py``; the Jenkins job does not patch it at build time.
