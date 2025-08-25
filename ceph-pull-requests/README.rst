ceph-pull-requests
==================
The ceph-pull-requests job, listed as "make check" under pull requests in the Ceph repository, 
is automatically triggered for all PRs as part of the CI/CD validation process. 
https://github.com/ceph/ceph


ceph-pull-requests/config/definitions/ceph-pull-requests.yml
============================================================

+-------+       +---------------------+
| Start |------>| GitHub PR Trigger   |
+-------+       +---------------------+
                        |
                        v
                +---------------------+
                | Validate Trigger    |----No----> +-------+
                | Phrase             |             | End   |
                | (jenkins test...)  |             +-------+
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
                | Set TERM=xterm     |                   |
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
                | Publish Cobertura  |                   |
                | Report             |                   |
                +---------------------+                  |
                        |                                |
                        v                                |
                +---------------------+               +-----------------+
                | Check Build Status |----Aborted----> | Run kill-tests |
                +---------------------+               +-----------------+
                        |                                |
                        |                                |
                        v                                |
                +---------------------+                  |
                | Publish xUnit      |                   |
                | Results            |                   |
                +---------------------+                  |
                        |                                |
                        v                                |
                +-------+                                |
                | End   |<-------------------------------
                +-------+

name: ceph-pull-requests
project-type: freestyle
defaults: global
concurrent: true
node: huge && bionic && x86_64 && !smithi
display-name: 'ceph: Pull Requests'
quiet-period: 5
block-downstream: false
block-upstream: false
retry-count: 3

    This section defines the basic configuration for the Jenkins job named ceph-pull-requests. 
    The job is of type freestyle, which means it is a flexible, general-purpose Jenkins job. 
    It inherits global defaults and allows multiple builds to run at the same time (concurrent: true).

    The node field specifies that the job should run on Jenkins agents labeled with huge, bionic, 
    x86_64, and not smithi. This ensures the job runs on suitable hardware and operating system 
    (Ubuntu Bionic, 64-bit, 
    large resources, and not on nodes labeled smithi). 
    The comment explains that Bionic is chosen because it supports both Python 2 and Python 3, 
    and all builds should be able to run there.

    The display-name sets how the job appears in the Jenkins UI as 'ceph: Pull Requests'. 
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

    This properties: section configures several important settings for the ceph-pull-requests Jenkins job:

    build-discarder:
    Controls how long Jenkins keeps build records and artifacts. 
    It keeps build records for 15 days or up to 300 builds, 
    and keeps build artifacts indefinitely (no time or number limit, as indicated by -1). This helps manage disk space and ensures old builds are cleaned up automatically.

    github:
    Associates the job with the Ceph GitHub repository at https://github.com/ceph/ceph/. 
    This enables integration features such as status reporting and linking builds to pull requests.

    rebuild:
    With auto-rebuild: true, Jenkins can automatically rebuild this job if needed, 
    such as when dependencies change or a user requests a rebuild.

    inject:
    Sets environment variables for the build. Here, it sets TERM=xterm, 
    which ensures that terminal output (such as colored logs) is handled correctly during the build process.

    Summary:
    These properties help manage build retention, enable GitHub integration, 
    allow for automatic rebuilds, and ensure a consistent build environment for the ceph-pull-requests job.

parameters:
      - string:
          name: ghprbPullId
          description: "the GitHub pull id, like '72' in 'ceph/pull/72'"

    This parameters: section defines an input parameter for the Jenkins job named ceph-pull-requests. 
    It specifies a single string parameter called ghprbPullId. 
    The description explains that this parameter should be set to the GitHub pull request ID, 
    such as 72 for ceph/pull/72.

    This parameter allows Jenkins to know which pull request to build and test. 
    Its value is used in other parts of the job configuration, such as checking out the correct 
    branch from GitHub (using the PR ID in the scm section). 
    This makes the job flexible and able to respond to different pull requests dynamically.

