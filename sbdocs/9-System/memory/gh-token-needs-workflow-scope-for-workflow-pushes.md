---
name: gh-token-needs-workflow-scope-for-workflow-pushes
description: "Pushing any change under .github/workflows/ is rejected unless the gh OAuth token has the `workflow` scope; refresh + setup-git, and run the refresh where the user can finish the device flow"
metadata:
  node_type: memory
  type: reference
  originSessionId: 7c4920b5-404f-4d90-9705-cd33a7158483
  modified: 2026-11-09T03:21:27.032Z
---

A `git push` that touches `.github/workflows/*.yml` fails with
`refusing to allow an OAuth App to create or update workflow ... without 'workflow' scope`.
As of 2026-11-09 the token on the Mac (`nparksb`) had only `gist, read:org, repo`. That push was SBDEV-4074, the first workflow edit pushed from this machine. SBDEV-3195 had evidently been pushed from elsewhere.

**Fix:** `gh auth refresh -h github.com -s workflow`, then `gh auth setup-git`. Without `setup-git`, git keeps
using the osxkeychain credential instead of gh's token.

**What cost several rounds:** the refresh uses a device flow (a one-time code and a browser page). Run via the `!` prefix, it got
backgrounded after 120 s and its code expired before it was entered. What worked: start it as a background Bash
(`gh auth refresh ... && gh auth setup-git && gh auth status`), read the code out of its output file, give
the user the code plus https://github.com/login/device, and wait for the completion notification. Check the scope
with `gh auth status | grep "'workflow'"` before retrying the push.

Related: [[wms2-no-pipeline-runs-tests]]
