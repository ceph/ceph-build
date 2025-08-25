ceph-windows-pull-requests
==========================
The ceph-windows-pull-requests job, listed as "ceph windows tests" under pull requests in the Ceph repository, 
is automatically triggered for all PRs as part of the CI/CD validation process. 
https://github.com/ceph/ceph

The ceph-windows-pull-requests job validates Ceph PRs by running tests on Windows platforms, 
which is critical for ensuring cross-platform compatibility of Ceph, 
a distributed object, block, and file storage system.

ceph-windows-pull-requests/config/definitions/ceph-windows-pull-requests.yml
============================================================================

+-------+       +---------------------+
| Start |------>| GitHub PR Trigger   |
+-------+       | (jenkins test windows)|
                +---------------------+
                        |
                        v
                +---------------------+
                | Validate Trigger    |----No----> +-------+
                | Phrase             |             | End   |
                | (jenkins test windows)|          +-------+
                +---------------------+                 
                        | Yes                           
                        v                               
                +---------------------+                 
                | Checkout PR Code   |                  
                | (Git: ceph/)       |                  
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                
                | Set TERM=xterm     |                  
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                 
                | Run build_utils.sh |                 
                +---------------------+                 
                        |                              
                        v                               
                +---------------------+                 
                | Run check_docs_pr_only|               
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                 
                | Setup libvirt      |                  
                +---------------------+                 
                        |                               
                        v                              
                +---------------------+                 
                | Setup Ubuntu VM    |                  
                +---------------------+                
                        |                               
                        v                               
                +---------------------+                 
                | Run win32_build.sh |                  
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                 
                | Cleanup Ubuntu VM  |                  
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                 
                | Setup Ubuntu VM    |                  
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                 
                | Setup Windows VM   |                  
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                 
                | Setup Ceph vstart  |                  
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                 
                | Run run_tests.sh   |                  
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                
                | Archive Artifacts  |                  
                | (artifacts/**)     |                
                +---------------------+                 
                        |                              
                        v                              
                +---------------------+                 
                | Run cleanup.sh     |                  
                | (on all statuses)  |                 
                +---------------------+                 
                        |                               
                        v                               
                +---------------------+                 
                | Publish Results     |                 
                | to GitHub          |                 
                +---------------------+                 
                        |                               
                        v                               
                    +-------+
                    | End   |
                    +-------+

name: ceph-windows-pull-requests
project-type: freestyle
defaults: global
concurrent: true
node: amd64 && focal && libvirt && windows
display-name: 'ceph-windows: Pull Requests'
quiet-period: 5
block-downstream: false
block-upstream: false
retry-count: 3

    name: The job is called ceph-windows-pull-requests.
    project-type: freestyle: This is a general-purpose Jenkins job that can be customized 
    with various build and post-build steps.
    defaults: global: Inherits global default settings for Jenkins jobs.
    concurrent: true: Allows multiple builds of this job to run at the same time.
    node: amd64 && focal && libvirt && windows: Restricts the job to run only on 
    Jenkins agents labeled with all these tags, ensuring it runs in an environment 
    suitable for building and testing Ceph on Windows using virtualization.
    display-name: Sets how the job appears in the Jenkins UI.
    quiet-period: 5: Waits 5 seconds after being triggered before starting, 
    which can help avoid redundant builds if multiple triggers happen in quick succession.
    block-downstream: false and block-upstream: false: The job does not block related jobs from running.
    retry-count: 3: Jenkins will automatically retry the job up to three times if it fails, increasing reliability.

properties:
      - build-discarder:
          days-to-keep: 15
          num-to-keep: 300
          artifact-days-to-keep: 15
          artifact-num-to-keep: 100
      - github:
          url: https://github.com/ceph/ceph/
      - rebuild:
          auto-rebuild: true
      - inject:
          properties-content: |
            TERM=xterm
    
    build-discarder: Keeps build records for 15 days or up to 300 builds, 
    and build artifacts for 15 days or up to 100 artifacts, helping manage disk space.

    github: Associates the job with the Ceph GitHub repository, 
    enabling integration features like status reporting.

    rebuild: With auto-rebuild: true, Jenkins can automatically rebuild this job if needed.

    inject: Sets the environment variable TERM=xterm for the build, 
    ensuring proper terminal emulation for colored output.

parameters:
    - string:
        name: ghprbPullId
        description: "The GitHub pull request id, like '72' in 'ceph/pull/72'"

    it specifies a single string parameter named ghprbPullId. 
    The description explains that this parameter should be set to the GitHub pull request ID

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
          trigger-phrase: 'jenkins test windows'
          skip-build-phrase: '^jenkins do not test.*'
          only-trigger-phrase: false
          github-hooks: true
          permit-all: true
          auto-close-on-fail: false
          status-context: "ceph windows tests"
          started-status: "running ceph windows tests"
          success-status: "ceph windows tests succeeded"
          failure-status: "ceph windows tests failed"

    This triggers: section configures how the ceph-windows-pull-requests Jenkins job is 
    automatically started in response to GitHub pull request activity. It uses the github-pull-request trigger, 
    which integrates Jenkins with GitHub PR events. 

    cancel-builds-on-update: true
    If a pull request is updated (for example, new commits are pushed), 
    any running builds for that PR are canceled and restarted. This ensures that only the 
    latest changes are tested.

    allow-whitelist-orgs-as-admins: true
    Organizations listed in org-list (here, ceph) are treated as admins for triggering builds.

    org-list
    Only pull requests from the ceph organization will trigger builds.

    white-list-target-branches
    Only pull requests targeting the listed branches (main, tentacle, squid, reef) will trigger this job.

    trigger-phrase: 'jenkins test windows'
    If a PR comment matches this phrase, it will trigger a build. 
    This allows contributors to manually request a build by commenting this phrase.

    skip-build-phrase: '^jenkins do not test.*'
    If a PR comment matches this pattern, the build will be skipped. 
    This is useful for contributors who want to prevent unnecessary builds.

    only-trigger-phrase: false
    Builds can be triggered by PR updates or by the trigger phrase, not just the phrase alone.

    github-hooks: true
    Enables real-time triggering using GitHub webhooks, so builds start as soon as 
    relevant events happen on GitHub.

    permit-all: true
    Anyone can trigger builds, not just admins or whitelisted users.

    auto-close-on-fail: false
    Jenkins will not automatically close pull requests if the build fails.

    status-context, started-status, success-status, failure-status
    These fields control the status messages shown on GitHub for this build. 
    For example, when the build starts, GitHub will show "running ceph windows tests"; 
    if it succeeds, "ceph windows tests succeeded"; and if it fails, "ceph windows tests failed".

    Summary:
    This configuration ensures that the Jenkins job is automatically and intelligently triggered by 
    PR activity or specific comments, provides clear status updates on GitHub, 
    and manages build concurrency and permissions for the Ceph Windows pull request testing pipeline.

scm:
      - git:
          url: https://github.com/ceph/ceph.git
          branches:
            - origin/pr/${{ghprbPullId}}/merge
          refspec: +refs/pull/${{ghprbPullId}}/*:refs/remotes/origin/pr/${{ghprbPullId}}/*
          browser: auto
          timeout: 20
          do-not-fetch-tags: true
          shallow-clone: true
          honor-refspec: true
          wipe-workspace: true
          basedir: ceph
   
    This scm: section configures how Jenkins checks out the source code 
    for the ceph-windows-pull-requests job using Git

    url:
    Specifies the GitHub repository to clone: https://github.com/ceph/ceph.git.

    branches:
    Tells Jenkins to check out the special merge branch for the pull request, 
    using the parameter ${{ghprbPullId}}. This branch (origin/pr/${{ghprbPullId}}/merge) 
    contains the result of merging the PR into the base branch, 
    ensuring tests run against what would actually be merged.

    refspec:
    +refs/pull/${{ghprbPullId}}/*:refs/remotes/origin/pr/${{ghprbPullId}}/*
    This fetches all references for the given pull request, making the PR’s branches available locally.

    browser: auto:
    Lets Jenkins automatically detect the repository browser for linking purposes.

    timeout: 20:
    Sets a 20-minute timeout for Git operations, preventing jobs from hanging indefinitely.

    do-not-fetch-tags: true:
    Tells Jenkins not to fetch Git tags, which can speed up the checkout process.

    shallow-clone: true:
    Performs a shallow clone, fetching only the latest history to save time and disk space.

    honor-refspec: true:
    Ensures the refspec is used exactly as specified.

    wipe-workspace: true:
    Cleans the workspace before checking out the code, 
    preventing issues from leftover files from previous builds.

    basedir: ceph:
    Checks out the repository into a subdirectory named ceph within the workspace.

    Summary:
    This configuration ensures Jenkins efficiently and reliably checks out 
    the correct code for the specific pull request being tested, using a clean workspace 
    and optimized Git operations. It helps guarantee that the build and tests are run against 
    the exact code that would be merged if the PR is accepted.

builders:
    - shell:
        !include-raw-verbatim:
          - ../../../scripts/build_utils.sh
          - ../../build/check_docs_pr_only
          - ../../../scripts/ceph-windows/setup_libvirt
          - ../../../scripts/ceph-windows/setup_libvirt_ubuntu_vm
          - ../../../scripts/ceph-windows/win32_build
          - ../../../scripts/ceph-windows/cleanup_libvirt_ubuntu_vm
          - ../../../scripts/ceph-windows/setup_libvirt_ubuntu_vm
          - ../../../scripts/ceph-windows/setup_libvirt_windows_vm
          - ../../../scripts/ceph-windows/setup_ceph_vstart
          - ../../../scripts/ceph-windows/run_tests

    This builders: section defines the main build steps for the ceph-windows-pull-requests Jenkins job. 
    It uses a shell step that sequentially includes and executes a series of scripts 
    using the !include-raw-verbatim directive. 

    build_utils.sh: Sets up the build environment and provides utility functions.

    check_docs_pr_only: Checks if the pull request only affects documentation. 
    If so, the job can exit early, skipping unnecessary builds and tests.

    setup_libvirt: Prepares the libvirt virtualization environment, 
    which is needed for running virtual machines during the build and test process.

    setup_libvirt_ubuntu_vm: Sets up an Ubuntu virtual machine using libvirt, 
    which may be used for cross-compilation or as part of the test infrastructure.

    win32_build: Performs the actual build of Ceph for Windows.

    cleanup_libvirt_ubuntu_vm: Cleans up the Ubuntu VM after use to free resources 
    and ensure a clean environment for subsequent builds.

    setup_libvirt_ubuntu_vm (again): Ensures the Ubuntu VM is ready, 
    possibly for further steps or as a safety measure.

    setup_libvirt_windows_vm: Sets up a Windows VM using libvirt, 
    where the Windows-specific build and tests will run.

    setup_ceph_vstart: Prepares the Ceph cluster environment for testing, 
    likely using the vstart script to launch a test cluster.

    run_tests: Executes the test suite on the built Windows binaries.

    Summary:
    This sequence automates the full lifecycle of building and testing Ceph on Windows: 
    it sets up the environment, builds the code, prepares and manages virtual machines, 
    runs tests, and ensures proper cleanup. This approach ensures consistency, reliability,
    and resource efficiency for every pull request targeting Windows support.

 publishers:
      - archive:
          artifacts: 'artifacts/**'
          allow-empty: true
          latest-only: false

      - postbuildscript:
          builders:
            - role: SLAVE
              build-on:
                - SUCCESS
                - UNSTABLE
                - FAILURE
                - ABORTED
              build-steps:
                - shell:
                    !include-raw-verbatim:
                      - ../../../scripts/build_utils.sh
                      - ../../../scripts/ceph-windows/cleanup

    This publishers: section defines post-build actions for the ceph-windows-pull-requests Jenkins job:

    archive:
    This step tells Jenkins to collect and store any files matching the pattern artifacts/** 
    after the build completes.

    allow-empty: true means the build will not fail if there are no artifacts to archive.
    latest-only: false means artifacts from all builds (not just the latest)
    will be kept according to the job's retention policy.
    postbuildscript: This step runs additional scripts after the build, regardless of the build result 
    (SUCCESS, UNSTABLE, FAILURE, or ABORTED).

    Under builders, it specifies a shell step that will execute on the build agent (role: SLAVE).
    The shell step uses !include-raw-verbatim to include and execute the contents of two scripts:
        ../../../scripts/build_utils.sh (for environment setup and utility functions)
        ../../../scripts/ceph-windows/cleanup (to clean up resources, such as virtual machines or temporary files, 
        used during the build)

    Summary:
    This configuration ensures that build artifacts are always archived for later inspection and 
    that cleanup scripts are always run after the build, regardless of the build outcome. 
    This helps keep the build environment clean and reliable for future runs.

wrappers:
      - ansicolor
      - credentials-binding:
          - file:
              credential-id: ceph_win_ci_private_key
              variable: CEPH_WIN_CI_KEY
          - username-password-separated:
              credential-id: github-readonly-token
              username: GITHUB_USER
              password: GITHUB_PASS

    This wrappers: section configures extra features and secure environment settings for the 
    ceph-windows-pull-requests Jenkins job:

    ansicolor:
    Enables ANSI color support in the Jenkins build logs, so colored output from scripts and tools is displayed correctly in the Jenkins console, making logs easier to read.

    credentials-binding:
    Securely injects credentials into the build environment:

    The file binding uses the credential with ID ceph_win_ci_private_key and makes it 
    available as the environment variable CEPH_WIN_CI_KEY. 
        This is typically used for SSH keys or other sensitive files needed during the build.
        The username-password-separated binding uses the credential with ID github-readonly-token 
        and exposes the username as GITHUB_USER and the password/token as GITHUB_PASS. 
        This allows scripts to authenticate with GitHub securely, 
        without exposing secrets in the job configuration or logs.

    Summary:
    This section ensures that build logs are colorized for better readability and 
    that sensitive credentials (such as private keys and GitHub tokens) are securely 
    provided to the build process as environment variables.

ceph-windows-pull-requests/build/check_docs_pr_only
===================================================

#!/usr/bin/env bash
set -o errexit
set -o pipefail

docs_pr_only
container_pr_only
if [[ "$DOCS_ONLY" = true || "$CONTAINER_ONLY" = true ]]; then
    echo "Only the doc/ or container/ dir changed. No need to run Ceph Windows tests."
    exit 0
fi

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
                +---------------------+             | container/ changed"    |
                        |                          | Exit 0                  |
                        |                          +-------------------------+
                        | No
                        v
                    +-------+
                    | End   |
                    +-------+
                    
    This Bash script is used in the Jenkins pipeline to determine if a pull request 
    only changes documentation or container-related files. 
    It starts by enabling strict error handling with set -o errexit (exit on any error) 
    and set -o pipefail (fail if any part of a pipeline fails).

    The script then calls two functions, docs_pr_only and container_pr_only, 
    which are expected to set the environment variables DOCS_ONLY and CONTAINER_ONLY to true 
    if the pull request only affects documentation or container directories, respectively.

    If either DOCS_ONLY or CONTAINER_ONLY is true, the script prints a message 
    indicating that only documentation or container files were changed and exits with code 0. 
    This prevents unnecessary Ceph Windows tests from running for such pull requests, saving time and resources. 
    If neither variable is true, the script simply finishes, allowing the rest of the build process to continue.
