---
name: wms2-develop-push-can-create-no-ci-run
description: "A merge to wms2-api develop can produce NO \"Docker Image CI (develop)\" run at all, so nothing deploys; the workflow has no workflow_dispatch — the next push to develop carries it"
metadata:
  node_type: memory
  type: project
  originSessionId: ec8e2c74-641c-40a3-b9d2-be0c47c592ee
  modified: 2026-10-21T14:35:57.569Z
---

A merge into `wms2-api` `develop` can leave **no** workflow run for its merge commit: not a red run, not
a `startup_failure`, nothing in `gh api repos/SiteBossInc/wms2-api/actions/runs?head_sha=<sha>`. Seen twice:
#533 (2026-10-19, during a GitHub Actions degradation) and #549 / `ccaa4e93` (2026-10-21, githubstatus
reported all systems operational). Without a run the `build` job never fires, so **dev does not get the
code** even though the merge is on develop. `post-merge-verify.sh --wait-run` then waits indefinitely.

**Why:** `.github/workflows/docker-image-develop.yml` triggers only on `push` and `pull_request` — there is
no `workflow_dispatch`, so a dropped push event cannot be re-fired by hand, and `gh run rerun` needs a run
to exist.

**How to apply:**
- After a merge, if `gh run list --branch develop` shows no run for the new tip within a few minutes, check
  `actions/runs?head_sha=` before waiting on the verify script.
- Don't push an empty commit to develop on your own initiative. The next real merge's run builds a tree that
  contains the orphaned merge (as #536's run carried #533 to dev); prove the orphan's content in THAT
  deploy (`dev serves X, which contains <orphan sha>`).
- Tell the user the orphaned PR is merged but not yet on dev. Related: [[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]].
