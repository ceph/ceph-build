# ceph-pr-pipeline

One declarative Jenkins pipeline for the ceph.git PR checks that were
previously five independent freestyle jobs, each doing its own 4-5 minute
clone and (for three of them) its own multi-hour build:

| Status context | Old job | In the pipeline |
| --- | --- | --- |
| `Signed-off-by` | [ceph-pr-commits](../ceph-pr-commits/) | GitHub-API check, no clone, seconds |
| `Unmodified Submodules` | [ceph-pr-submodules](../ceph-pr-submodules/) | GitHub-API check, no clone, seconds |
| `make check` | [ceph-pull-requests](../ceph-pull-requests/) | shared build → ctest on its own builder |
| `ceph API tests` | [ceph-pr-api](../ceph-pr-api/) | shared build → API tests on its own builder |
| `ceph windows tests` | [ceph-windows-pull-requests](../ceph-windows-pull-requests/) | parallel leg (different binaries, nothing to share) |

`make check (arm64)` ([ceph-pull-requests-arm64](../ceph-pull-requests-arm64/))
deliberately stays a separate job: it can never reuse the x86_64 binaries, so
folding it in would add matrix complexity for zero savings.

The GitHub status contexts are identical to the old jobs, so **branch
protection rules do not change**.

- Job definitions (JJB): [ceph-pr-pipeline.yml](config/definitions/ceph-pr-pipeline.yml),
  [ceph-pr-pipeline-trigger.yml](../ceph-pr-pipeline-trigger/config/definitions/ceph-pr-pipeline-trigger.yml)
- Pipeline: [Jenkinsfile](build/Jenkinsfile)
- Trigger: [ceph-pr-pipeline-trigger/build/Jenkinsfile](../ceph-pr-pipeline-trigger/build/Jenkinsfile)
- Helper scripts: [pr_checks.sh](build/pr_checks.sh) (API-based quick checks),
  [s3_cache.sh](build/s3_cache.sh) (build-tree handoff/cache)

## Flow

```
webhook (pull_request / issue_comment)
  └─ ceph-pr-pipeline-trigger        gating, cancellation, label handling
       └─ ceph-pr-pipeline
            prepare                  (small)  resolve PR, classify changed files
            ├─ Signed-off-by         (small)  GitHub API, no clone
            ├─ Unmodified Submodules (small)  GitHub API, no clone
            ├─ ceph windows tests    (libvirt) own clone + win32 build + tests
            └─ build and test
                 build ceph          (huge)   ONE clone, bwc -e buildtests,
                 │                            tree → S3 (skipped if cached)
                 ├─ make check       (noble)  tree ← S3, bwc -e tests
                 └─ ceph API tests   (huge)   tree ← S3, run-backend-api-tests
```

- **One checkout.** Only the build node and the windows node clone ceph.git.
  The quick checks and the test legs never clone at all.  Set
  `CEPH_REFERENCE_REPO` to a local mirror path (maintainable via ansible/cron
  on the builders) to cut the remaining clones from ~5 minutes to seconds; the
  git plugin ignores the path on builders that don't have it.
- **One build.** `build-with-container.py -e buildtests` compiles ceph *with*
  tests (a superset of what the API tests need — the old ceph-pr-api job
  built its own tree with `WITH_TESTS=OFF`).  The tree is compiled inside the
  `DISTRO_BASE` container, so it runs identically on whichever builder the
  test legs land on.
- **Binary cache / re-runs.**  The built tree (source + `build/`) is
  zstd-tarred and uploaded to S3 keyed by `pr-builds/<PR>/<head sha>.tar.zst`.
  Any re-run for the same head sha — e.g. `jenkins test api` after a flaky
  failure — skips compilation entirely and reuses the cached tree
  (`FORCE_BUILD=true` overrides).  sccache still accelerates genuinely new
  builds.
- **Statuses.**  Each leg posts pending/success/failure for its own context
  directly via the GitHub API (`github-status-check-token`); there is no
  GHPRB plugin involvement.  A failed build posts failure to both `make
  check` and `ceph API tests` so nothing is left hanging at "queued".
- **Docs-only PRs** (and container-only, `.github`-only; plus qa-only for
  windows) skip the heavy legs and report success for their contexts, same as
  the old jobs.  Signed-off-by switches to the doc-title check for docs-only
  PRs, mirroring ceph-pr-commits.

## Gating (replaces GHPRB's org whitelist)

Implemented in the trigger job:

- PR author in the **ceph GitHub org** → CI runs automatically on open,
  reopen and every push.
- Anyone else → all five contexts are set to pending
  ("awaiting 'ci-approved' label…") and nothing runs until a Ceph developer
  adds the **`ci-approved` label** (adding labels requires triage permission,
  so the label itself is the authorization).
- **Every push to an approved PR revokes the approval**: the trigger removes
  `ci-approved`, cancels any running pipeline builds for that PR, and resets
  the contexts to pending.  The label must be re-added after each push —
  including force-pushes — so approval always refers to reviewed code.
