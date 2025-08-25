ceph-pr-api
===========
The ceph-pr-api job, listed as "ceph API tests" under pull requests in the Ceph repository, 
is automatically triggered for all PRs as part of the CI/CD validation process. 
https://github.com/ceph/ceph

The ceph-api job runs integration tests in a vstart cluster 
(helper script provided by Ceph located in the src directory of the Ceph source tree), 
testing components like RADOS, RBD, RGW, and CephFS. 
The job ensures that PR changes integrate correctly with Ceph’s storage APIs.


ceph-pr-api/config/definitions/ceph-pr-api.yml
==============================================

+-------+       +---------------------+
| Start |------>| GitHub PR Trigger   |
+-------+       | (jenkins test api)  |
                +---------------------+
                        |
                        v
                +---------------------+
                | Validate Trigger    |----No----> +-------+
                | Phrase             |             | End   |
                | (jenkins test api) |             +-------+
                +---------------------+                  ^
                        | Yes                            |
                        v                                |
                +---------------------+                  |
                | Checkout PR Code   |                   |
                | (Git: origin/pr/...) |                 |
                +---------------------+                  |
                        |                                |
                        v                                |
                +---------------------+                  |
                | Set Environment     |                  |
                | (TERM=xterm)       |                   |
                +---------------------+                  |
                        |                                |
                        v                                |
                +---------------------+                  |
                | Run build_utils.sh |                   |
                +---------------------+                  |
                        |                                |
                        v                                |
                +---------------------+                  |
                | Run build.sh       |                   |
                +---------------------+                  |
                        |                                |
                        v                                |
                +---------------------+                  |
                | Run install-backend|                   |
                | -api-test-deps.sh  |                   |
                +---------------------+                  |
                        |                                |
                        v                                |
                +---------------------+                  |
                | Run api.sh         |                   |
                +---------------------+                  |
                        |                                |
                        v                                |
                +---------------------+                  |
                | Archive Logs       |                   |
                | (build/out/*.log)  |                   |
                +---------------------+                  |
                        |                                |
                        v                                |
                +---------------------+                  |
                | Check Build Status |----Aborted----> +-----------------+
                +---------------------+                | Run dpkg       |
                        |                              | cleanup        |
                        |                              +-----------------+
                        |                                 |
                        v                                 |
                +---------------------+                   |
                | Publish Results     |                   |
                | to GitHub          |                    |
                +---------------------+                   |
                        |                                 |
                        v                                 |
                    +-------+                             |
                    | End   |<----------------------------+
                    +-------+


name: ceph-api
project-type: freestyle
defaults: global
concurrent: true
node: huge && bionic && x86_64 && !smithi
display-name: 'ceph: API'
quiet-period: 5
block-downstream: false
block-upstream: false
retry-count: 3

    The job is of type freestyle, which means it is a flexible, general-purpose Jenkins job.
    It inherits global defaults and allows multiple builds to run at the same time (concurrent: true).

    The node field specifies that the job should run on Jenkins agents labeled with huge, bionic, x86_64, and not smithi.
    This ensures the job runs on suitable hardware and operating system (Ubuntu Bionic, 64-bit, large resources, 
    and not on nodes labeled smithi).

    The display-name sets how the job appears in the Jenkins UI as 'ceph: API'. 
    The quiet-period: 5 means the job will wait 5 seconds after being triggered before starting, 
    which can help avoid redundant builds if multiple triggers happen in quick succession.

    Both block-downstream and block-upstream are set to false, so this job will not block related jobs from running. 
    Finally, retry-count: 3 means Jenkins will automatically retry the job up to three times if it fails, 
    which helps to recover from transient errors and increases the reliability of the CI process.

properties:
    - build-discarder:
        days-to-keep: 15
        num-to-keep: 300
        artifact-days-to-keep: -1
        artifact-num-to-keep: -1
    - github:
        url: https://github.com/ceph/ceph/
    - rebuild:
        auto-rebuild: true
    - inject:
        properties-content: |
        TERM=xterm

    properties: section configures several important settings for the ceph-api Jenkins job:

    build-discarder:
    Controls how long Jenkins keeps build records and artifacts. 
    It keeps build records for 15 days or up to 300 builds, 
    and keeps build artifacts indefinitely (no time or number limit, as indicated by -1). 
    This helps manage disk space and ensures old builds are cleaned up automatically.

    github:
    Associates the job with the Ceph GitHub repository at https://github.com/ceph/ceph/.
    This enables integration features such as status reporting and linking builds to pull requests.

    rebuild:
    With auto-rebuild: true, Jenkins can automatically rebuild this job if needed, 
    such as when dependencies change or a user requests a rebuild.

    inject:
    Sets environment variables for the build. 
    Here, it sets TERM=xterm, which ensures that terminal output (such as colored logs) 
    is handled correctly during the build process.

    In summary, these properties help manage build retention, 
    enable GitHub integration, allow for automatic rebuilds, 
    and ensure a consistent build environment for the ceph-api job.

parameters:
    - string:
        name: sha1
        description: "commit id or a refname, like 'origin/pr/72/head'"
    
    parameters: section defines an input parameter for the Jenkins job named ceph-api. 
    It specifies a single string parameter called sha1. 
    The description explains that this parameter should be set to a commit ID or a reference name, 
    such as origin/pr/72/head. This allows the job to be triggered for a specific commit or branch, 
    making it flexible for building and testing different code revisions or pull requests. 
    The value of sha1 is typically used in the source control configuration (scm: section)
    to check out the correct code version for the build and test process.

triggers:
      - github-pull-request:
          cancel-builds-on-update: true
          allow-whitelist-orgs-as-admins: true
          org-list:
            - ceph
          white-list-target-branches:
            - main
            - tentacle
            - squid
            - reef
            - "feature-.*"
          trigger-phrase: 'jenkins test api'
          skip-build-phrase: '^jenkins do not test.*'
          only-trigger-phrase: false
          github-hooks: true
          permit-all: true
          auto-close-on-fail: false
          status-context: "ceph API tests"
          started-status: "running API tests"
          success-status: "ceph API tests succeeded"
          failure-status: "ceph API tests failed"
    
    triggers: section configures how and when the ceph-api Jenkins job is triggered by GitHub pull request activity.

    It uses the github-pull-request trigger, which integrates Jenkins with GitHub PR events. 

    cancel-builds-on-update: true: 
    If a pull request is updated (for example, new commits are pushed), 
    any running builds for that PR are canceled and restarted to ensure only the latest changes are tested.

    allow-whitelist-orgs-as-admins: true: 
    Organizations in the whitelist (here, ceph) are treated as admins for triggering builds.

    org-list: 
    Only pull requests from the ceph organization will trigger builds.

    white-list-target-branches: 
    Only pull requests targeting the listed branches 
    (main, tentacle, squid, reef, or any branch matching feature-.*) will trigger this job.

    trigger-phrase: 'jenkins test api': If a PR comment matches this phrase, it will trigger a build.

    skip-build-phrase: '^jenkins do not test.*': 
    If a PR comment matches this pattern, the build will be skipped.

    only-trigger-phrase: false: 
    Builds can be triggered by PR updates or by the trigger phrase.

    github-hooks: true: 
    Uses GitHub webhooks for real-time triggering.

    permit-all: true: 
    Anyone can trigger builds, not just admins.

    auto-close-on-fail: false: 
    Jenkins will not automatically close PRs if the build fails.

    status-context and related fields: 
    These control the status messages shown on GitHub for this build, 
    providing clear feedback about the state of the API tests.

    In summary, this section ensures that the Jenkins job is automatically and 
    intelligently triggered by relevant PR activity or specific comments, provides clear status updates on GitHub, 
    and manages build concurrency and permissions for the Ceph API test pipeline.

scm:
    - git:
        url: https://github.com/ceph/ceph.git
        branches:
            - origin/pr/${{ghprbPullId}}/merge
        refspec: +refs/pull/${{ghprbPullId}}/*:refs/remotes/origin/pr/${{ghprbPullId}}/*
        browser: auto
        timeout: 20
        skip-tag: true
        shallow-clone: true
        wipe-workspace: true

    scm: section configures how Jenkins checks out the source code for the ceph-api job. 
    It uses the Git plugin to clone the Ceph repository from GitHub.

    The branches field specifies that Jenkins should check out the special merge branch for the pull request, 
    identified by the ghprbPullId parameter. 
    This branch contains the result of merging the pull request into the base branch, 
    ensuring that tests run against the code as it would appear if merged.

    The refspec ensures that all references for the pull request are fetched, 
    making the PR's branches available locally. 
    
    The browser: auto setting allows Jenkins to automatically detect the repository browser for linking purposes. 
    The timeout: 20 sets a 20-minute timeout for Git operations, helping to avoid hanging builds.

    The skip-tag: true option tells Jenkins not to fetch Git tags, which can speed up the checkout process. 
    The shallow-clone: true option makes the clone operation faster and uses less disk 
    space by only fetching the latest history. 
    The wipe-workspace: true option cleans the workspace before checking out the code, 
    preventing issues from leftover files from previous builds.

    In summary, this configuration ensures that Jenkins efficiently and reliably 
    checks out the correct code for the specific pull request being tested, 
    using a clean workspace and optimized Git operations.

builders:
    - shell:
        !include-raw-verbatim:
         - ../../../scripts/build_utils.sh
         - ../../build/build
         - ../../../scripts/dashboard/install-backend-api-test-deps.sh
         - ../../build/api

    builders: section defines the main build steps for the ceph-api Jenkins job. 
    It uses a shell step that sequentially includes and executes several scripts using the
    
    !include-raw-verbatim directive.

    ../../../scripts/build_utils.sh: 
    Sets up the build environment and provides utility functions needed for the build process.

    ../../build/build: 
    Runs the main build logic, which may include compiling code, running checks, or preparing the environment.

    ../../../scripts/dashboard/install-backend-api-test-deps.sh: 
    Installs any backend dependencies required for API testing, 
    ensuring that all necessary packages and tools are available.

    ../../build/api: 
    Executes the API-specific build and test steps, such as running API tests or generating API documentation.
    By chaining these scripts, the job automates the setup, build, dependency installation, 
    and API testing process for each pull request, ensuring consistency and reliability in the CI pipeline.

publishers:
      - postbuildscript:
          builders:
            - role: SLAVE
              build-on:
                  - ABORTED
              build-steps:
                - shell: "sudo dpkg --configure -a"

      - archive:
          artifacts: 'build/out/*.log'
          allow-empty: true
          latest-only: false

    This `publishers:` section defines post-build actions for the `ceph-api` Jenkins job.

    The first publisher, `postbuildscript`, is configured to run only if the build is **aborted**. 
    When this happens, it executes the shell command `sudo dpkg --configure -a` on the build agent. 
    This command is used to repair or complete any interrupted package configuration steps 
    in the Debian package manager (`dpkg`).
    The comment above this section explains that this job is often aborted during an `apt` transaction, 
    which can leave the package database in an inconsistent state. 
    Running this command helps clean up and restore the system to a healthy state for future builds.

    The second publisher, `archive`, tells Jenkins to collect and store any log files 
    matching the pattern `build/out/*.log` after the build completes. 
    The `allow-empty: true` option means the build will not fail if there are no log files to archive, 
    and `latest-only: false` means artifacts from all builds (not just the latest) will be 
    kept according to the job's retention policy.

    In summary, this section ensures that if the job is aborted, 
    the system is cleaned up to prevent future build failures, 
    and that important log files are archived for later inspection and debugging.

wrappers:
    - ansicolor
    - credentials-binding:
        - username-password-separated:
            credential-id: github-readonly-token
            username: GITHUB_USER
            password: GITHUB_PASS

    wrappers: section configures two important features for the ceph-api Jenkins job.

    The first wrapper, ansicolor, enables ANSI color support in the Jenkins build logs. 
    This means that any colored output produced by scripts or tools during the build will be 
    displayed correctly in the Jenkins console, making logs easier to read and debug.

    The second wrapper, credentials-binding, securely injects credentials into the build environment. 
    Specifically, it uses the username-password-separated binding with the credential ID github-readonly-token. 
    This makes the GitHub username available as the environment variable GITHUB_USER and 
    the password or token as GITHUB_PASS.

    This allows scripts and tools in the build process to authenticate with GitHub securely, 
    without exposing sensitive information in the job configuration or logs.

    In summary, this section ensures that build logs are colorized for better readability 
    and that GitHub credentials are securely provided to the build process as environment variables.


ceph-pr-api/build/build
=======================

#!/bin/bash -e

docs_pr_only
container_pr_only
if [[ "$DOCS_ONLY" = true || "$CONTAINER_ONLY" = true ]]; then
    echo "Only the doc/ or container/ dir changed.  No need to run make check or API tests."
    mkdir -p $WORKSPACE/build/out
    echo "File created to avoid Jenkins' Artifact Archiving plugin from hanging" > $WORKSPACE/build/out/mgr.foo.log
    exit 0
fi

n_build_jobs=$(get_nr_build_jobs)
n_test_jobs=$(($(nproc) / 4))
export CHECK_MAKEOPTS="-j${n_test_jobs} -N -Q"
export BUILD_MAKEOPTS="-j${n_build_jobs}"
export FOR_MAKE_CHECK=1
timeout 2h ./src/script/run-make.sh \
        --cmake-args '-DWITH_TESTS=OFF -DENABLE_GIT_VERSION=OFF'
sleep 5
ps -ef | grep ceph || true

    +-------+       +---------------------+
    | Start |------>| Run docs_pr_only   |
    +-------+       +---------------------+
                            |
                            v
                    +---------------------+
                    | Run                |
                    | container_pr_only  |
                    +---------------------+
                            |
                            v
                    +---------------------+
                    | DOCS_ONLY or       |----Yes----> +-------------------------+
                    | CONTAINER_ONLY?    |             | Echo "Only doc/ or      |
                    +---------------------+             | container/ changed"      |
                            |                          | Create mgr.foo.log      |
                            |                          | Exit 0                  |
                            |                          +-------------------------+
                            | No
                            v
                    +-------------------------+
                    | Set n_build_jobs,       |
                    | n_test_jobs,            |
                    | CHECK_MAKEOPTS,         |
                    | BUILD_MAKEOPTS,         |
                    | FOR_MAKE_CHECK         |
                    +-------------------------+
                            |
                            v
                    +-------------------------+
                    | Run run-make.sh        |
                    | (2h timeout, cmake args)|
                    +-------------------------+
                            |
                            v
                    +-------------------------+
                    | Sleep 5 seconds         |
                    +-------------------------+
                            |
                            v
                    +-------------------------+
                    | Check Ceph Processes    |
                    | (ps -ef | grep ceph)    |
                    +-------------------------+
                            |
                            v
                        +-------+
                        | End   |
                        +-------+

    This Bash script is used in the ceph-pr-api Jenkins job to control the build and test process for pull requests. 
    Here’s what it does, step by step:

    Strict error handling:
    #!/bin/bash -e
    The script will exit immediately if any command fails.

    Check for docs or container-only changes:
    It calls the functions docs_pr_only and container_pr_only, which set 
    the variables DOCS_ONLY and CONTAINER_ONLY if the pull request only changes documentation or container files.
    If either variable is true, the script:

    Prints a message saying there’s no need to run tests.
    Creates a dummy log file (mgr.foo.log) to prevent Jenkins’ artifact archiving from hanging due to missing files.
    Exits successfully, skipping the rest of the build.
    Set up parallelism for build and test:

    n_build_jobs=$(get_nr_build_jobs): Determines the number of jobs for building (function defined elsewhere).
    n_test_jobs=$(($(nproc) / 4)): Sets the number of test jobs to a quarter of the available CPU cores.
    Sets CHECK_MAKEOPTS and BUILD_MAKEOPTS environment variables to control parallelism for make commands.
    Run the build:

    Sets FOR_MAKE_CHECK=1 to indicate this is a check build.
    Runs ./src/script/run-make.sh with a 2-hour timeout, passing CMake arguments to disable tests and 
    Git version info.
    Post-build process check:

    Waits 5 seconds.
    Lists any running ceph processes for debugging or cleanup.
    Summary:
    This script efficiently skips unnecessary builds for docs/container-only PRs, 
    configures parallelism for building and testing, runs the main build, and checks for leftover processes, 
    optimizing CI resources and reliability.


ceph-pr-api/build/api
=====================

#!/bin/bash -e
cd src/pybind/mgr/dashboard
timeout 7200 ./run-backend-api-tests.sh

    +-------+       +---------------------+
    | Start |------>| cd src/pybind/mgr/  |
    +-------+       | dashboard           |
                    +---------------------+
                            |
                            v
                    +---------------------+
                    | Run run-backend-   |
                    | api-tests.sh       |
                    | (7200s timeout)    |
                    +---------------------+
                            |
                            v
                        +-------+
                        | End   |
                        +-------+

    This short Bash script is used to run the backend API tests for the Ceph Dashboard component:

    #!/bin/bash -e
    Runs the script with Bash and exits immediately if any command fails.

    cd src/pybind/mgr/dashboard
    Changes the working directory to the dashboard source directory, where the API test script is located.

    timeout 7200 ./run-backend-api-tests.sh
    Executes the run-backend-api-tests.sh script with a timeout of 7200 seconds (2 hours). 
    This script runs the backend API tests for the dashboard.

    Summary:
    The script ensures that the backend API tests for the Ceph Dashboard are run, 
    and will fail if any step fails or if the tests take longer than 2 hours.
