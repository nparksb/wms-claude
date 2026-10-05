---
name: wms2-mobile-ui-apierror-renders-problemdetail
description: wms2-mobile-ui util/apiError.js DOES exist and renders a ProblemDetail detail as a toast; three wms2-api javadocs assert the opposite
metadata: 
  node_type: memory
  type: project
  originSessionId: fa3a1397-756c-4c22-a3bc-ca1190e2307b
  modified: 2026-09-22T17:27:14.133Z
---

`v2/wms2-mobile-ui` `util/apiError.js` exists on `origin/develop`, `origin/main` and
`origin/release` (added 2026-08-28, "fix(errors): surface the backend's error message instead of a
fixed generic red bar"). Its `apiErrorMessage` prefers `data.detail`, and `toastApiError` is called
from the `catch` of **every** store action — including `store/truckLoading.js` `scanGate` and all
four `store/palletizing.js` actions. `plugins/axios.js` `onError` intercepts only
`403 && body.reason`, so a 409 rejects through to the store catch. So **a 409 ProblemDetail's
`detail` IS shown to the operator as a toast.**

⚠ As of SBDEV-3418 commit `ed2ed97a` (2026-09-22), three `wms2-api` `src/main` javadocs assert the
opposite — that the file "does not exist anywhere in that repo" and the handheld shows only
`"Error: Request failed due to a network or server issue. Please retry."`:
`MobileTruckLoadingService`, `MobilePalletizingService`, `MobilePalletizeWriteService`. Those
comments are wrong; do not build on them. (The fixed-string behaviour is what the 2026-08-28 commit
removed.)

**Why:** the claim was derived from a local `wms2-mobile-ui` checkout 77 commits / ~7 weeks behind
`origin/develop`, where a `find` genuinely returns nothing — a false zero indistinguishable from a
true one. See [[derive-cross-repo-claims-from-origin-develop]] and
[[a-zero-scan-needs-a-positive-control]].

**How to apply:** before asserting anything about a UI repo from `wms2-api`, `git fetch` and read
via `git show origin/develop:<path>`, never the working tree or `find .`.
