Release Tracker Workflow
========================

A Jenkins pipeline that automates RC (release candidate) testing for Ceph release trackers:

- Resolve or accept a Ceph SHA1 (optional **CEPH_SHA1**; must exist on Shaman).
- Wait for the SHA1 on Shaman, then schedule teuthology suites (all triggered at once, then wait for all).
- Aggregate pass/fail results and post to Redmine (tracker.ceph.com) and/or send email.

No build step: the pipeline relies on Shaman only (SHA1 must already be built and available).

Requirements
------------

- Jenkins agent with label **teuthology-agent** (or set **AGENT_LABEL**); teuthology installed, ``~/.teuthology.yaml``, Shaman/Paddles reachable.
- Credential **redmine-api-key** (or set **REDMINE_CREDENTIAL_ID**) in Jenkins for posting to tracker.ceph.com when **SKIP_TRACKER_UPDATE** is false.

Parameters
----------

- **CEPH_BRANCH** / **CEPH_SHA1**: Branch to resolve SHA1 from, or a specific SHA1 to use (must exist on Shaman).
- **SUITE_LIST_SOURCE**: Path relative to workspace (e.g. ``release-tracker-workflow/config/suites.yaml``) or URL for suite list; empty = use **SUITE_NAME**.
- **SKIP_TRACKER_UPDATE** (default true): Do not post to Redmine.
- **TRACKER_ISSUE_ID**: Redmine issue ID when posting (required when SKIP_TRACKER_UPDATE is false).

Configuration (no hardcodings)
------------------------------

Paths and URLs are parameterized so the same job works across environments:

- **AGENT_LABEL**: Jenkins agent label (default ``teuthology-agent``).
- **TEUTHOLOGY_SCRIPT_DIR** / **TEUTHOLOGY_VIRTUALENV_PATH** / **TEUTHOLOGY_OVERRIDE_YAML**: Teuthology install path, virtualenv, and optional override YAML for teuthology-suite.
- **PULPITO_BASE**: Base URL for Pulpito run links (default ``https://pulpito.ceph.com``).
- **PADDLES_URL**: Paddles base URL for aggregation.
- **REDMINE_CREDENTIAL_ID**: Jenkins credential ID for Redmine API key.
- **SUITE_MACHINE_TYPE**, **SUITE_LIMIT**: Teuthology suite machine type and --limit.
- **SHAMAN_WAIT_TIMEOUT**, **SHAMAN_WAIT_INTERVAL**, **SUITE_WAIT_SLEEP**: Timeouts and sleep for Shaman wait and suite scheduling.

Suite lists
-----------

- ``release-tracker-workflow/config/suites.yaml``: list of teuthology suites to run.

Set **SUITE_LIST_SOURCE** to this path (or a URL) to run multiple suites; all are triggered in parallel, then the pipeline waits for all and aggregates results.
