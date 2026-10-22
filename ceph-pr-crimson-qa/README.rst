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
   - ``SUITE_RUNS_JSON`` = ``[{"suite":"crimson-rados","priority":"101","forcePriority":true}]``

5. **Post final status** — updates the ``crimson-qa`` commit status to
   ``success`` or ``failure`` based on teuthology-runner's outcome.

Requirements
------------

Jenkins jobs
  - ``teuthology-runner`` (``teuthology-runner/config/definitions/teuthology-runner.yml``)

Credentials
  - ``github-status-check-token`` — username/password credential with
    *repo:status* and *read:org* scopes on ``ceph/ceph``
    (shared with ``ceph-pr-pipeline-trigger``).
  - ``pr-crimson-qa-trigger-token`` — secret-text credential holding the
    generic-webhook-trigger token ``ceph-pr-crimson-qa``.

Webhook
  Add the ``issue_comment`` event to the repo (or org) webhook that already
  points at::

      https://jenkins.ceph.com/generic-webhook-trigger/invoke?token=ceph-pr-crimson-qa

  If no such webhook exists yet, create one at
  ``https://github.com/ceph/ceph/settings/hooks`` with:

  - Payload URL: above URL
  - Content type: ``application/json``
  - Events: *Issue comments*

Parameters
----------

=================================  ================  ==========================================
Parameter                          Default           Description
=================================  ================  ==========================================
``ghprbPullId``                    *(webhook)*       PR number; set automatically or manually.
``CEPH_BUILD_BRANCH``              ``main``          ceph-build branch for the Jenkinsfile.
``TEUTHOLOGY_RUNNER_JOB_NAME``     ``teuthology-runner``  Runner job name.
``SUITE_MACHINE_TYPE``             ``trial``         ``teuthology-suite --machine-type``.
``TEUTHOLOGY_SUITE_NEWEST``        ``100``           ``teuthology-suite --newest`` (empty = omit).
``TEUTHOLOGY_REPO_URL``            upstream GitHub   Teuthology repo to clone.
``TEUTHOLOGY_BRANCH``              ``main``          Teuthology branch.
``SUITE_REPO``                     ceph/ceph.git     ``teuthology-suite --suite-repo``.
``PADDLES_URL``                    *(from config)*   Optional Paddles override.
``PULPITO_BASE``                   pulpito.ceph.com  Pulpito base URL.
``WAIT_FOR_RUNS``                  ``false``         Forward to teuthology-runner.
``RUN_AGGREGATE``                  ``false``         Forward to teuthology-runner.
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
