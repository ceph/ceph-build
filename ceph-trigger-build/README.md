# ceph-trigger-build

This pipeline's role is to:
  1. Be triggered by a git push event
  2. Determine which job or pipeline to use for the actual compile and
     packaging
  3. Build one or more sets of parameters
  4. For each set, trigger a second job or pipeline with those parameters

Parameter sets are constructed in this way:
  1. A set of default values is constructed based on the branch name
  2. The head commit is examined for git trailers
    a. See https://git-scm.com/docs/git-interpret-trailers
  3. If a "CEPH-BUILD-JOB: ceph-dev-pipeline" trailer is found, other parameter
     values are overridden by any trailers matching them

An example set of trailers:

    CEPH-BUILD-JOB: ceph-dev-pipeline
    DISTROS: jammy centos9
    ARCHS: x86_64 arm64

NOTE: During a transitional period, before this can fully replace the legacy
trigger jobs, it will *not* trigger the legacy build jobs if the legacy triggers
are enabled.
