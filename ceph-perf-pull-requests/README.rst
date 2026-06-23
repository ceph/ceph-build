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
(``WITH_CRIMSON=ON``, ``vstart-base`` + ``crimson-osd``; clang-19+ or GCC/G++ 13+),
execute the ``radosbench_4K_read.yaml`` workload from ``ceph-main``, and compare
results with ``cbt/compare.py``. A GitHub check (``perf-test-{osd-flavor}``) is
updated with the comparison report.

Triggering
----------

On a ``ceph/ceph`` pull request, comment::

    jenkins test classic perf
    jenkins test crimson perf

Pull requests with the ``performance`` label may also be built automatically.
See ``doc/dev/continuous-integration.rst`` in the Ceph tree for an overview of
how this job fits into CI.

Teuthology YAML translation
---------------------------

Benchmark definitions under ``src/test/crimson/cbt/`` use teuthology's
``tasks`` format. ``run-cbt.sh`` calls ``t2c.py`` to extract the ``cbt`` task
and emit a CBT configuration. That translator (including ``yaml.safe_load`` for
input parsing) lives in the Ceph repository with unit tests in
``test_t2c.py``; the Jenkins job does not patch it at build time.