triggers:
      - github-pull-request:
          cancel-builds-on-update: true
          allow-whitelist-orgs-as-admins: true
          org-list:
            - ceph
          trigger-phrase: 'jenkins test make check'
          skip-build-phrase: '^jenkins do not test.*'
          only-trigger-phrase: false
          github-hooks: true
          permit-all: true
          auto-close-on-fail: false
          status-context: "make check"
          started-status: "running make check"
          success-status: "make check succeeded"
          failure-status: "make check failed"

    This triggers: section configures how the ceph-pull-requests Jenkins job is automatically 
    started in response to GitHub pull request activity. It uses the github-pull-request trigger, 
    which integrates Jenkins with GitHub PR events. Here’s what each option does:

    cancel-builds-on-update: true
    If a pull request is updated (for example, new commits are pushed), 
    any running builds for that PR are canceled and restarted. 
    This ensures that only the latest changes are tested.

    allow-whitelist-orgs-as-admins: true
    Organizations listed in org-list (here, ceph) are treated as admins for triggering builds.

    org-list
    Only pull requests from the ceph organization will trigger builds.

    trigger-phrase: 'jenkins test make check'
    If a PR comment matches this phrase, it will trigger a build. 
    This allows contributors to manually request a build by commenting this phrase.

    skip-build-phrase: '^jenkins do not test.*'
    If a PR comment matches this pattern, the build will be skipped. 
    This is useful for contributors who want to prevent unnecessary builds.

    only-trigger-phrase: false
    Builds can be triggered by PR updates or by the trigger phrase, not just the phrase alone.

    github-hooks: true
    Enables real-time triggering using GitHub webhooks, 
    so builds start as soon as relevant events happen on GitHub.

    permit-all: true
    Anyone can trigger builds, not just admins or whitelisted users.

    auto-close-on-fail: false
    Jenkins will not automatically close pull requests if the build fails.

    status-context, started-status, success-status, failure-status
    These fields control the status messages shown on GitHub for this build. 
    For example, when the build starts, GitHub will show "running make check"; 
    if it succeeds, "make check succeeded"; and if it fails, "make check failed".

    Summary:
    This configuration ensures that the Jenkins job is automatically and 
    intelligently triggered by PR activity or specific comments, 
    provides clear status updates on GitHub, and manages build concurrency and permissions for 
    the Ceph pull request testing pipeline.

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
          honor-refspec: true
          wipe-workspace: true

    This scm: section configures how Jenkins checks out the source code for the ceph-pull-requests job using Git. 
    Here’s what each setting does:

    url:
    Specifies the GitHub repository to clone: https://github.com/ceph/ceph.git.

    branches:
    Tells Jenkins to check out the special merge branch for the pull request, 
    using the parameter ${{ghprbPullId}}. This branch (origin/pr/${{ghprbPullId}}/merge) contains 
    the result of merging the PR into the base branch, ensuring tests run against what would actually be merged.

    refspec:
    +refs/pull/${{ghprbPullId}}/*:refs/remotes/origin/pr/${{ghprbPullId}}/*
    This fetches all references for the given pull request, making the PR’s branches available locally.

    browser: auto:
    Lets Jenkins automatically detect the repository browser for linking purposes.

    timeout: 20:
    Sets a 20-minute timeout for Git operations, preventing jobs from hanging indefinitely.

    skip-tag: true:
    Tells Jenkins not to fetch Git tags, which can speed up the checkout process.

    shallow-clone: true:
    Performs a shallow clone, fetching only the latest history to save time and disk space.

    honor-refspec: true:
    Ensures the refspec is used exactly as specified.

    wipe-workspace: true:
    Cleans the workspace before checking out the code, preventing issues from leftover files from previous builds.

    Summary:
    This configuration ensures Jenkins efficiently and reliably checks out the correct code for 
    the specific pull request being tested, using a clean workspace and optimized Git operations. 
    It helps guarantee that the build and tests are run against the exact code that would be merged 
    if the PR is accepted.

builders:
    - shell:
        !include-raw-verbatim:
          - ../../../scripts/build_utils.sh
          - ../../build/build

    This builders: section defines the main build steps for the ceph-pull-requests Jenkins job. It uses a shell build step that sequentially includes and executes two scripts using the !include-raw-verbatim directive:

    ../../../scripts/build_utils.sh: This script sets up the build environment and provides utility 
    functions needed for the build process.

    ../../build/build: This script contains the main build and test logic, 
    such as compiling the code, running checks, and executing tests for the pull request.

    By chaining these scripts, the job ensures that the environment is properly prepared 
    and that the main build and test procedures are executed consistently for every pull request. 
    This approach helps automate the CI process, ensuring reliability and repeatability in the build pipeline.

publishers:
      - cobertura:
          report-file: "src/pybind/mgr/dashboard/frontend/coverage/cobertura-coverage.xml"
          only-stable: "true"
          health-auto-update: "false"
          stability-auto-update: "false"
          zoom-coverage-chart: "true"
          source-encoding: "Big5"
          targets:
            - files:
                healthy: 10
                unhealthy: 20
                failing: 30
            - method:
                healthy: 10
                unhealthy: 20
                failing: 30
      - postbuildscript:
          builders:
            - role: SLAVE
              build-on:
                - ABORTED
              build-steps:
                - shell:
                    !include-raw-verbatim:
                      - ../../build/kill-tests
      - xunit:
          thresholds:
            - failed:
                unstable: 0
                unstablenew: 0
                failure: 0
                failurenew: 0
          types:
            - ctest:
                pattern: "build/Testing/**/Test.xml"
                skip-if-no-test-files: true

    This publishers: section defines the post-build actions for the ceph-pull-requests Jenkins job. 
    It includes three main publishers:

    Cobertura
    This publisher collects and publishes code coverage reports using the Cobertura plugin. 
    It looks for the coverage report at src/pybind/mgr/dashboard/frontend/coverage/cobertura-coverage.xml. 
    The configuration specifies that coverage is only published for stable builds, disables automatic 
    health and stability updates, enables zoom on the coverage chart, and sets the source encoding to "Big5". 
    The targets section defines thresholds for code coverage health based on files and methods, 
    with specific values for what is considered healthy, unhealthy, or failing.

    Postbuildscript
    This publisher runs additional scripts if the build is aborted. Under builders, 
    it specifies that on the build agent (role: SLAVE), if the build is aborted (build-on: ABORTED), 
    Jenkins should execute the shell script found at ../../build/kill-tests. 
    This script is responsible for cleaning up any lingering test processes that 
    may not have been terminated when the build was stopped, helping to keep the build environment clean.

    xUnit
    This publisher collects and publishes test results using the xUnit plugin.
    It is configured to look for CTest result files matching the pattern build/Testing/**/Test.xml.
    The thresholds section sets all failure and instability thresholds to zero, 
    meaning any test failure will be reported.
    The skip-if-no-test-files: true option ensures that the publisher will not fail the build if 
    no test result files are found.

    Summary:
    Together, these publishers ensure that after each build, Jenkins will:

    Publish code coverage results,
    Clean up test processes if the build is aborted,
    Publish test results from CTest.
    This setup helps maintain code quality, provides clear feedback on test and coverage status, 
    and ensures the build environment remains stable and clean.

