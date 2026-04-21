teuthology-runner
=================

Schedules Teuthology suites from **caller-provided data** only.
When **CEPH_SHA1** is empty, the branch tip is resolved with **``git ls-remote``** (no ceph repo clone).

**SUITE_RUNS_JSON** (text parameter): JSON array of objects. Each object must include ``suite``
(optional alias ``name``). Optional per-row fields: ``limit``, ``threshold``, ``subset``, ``priority``,
``flavor``, ``kernel``, ``filter``, ``forcePriority``, ``suiteSha``. Missing fields fall back to job
parameters ``SUITE_LIMIT``, ``SUITE_JOB_THRESHOLD``, ``SUITE_SUBSET``, ``SUITE_SHA``.

**SUITE_LIST** (comma-separated names): used when ``SUITE_RUNS_JSON`` is empty; each run uses the
global ``SUITE_LIMIT`` / ``SUITE_JOB_THRESHOLD`` / ``SUITE_SUBSET`` / ``SUITE_SHA``.

Callers: **teuthology-nightly-cadence** builds JSON from its own cadence tables; **release-tracker-workflow**
resolves a suite list and passes ``SUITE_LIST`` plus only the optional parameters that are set.
