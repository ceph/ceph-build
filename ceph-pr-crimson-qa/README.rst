ceph-pr-crimson-qa
==================

Jenkins pipeline that schedules a **crimson-rados** teuthology suite run
against a ``ceph.git`` pull request.

Trigger
-------

Post a comment on any open ceph/ceph PR::

    jenkins test crimson-qa

The generic-webhook-trigger plugin receives the ``issue_comment`` event,
matches the phrase, and fires the ``ceph-pr-crimson-qa`` pipeline.

Manual runs
-----------

Build the job directly from Jenkins and supply ``ghprbPullId`` (the PR number).

How it works
------------

1. **Resolve PR** — fetches the PR from the GitHub API to obtain the head SHA
   and target branch.  Aborts immediately if the PR is not open.
2. **Authorize** — verifies that the commenter (or the PR author for manual
   runs) has *write* or *admin* permission on ``ceph/ceph`` (same bar as
   ``ceph-pr-pipeline-trigger``).  Falls back to org membership if the
   credentials lack collaborator-read scope, and logs a loud warning.
3. **Post pending status** — writes a ``crimson-qa`` commit status (``pending``)
   on the PR head SHA.
4. **Trigger teuthology-runner** — delegates to the shared ``teuthology-runner``
   job with:

   - ``CEPH_SHA1`` = PR head SHA (Shaman wait is skipped: ``SKIP_SHAMAN_WAIT=true``)
   - ``CEPH_BRANCH`` = PR target branch (for ``teuthology-suite`` version selection)
   - ``SUITE_RUNS_JSON`` = ``[{"suite":"crimson-rados","priority":"101","forcePriority":true,"flavor":"debug"}]``

   The PR head must already have packages on Shaman, i.e. the same commits
   pushed to ``ceph-ci.git`` and built.  Otherwise ``teuthology-suite`` fails
   and the status goes red.

5. **Post final status** — updates the ``crimson-qa`` commit status to
   ``success`` once the run is scheduled, or ``failure`` if scheduling failed.
   The run's own result is not reported back.

Requirements
------------

Jenkins jobs
  - ``teuthology-runner`` (``teuthology-runner/config/definitions/teuthology-runner.yml``)

Credentials
  - ``github-status-check-token`` — username/password credential with
    *repo:status* and *read:org* scopes on ``ceph/ceph``
    (shared with ``ceph-pr-pipeline-trigger``).

Webhook
  None to add.  The job shares the ``ceph-pr-pipeline-trigger`` token, so the
  existing ``ceph/ceph`` webhook (which already sends ``issue_comment``
  events) fires it; the job's own regex filter keeps every other comment out.

Parameters
----------

=================================  ================  ==========================================
Parameter                          Default           Description
=================================  ================  ==========================================
``ghprbPullId``                    *(webhook)*       PR number; set automatically or manually.
``CEPH_BUILD_BRANCH``              ``main``          ceph-build branch for the Jenkinsfile.
``TEUTHOLOGY_RUNNER_JOB_NAME``     ``teuthology-runner``  Runner job name.
``SUITE_MACHINE_TYPE``             ``trial``         ``teuthology-suite --machine-type``.
``TEUTHOLOGY_SUITE_NEWEST``        ````              ``teuthology-suite --newest`` (empty = omit).
``TEUTHOLOGY_REPO_URL``            upstream GitHub   Teuthology repo to clone.
``TEUTHOLOGY_BRANCH``              ``main``          Teuthology branch.
``SUITE_REPO``                     ceph/ceph.git     ``teuthology-suite --suite-repo``.
``PADDLES_URL``                    *(from config)*   Optional Paddles override.
``PULPITO_BASE``                   pulpito.ceph.com  Pulpito base URL.
=================================  ================  ==========================================

Files
-----

::

    ceph-pr-crimson-qa/
    ├── build/
    │   └── Jenkinsfile          # Pipeline logic
    ├── config/
    │   └── definitions/
    │       └── ceph-pr-crimson-qa.yml   # JJB job definition
    └── README.rst               # This file
