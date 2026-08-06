# ceph-pr-pipeline

One pipeline for all ceph.git PR checks, replacing the GitHub Pull Request
Builder plugin and six freestyle jobs.  ceph.git is cloned once and built once
(x86_64, with tests); the test legs run on separate builders from the shared
build tree.  The GitHub status contexts are unchanged, so branch protection
rules don't change.

| Status context | Replaces | How it runs now |
| --- | --- | --- |
| `Signed-off-by` | [ceph-pr-commits](../ceph-pr-commits/) | GitHub API only, no clone, seconds |
| `Unmodified Submodules` | [ceph-pr-submodules](../ceph-pr-submodules/) | GitHub API only, no clone, seconds |
| `make check` | [ceph-pull-requests](../ceph-pull-requests/) | shared build → ctest on its own builder |
| `ceph API tests` | [ceph-pr-api](../ceph-pr-api/) | shared build → API tests on its own builder |
| `ceph windows tests` | [ceph-windows-pull-requests](../ceph-windows-pull-requests/) | parallel leg, own (win32) build |
| `make check (arm64)` | [ceph-pull-requests-arm64](../ceph-pull-requests-arm64/) | parallel leg, build+test on one arm64 node |

## Flow

```
webhook (pull_request / issue_comment)
  └─ ceph-pr-pipeline-trigger         gating, cancellation, label handling
       └─ ceph-pr-pipeline
            prepare                   resolve PR, classify files, post pending statuses
            ├─ Signed-off-by          GitHub API
            ├─ Unmodified Submodules  GitHub API
            ├─ ceph windows tests     (libvirt) own clone + build + tests
            ├─ build and test (arm64) (arm64)  restore-or-build + tests
            └─ build and test
                 build ceph           (huge)  ONE clone, bwc -e buildtests, tree → S3
                 ├─ make check        tree ← S3, bwc -e tests
                 └─ ceph API tests    tree ← S3, run-backend-api-tests (in container)
```

- **Cache:** build trees are zstd-tarred to S3 as
  `pr-builds/<PR>/<head sha>.<arch>.tar.zst`.  Re-runs for an unchanged head
  sha skip compilation (`FORCE_BUILD=true` overrides).
- **Statuses:** each leg posts its own context via the GitHub API.  Pending
  is posted from `prepare` before legs wait for executors; canceled/failed
  runs finalize any still-pending contexts.  Docs/container/gha-only PRs
  (plus qa-only for windows/arm64) report success without building.
- **Checkout time:** set `CEPH_REFERENCE_REPO` to a local ceph.git mirror on
  the builders to cut the remaining clones to seconds.

## Gating

- PR author in the ceph org: CI runs automatically.
- Otherwise: all contexts wait as pending until a Ceph developer adds the
  `ci-approved` label.  **Every push removes the label**, cancels running
  builds, and resets statuses — it must be re-added for the new code.
- Comment phrases (org members always, others only while labeled):
  `jenkins retest ...` re-runs everything; `jenkins test <check>` runs one of
  `make check`, `make check arm64`, `api`, `windows`, `signed`, `submodules`.
  Bare `jenkins test` runs nothing.

## Rollout

1. Credentials: `pipeline-trigger-token`, `github-status-check-token`
   (repo:status + issues write + org read), `github-readonly-token`,
   `dgalloway-docker-hub`, `ibm-cloud-sccache-bucket`, `ceph_win_ci_private_key`.
2. Deploy both jobs with JJB, then pre-approve the sandbox signatures in
   Manage Jenkins → Script Console:

   ```groovy
   import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval
   [
     'method org.jenkinsci.plugins.workflow.support.steps.build.RunWrapper getRawBuild',
     'method hudson.model.Run getParent',
     'method hudson.model.Job getBuilds',
     'method jenkins.model.HistoricalBuild getNumber',
     'method jenkins.model.HistoricalBuild isBuilding',
     'method hudson.model.Actionable getAction java.lang.Class',
     'method hudson.model.ParametersAction getParameter java.lang.String',
     'method hudson.model.StringParameterValue getValue',
     'method hudson.model.Run getExecutor',
     'method hudson.model.Executor interrupt hudson.model.Result',
     'staticField hudson.model.Result ABORTED',
     'staticMethod jenkins.model.Jenkins get',
     'method jenkins.model.Jenkins getItemByFullName java.lang.String',
   ].each { ScriptApproval.get().approveSignature(it) }
   ```

   (If a run reports a differently-resolved signature, approve exactly what
   it prints at In-process Script Approval.)
3. Test side by side: run `ceph-pr-pipeline` manually with a PR number and
   `STATUS_PREFIX=pipeline/` so required contexts are untouched.
4. Add the webhook:
   `https://jenkins.ceph.com/generic-webhook-trigger/invoke?token=<pipeline-trigger-token>`
   for `pull_request` + `issue_comment`, content type `application/json`.
5. Flip: disable the GHPRB triggers on the six old jobs, drop `STATUS_PREFIX`.
6. Add an S3 lifecycle rule expiring `pr-builds/*` after ~7 days, and
   (optional) seed reference mirrors for `CEPH_REFERENCE_REPO`.

## Known gaps

- API tests now run inside the build container (was: bare noble host);
  validate on a real PR before the flip.
- Dashboard-frontend cobertura publishing is not wired up yet.
- A hard kill (double abort) skips `post{}`, so statuses stay pending.
- `build-with-container.py` names its container `ceph_build`: one leg per
  builder at a time (true today with single-executor builders).
