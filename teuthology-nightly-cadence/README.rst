teuthology-nightly-cadence
===========================

Thin Jenkins jobs that expand **daily/weekly cadence** locally into **SUITE_RUNS_JSON** (partition /
subset per suite) and invoke **teuthology-runner**.

- ``teuthology-nightly-cadence``: builds JSON from ``cadenceSteps`` / day-of-year in this folder's Jenkinsfile, then triggers the runner job (default ``teuthology-runner``; set **TEUTHOLOGY_RUNNER_JOB_NAME** for a test copy).
- ``teuthology-nightly-cadence-trigger``: JJB ``timed`` block with ``TZ=Etc/UTC`` (same pattern as
  ``ceph-dev-cron``). Schedules echo ``qa/crontab/teuthology-cronjobs``: weekday **06:00** UTC → **daily**
  cadence; **Sunday 20:00** UTC → **weekly** cadence (cf. ``00 20 * * 0`` weekly main runs there).
  ``wait: false``. Edit ``triggers`` in the YAML to tune times.

Scripts and Shaman/suite logic live under ``teuthology-runner/``. Ensure the **teuthology-runner**
job exists in Jenkins (see ``teuthology-runner/config/definitions/teuthology-runner.yml``).