wrappers:
      - ansicolor
      - credentials-binding:
          - username-password-separated:
              credential-id: github-readonly-token
              username: GITHUB_USER
              password: GITHUB_PASS

    This wrappers: section configures additional features for the ceph-pull-requests Jenkins job:

    ansicolor:
    Enables ANSI color support in the Jenkins build logs. 
    This means that any colored output from scripts or tools will be displayed correctly in the Jenkins console, 
    making logs easier to read and debug.

    credentials-binding:
    Securely injects credentials into the build environment.

    The username-password-separated binding uses the credential with ID github-readonly-token 
    and exposes the username as the environment variable GITHUB_USER and the password/token as GITHUB_PASS.
    This allows scripts and tools in the build process to authenticate with GitHub securely, 
    without exposing sensitive information in the job configuration or logs.
    Summary:
    This section ensures that build logs are colorized for better readability and that GitHub 
    credentials are securely provided to the build process as environment variables.

ceph-pull-requests/build/build
==============================

#!/bin/bash -ex

docs_pr_only
container_pr_only
if [[ "$DOCS_ONLY" = true || "$CONTAINER_ONLY" = true ]]; then
    echo "Only the doc/ or container/ dir changed.  No need to run make check."
    exit 0
fi

export NPROC=$(nproc)
export WITH_CRIMSON=true
export WITH_RBD_RWL=true
timeout 3h ./run-make-check.sh
sleep 5
ps -ef | grep -v jnlp | grep ceph || true

+-------+       +-----------------+
| Start |------>| Run             |
+-------+       | docs_pr_only    |
                +-----------------+
                        |
                        v
                +------------------+
                | Run              |
                | container_pr_only|
                +------------------+
                        |
                        v
                +-----------------+             +-------------------------+
                | DOCS_ONLY or    |----Yes----> | Echo "Only doc/ or      |
                | CONTAINER_ONLY? |             | container/ changed"     |
                +-----------------+             | Exit 0                  |
                        |                       +-------------------------+
                        |                     
                        | No
                        v
                +-------------------------+
                | Set NPROC, CRIMSON,     |
                | RBD_RWL                 |
                +-------------------------+
                        |
                        v
                +-------------------------+
                | Run run-make-check.sh   |
                | (3h timeout)            |
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

    This Bash script is the main build and test runner for the ceph-pull-requests Jenkins job. 
    Here’s what it does:

    Strict error handling:
    #!/bin/bash -ex
    The script will print each command before running it (-x) and exit immediately if any command fails (-e).

    Check for docs or container-only changes:
    It calls the functions docs_pr_only and container_pr_only, 
    which set the variables DOCS_ONLY and CONTAINER_ONLY if the pull request only 
    changes documentation or container files.
    If either variable is true, the script prints a message and exits, 
    skipping the build and tests since they are unnecessary for such changes.

    Set environment variables:
    NPROC=$(nproc): Sets the number of available CPU cores for parallel builds.
    WITH_CRIMSON=true and WITH_RBD_RWL=true: Enable specific Ceph features for the build and tests.
    Run the main test suite:

    Runs ./run-make-check.sh with a 3-hour timeout. This script builds Ceph and runs its test suite.

    Post-test process check:
    Waits 5 seconds.
    Lists any running ceph processes (excluding Jenkins agent processes) for debugging or cleanup purposes.

    Summary:
    This script skips unnecessary builds for docs/container-only PRs, sets up the environment, 
    runs the main Ceph test suite, and checks for leftover Ceph processes after the tests.