- Comment phrases (org members always; others only while the label is
  present):
  `jenkins test make check`, `jenkins test api`, `jenkins test windows`,
  `jenkins test signed`, `jenkins test submodules`, `jenkins test all`.
  `jenkins test make check arm64` is left to the arm64 job's own GHPRB
  trigger.  `jenkins do not test` in the PR description still skips
  auto-builds.

## Force-push / cancellation

A new webhook delivery for a PR (push or retest) makes the trigger abort any
still-running `ceph-pr-pipeline` builds for that PR number before starting a
new one, and the pipeline's prepare stage also aborts older builds of itself
for the same PR (covers manual runs and webhook races).  A build whose
`HEAD_SHA` no longer matches the PR head aborts itself as superseded.

## Why not GitHub Actions (or a GHA/Jenkins combo)?

- Every heavy check needs our own hardware (huge builders, libvirt hosts);
  GHA could only ever be a trigger shim in front of Jenkins.
- `.github/workflows` live in ceph.git per target branch and would need
  backporting to every stable branch; ceph-build config applies to all
  branches on merge.
- Gating/cancellation policy would exist in two systems and drift.

## Rollout

1. Create the `pipeline-trigger-token` secret text credential (any random
   string) if not already present, and confirm these exist:
   `github-status-check-token` (needs `repo:status` **and** issues write for
   label removal, and org membership read), `github-readonly-token`,
   `dgalloway-docker-hub`, `ibm-cloud-sccache-bucket`,
   `ceph_win_ci_private_key`.
2. Deploy the two jobs with JJB.  The abort-superseded-builds helpers touch
   the Jenkins model (`Jenkins.get()` / `rawBuild`), which the sandbox
   rejects until approved.  Rather than approving one signature per failed
   run, pre-approve the lot in Manage Jenkins → Script Console:

   ```groovy
   import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

   [
     'method org.jenkinsci.plugins.workflow.support.steps.build.RunWrapper getRawBuild',
     'method hudson.model.Run getParent',
     'method hudson.model.Job getBuilds',
     'method hudson.model.Run getNumber',
     'method hudson.model.Run isBuilding',
     'method hudson.model.Actionable getAction java.lang.Class',
     'method hudson.model.ParametersAction getParameter java.lang.String',
     'method hudson.model.ParameterValue getValue',
     'method hudson.model.Run getExecutor',
     'method hudson.model.Executor interrupt hudson.model.Result',
     'staticField hudson.model.Result ABORTED',
     'staticMethod jenkins.model.Jenkins get',
     'method jenkins.model.Jenkins getItemByFullName java.lang.String',
   ].each { ScriptApproval.get().approveSignature(it) }
   ```

   If a run still hits a rejection (signature strings can vary slightly by
   plugin version), approve the exact string it reports at Manage Jenkins →
   In-process Script Approval and re-run.
3. Test side by side with the old jobs: run `ceph-pr-pipeline` manually with
   a real PR number and `STATUS_PREFIX=pipeline/` — statuses appear as e.g.
   `pipeline/make check` and the required contexts are untouched.
4. Add the repo (or org) webhook:
   `https://jenkins.ceph.com/generic-webhook-trigger/invoke?token=<pipeline-trigger-token>`
   for `pull_request` + `issue_comment` events, content type
   `application/json`.
5. Flip: disable the GHPRB triggers on the five old jobs (keep the jobs for a
   while for manual reruns/rollback), and remove `STATUS_PREFIX`.
6. Add an S3 lifecycle rule expiring `pr-builds/*` after ~7 days (the cache
   is per-PR-head-sha and only useful for re-runs).  Consider a dedicated
   bucket instead of `ceph-sccache` if quota is a concern.
7. Optional: seed `/home/jenkins-build/ceph-mirror.git` on the builders and
   set `CEPH_REFERENCE_REPO` accordingly.

## Known gaps / TODO

- The dashboard-frontend cobertura coverage publishing from
  ceph-pull-requests is not wired up yet (needs the coverage plugin's
  pipeline step).
- The API tests now run **inside the build container** (jammy by default)
  instead of directly on a noble host; `run-backend-api-tests.sh` in a
  rootless-podman container needs validating on a real PR before the flip.
  Daemon-heavy make check tests already run in that container, so this is
  expected to work.
- Squid-targeted PRs: the old `ceph-api-squid` job ran on jammy *hosts*; here
  everything is containerized so the host OS no longer matters, but squid PRs
  should be spot-checked.
- The GHPRB "rebuild" button semantics are replaced by re-running the
  pipeline build (Jenkins "Rebuild" with the same parameters works and will
  hit the binary cache).
- `build-with-container.py` names its container `ceph_build`, so two legs of
  the same (or different) PRs must not share a builder concurrently; with
  one executor per builder — the current farm setup — this cannot happen.
