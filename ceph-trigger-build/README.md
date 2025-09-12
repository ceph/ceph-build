
# ceph-trigger-build

This pipeline's role is to:

1. Be triggered by a git push event to [ceph-ci.git](https://github.com/ceph/ceph-ci)
2. Determine which Jenkins job or pipeline to use for the source creation, compilation, and packaging.
3. Trigger the appropriate Jenkins job/pipeline using default parameters based on the branch name, defined parameters via [git trailers](https://git-scm.com/docs/git-interpret-trailers), or a combination of both.


### Git Trailer Parameters

- All parameters are optional.  For example, if you only want to build packages on `x86_64` for a branch targeted at `tentacle`, tentacle's default distros are `jammy centos9 windows` so a pipeline would be triggered to build x86_64 packages of each distro.
- The use of git trailers is only supported in combination with CEPH-BUILD-JOB: ceph-dev-pipeline.
- Only the head commit's trailers will be evaluated.

|Parameter|Description|Available Options|Default|
|--|--|--|--|
|CEPH-BUILD-JOB|Which Jenkins job to trigger. Only ceph-dev-pipeline supports the options below.|ceph-dev-pipeline, ceph-dev-new|`ceph-dev-pipeline`|
|DISTROS|Space-sparated list of Linux distributions to build for|focal, jammy, noble, centos9, windows|Depends on keywords in branch name|
|ARCHS|Space-separated list of architectures to build on|x86_64, arm64|`x86_64 arm64`|
|FLAVORS|Crimson or non-Crimson|default, crimson-debug, crimson-release|`default`|
|CI-COMPILE|Compile binaries and packages[^1]|Boolean|`true`|
|CI-CONTAINER|Build a dev container using the packages built|Boolean|`true`|
|DWZ|Use [DWZ](https://sourceware.org/dwz/) to make debuginfo packages smaller|Boolean|`true` when using ceph-dev-new<br>`false` when using ceph-dev-pipeline[^2]|
|SCCACHE|Use [sccache](https://github.com/mozilla/sccache) to reduce compilation time|Boolean|`false` when using ceph-dev-new<br>`true` when using ceph-dev-pipeline[^3]|
|CEPH-BUILD-BRANCH|Which ceph-build.git branch to use. Useful for testing.|N/A|`main`|


[^1]: You might set this to `false` if you know packages already exist and you only want to build a container using them.
[^2]: DWZ adds a lot of time to builds for a small decrease in disk usage.  The default behavior is changing with the switch to the ceph-dev-pipeline job.
[^3]: This is new functionality provided in the ceph-dev-pipeline job.

### Git Trailer Examples
"I only want to build x86 packages for Ubuntu 22.04.  I don't care about containers."

    CEPH-BUILD-JOB: ceph-dev-pipeline
    DISTROS: jammy
    ARCHS: x86_64
    CI-CONTAINER: false

"I only want to build packages and a container for CentOS 9."

    CEPH-BUILD-JOB: ceph-dev-pipeline
    DISTROS: centos9

"My container build failed but I know the package build succeeded.  Let's try again."

    CEPH-BUILD-JOB: ceph-dev-pipeline
    DISTROS: centos9
    CI-COMPILE: false

"I don't trust sccache."

    CEPH-BUILD-JOB: ceph-dev-pipeline
    SCCACHE: false