ceph-pull-requests/build/kill-tests
===================================

# if ctest is still running, get its pid, otherwise we are done.
ctest_pid=$(pgrep ctest) || exit 0
# the parent process of ctest should have been terminated, but this might not be true when
# it comes to some of its descendant processes, for instance, unittest-seastar-messenger
ctest_pgid=$(ps --no-headers --format 'pgid:1' --pid $ctest_pid)
kill -SIGTERM -- -"$ctest_pgid"
# try harder
for seconds in 0 1 1 2 3; do
    sleep $seconds
    if pgrep --pgroup $ctest_pgid > /dev/null; then
        # kill only if we've waited for a while
        if test $seconds != 0; then
            pgrep --pgroup $ctest_pgid
            echo 'try harder'
            kill -SIGKILL -- -"$ctest_pgid"
        fi
    else
        echo 'killed'
        break
    fi
done

+-------+       +---------------------+
| Start |------>| Get ctest PID      |
+-------+       | (pgrep ctest)      |
                +---------------------+
                        |
                        v
                +---------------------+
                | ctest Running?     |----No----> +-------+
                | (PID found?)       |            | End   |
                +---------------------+           +-------+
                        | Yes
                        v
                +---------------------+
                | Get ctest PGID     |
                | (ps --format pgid) |
                +---------------------+
                        |
                        v
                +---------------------+
                | Send SIGTERM to    |
                | PGID               |
                +---------------------+
                        |
                        v
                +---------------------+
                | Loop: seconds      |
                | (0,1,1,2,3)       |
                +---------------------+
                        |
                        v
                +---------------------+
                | Sleep $seconds      |
                +---------------------+
                        |
                        v
                +---------------------+
                | Processes in PGID  |----No----> +-----------------+
                | Still Running?     |             | Echo "killed"  |
                | (pgrep --pgroup)  |             | Break Loop     |
                +---------------------+             +-----------------+
                        | Yes                          |
                        v                              |
                +---------------------+                |
                | seconds != 0?      |----No----------+
                +---------------------+                |
                        | Yes                          |
                        v                              |
                +---------------------+                |
                | Echo "try harder"   |                |
                | Send SIGKILL to     |                |
                | PGID               |                 |
                +---------------------+                |
                        |                              |
                        v                              |
                +---------------------+                |
                | Next Loop Iteration |----------------+
                +---------------------+
                        |
                        v
                    +-------+
                    | End   |
                    +-------+

    This Bash script is designed to clean up any lingering test processes when a Jenkins job is aborted or canceled, 
    specifically for jobs that use ctest to run tests.

    Find the ctest process:
    It uses pgrep ctest to find the process ID (pid) of any running ctest process. If no ctest process is found, 
    the script exits immediately.

    Get the process group ID:
    It retrieves the process group ID (pgid) for the ctest process. 
    This allows the script to target not just ctest itself, but also any child processes it may have spawned.

    Send SIGTERM to the process group:
    The script sends a SIGTERM signal to the entire process group, 
    asking all processes in the group to terminate gracefully.

    Wait and escalate if needed:
    It enters a loop, waiting for increasing amounts of time (0, 1, 1, 2, 3 seconds). 
    After each wait, it checks if any processes in the group are still running:

    If processes remain and the script has waited (i.e., not on the first iteration), 
    it prints the remaining process IDs, prints "try harder", 
    and sends a SIGKILL signal to forcefully terminate all processes in the group.
    If no processes remain, it prints "killed" and exits the loop.

    Summary:
    This script ensures that all test processes started by ctest are properly 
    terminated when a Jenkins job is aborted, preventing orphaned or lingering processes 
    that could interfere with future builds or consume system resources.