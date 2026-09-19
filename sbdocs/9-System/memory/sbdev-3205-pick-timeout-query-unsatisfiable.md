---
name: sbdev-3205-pick-timeout-query-unsatisfiable
description: "SBDEV-3205 CLOSED, both fixes on develop (#284+#285); the query was unsatisfiable since SBDEV-1675; two follow-ups proposed-not-filed are still live on develop"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4565145c-d7a5-4db0-8198-988c1b413c88
  modified: 2026-09-03T00:09:34.488Z
---

**SBDEV-3205 — CLOSED 2026-09-03. Both fixes are on `develop`: #284 `e818ff11` (polarity) + #285
`6b10cf94` (dropped `operator_id IS NOT NULL`, added the orphan-lock null guard). Do not re-open or
re-implement it.** ⚠ Both PRs were SQUASH-merged, so `bugfix/SBDEV-3205-*` branch tips are NOT
ancestors of develop and `git branch --no-merged` lists them as unmerged. That is an artifact of
squash-merge, not evidence of unshipped work — verify content with
`git diff $(git merge-base origin/develop <branch>)..<branch>`, never by ancestry. This exact
misreading cost a re-triage on 2026-09-08.

**Two follow-ups were PROPOSED, NOT FILED, and both are still live on develop (verified 2026-09-08):**
1. `MobilePickingService.releaseRegularPickingOrder` Case 3 (~`:735`, `GET /v3/picking/releasePickingOrder/{id}`)
   clears `operatorId` + sets PROCESSABLE but never clears `lockedtooperator` → it is the PRODUCER of
   the orphan lock. #285 only made the CONSUMER (`rapidPickingScanPackage`, ~`:1069`) tolerate it.
2. `ReleaseExpiredPickingOrdersFromUserJob.releaseExpiredPickingOrders` (~`:334`) has no per-row
   try/catch, so one `ObjectOptimisticLockingFailureException` aborts the rest of that tenant's batch.
   Latent while the query matched 0 rows; reachable now that the fix ships.

**The original defect.** `PickingorderRepository.getPickingOrdersToReleaseExpiredPickingOrders`
carried `lockedtooperator = true … AND operator_id is null AND lockedtooperator = FALSE` → 0 rows on every
tenant on every run since `326b20dc` (SBDEV-1675, 2025-10-31). Fix in worktree
`.claude/worktrees/wms2-api/SBDEV-3205`: `operator_id IS NOT NULL`, drop the `= FALSE` line, keep
`pickinginprogress = false` (which PREDATES 1675 — initial checkin a685e07b; 326b20dc added only the two bad lines).
A review lane pushed back on `operator_id IS NOT NULL`: it is implied by the lock on every reachable path,
and it EXCLUDES an ORPHAN lock (locked, operator NULL) — the state that 500s every scan at
`MobilePickingService.rapidPickingScanPackage`. #284 kept it per AC2's original wording; **#285 then dropped
it**, so the job now self-heals orphan locks. The shipped predicate is `lockedtooperator = true` alone.
Pinned by `orphanLockIsSelectedAndSelfHealed` (NOT `orphanLockIsNotSelected` — that name is from the
withdrawn #284 design). orphan_locked = 0 on 4 DBs.
The ticket's "218 rows under the naive fix" did NOT reproduce (0 on dev, two instruments) — don't quote it.

**AC1 answered by evidence, not by asking:** SBDEV-1675's ClickUp description recommended adding an
operator/lock EXCLUSION to the **merge** query `findByStateAndBoxesPerCartAndSectionId`. The commit
(author: Nam) added exactly that exclusion, in the exclusion polarity, to the ADJACENT timeout query —
a misplacement, not a deliberate neutering. The merge query never got it; it is already protected by
`state < RESERVED` plus the in-loop `poCurrent.getState() >= RESERVED → continue` that the same commit
added, so no follow-up needed there.

**AC6 (RAPID_PICKING-only) is coherent:** `setLockedtooperator(true)` exists at exactly two sites, both
`MobilePickingService.rapidPickingScanPackage*` (which also set STARTED). The reserve path sets
`operator_id` + RESERVED **without** the lock — so `lockedtooperator = true` is load-bearing, not
implied by `operator_id IS NOT NULL`; the test fixture has a RESERVED-not-locked row to make that
predicate observable (mutant M6 `WHERE TRUE` is killed only because of it).

**Why:** the unit tests (11 in `ReleaseExpiredPickingOrdersFromUserJobTest`) all stub the repository
and were green for ten months; same lesson as [[sbdev-1615-picking-guard-broken-by-scalar-subquery]].
Native-query pins need the raw Testcontainers+Flyway+reflection harness
(`*IntegrationTest`, never `*IT` — see [[wms2-api-29-it-classes-run-in-neither-test-lane]]).

**How to apply:** when a hand-mutation anchor is a WHERE line, check it is unique in the file first —
`" AND po.state < :state " +` appears in TWO queries in this repository, and a non-unique anchor that
aborts looks like a SURVIVOR (green) unless the script fails loudly. Docs corrected:
`wms2-scheduled-jobs-catalog.md` §4.5 and `wms2-picking-workflow.md` both said "state = PICKED"; the
predicate is `state < PICKED`. v1 has the identical four lines (`v1/wms-api` PickingorderRepository
@ `a0e859a`) — stated per [[v2-only-no-v1-fixes-unless-asked]], not fixed.
