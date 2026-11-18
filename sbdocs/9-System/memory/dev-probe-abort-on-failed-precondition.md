---
name: dev-probe-abort-on-failed-precondition
description: A dev-test script that sets a precondition (flag flip) must check it took effect and exit before the scenarios; sysprop SDR PATCH answers 405
metadata:
  node_type: memory
  type: feedback
  originSessionId: db6890ae-9178-4b64-9697-acd6a5faee75
  modified: 2026-11-13T00:16:38.431Z
---

On 2026-11-13 (SBDEV-4134 dev test) one Bash call flipped `PRINT_CASE_LABEL` to false via `PATCH /v3/sysprop/{id}` and then ran the "printing off" scenarios. The PATCH answered **405** (sysprop SDR does not allow PATCH), the flag stayed `true`, and the script carried on. `printLabel` therefore sent a real location label to `SB1-TestLabel1` (the external test printer the plan said never to hit), and the unitload reprint sent a job to `SB-TestNull`.

**Why:** the scenarios were only safe *because* of the precondition. Batching the precondition and the scenarios in one call with no gate turned a failed setup into the exact side effect the test was designed to avoid.

**How to apply:**
- Run the precondition as its own call. Read the DB value back (`q.sh`) and confirm it changed before running anything that depends on it. In a batch, `|| exit 1` after the check.
- Sysprop writes on dev: PATCH is 405. Use PUT with the full GET body minus `_links` (PUT nulls omitted fields, so keep `created`) plus `If-Match: "<version>"`. See [[sysprop-admin-save-has-no-optimistic-lock]].
- Any scenario that could print when its guard is off is a print test: treat it as needing the same go-ahead as a positive print.
