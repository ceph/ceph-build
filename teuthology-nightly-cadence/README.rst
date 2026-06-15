teuthology-nightly-cadence
===========================

Thin Jenkins jobs that expand **daily/weekly cadence** into **SUITE_RUNS_JSON** (partition / subset per
suite) and invoke **teuthology-runner**.

- ``teuthology-nightly-cadence``: ``cadenceSteps`` expands to JSON (random ``--subset`` per ``N``). **Daily** is
  ``smoke`` plus one suite from the per-branch weekly list (index by UTC day); **main** and **umbrella** use
  the same suite list and daily behavior. **Weekly** runs the full list (same definitions as ``ceph.git``
  ``qa/crontab/teuthology-cronjobs`` by branch).
- ``teuthology-nightly-cadence-trigger``: JJB ``timed`` block, ``TZ=Etc/UTC``, ``wait: false``. Timer runs
  **daily** cadence once per **main**, **tentacle**, **squid**, and **umbrella**. Manual runs use the selected
  ``CEPH_BRANCH`` only. Tune ``triggers`` in the YAML.

Scripts and Shaman/suite logic live under ``teuthology-runner/``. Ensure the **teuthology-runner**
job exists in Jenkins (see ``teuthology-runner/config/definitions/teuthology-runner.yml``).
