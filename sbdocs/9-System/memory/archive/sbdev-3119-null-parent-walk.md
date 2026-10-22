---
name: sbdev-3119-null-parent-walk
description: "SBDEV-3119 (v2) MERGED be3411ca — deleting a root container with children called findById(null); THREE verbatim copies of the walk, and 8 of 9 review findings were overstated CLAIMS of mine, not code"
metadata:
  type: project
---

**SBDEV-3119 (v2) — MERGED `be3411ca` on develop 2026-08-26, dev build. wms2-api
[PR #212](https://github.com/SiteBossInc/wms2-api/pull/212), commits `d325e6a6` → `9e751888` → `a10a5ce3`.**
Merged develop verified **5653 / 0 / 67 skipped**; baseline was 5645/0/67 at `71e30679`.

`UnitloadService`'s carrier walk stepped to the parent's parent unconditionally, so on reaching a ROOT
it called `unitloadRepository.findById(null)`. Spring Data asserts a non-null id as the **first
bytecode instruction** of `findById`, so it threw. Fixed with one helper carrying the null check in the
**loop condition**.

**THREE verbatim copies of the walk existed** — two in `deleteUnitLoadRecursivePreRun` (one per branch
of `unitLoadList == null`) and one in `deleteUnitLoadRecursive`. I found two, claimed that was all,
and **review found the third**. It mattered: `UnitLoadController:174` calls the pre-run **then**
`deleteUnitLoadRecursive`, so fixing only the pre-run would have MOVED the failure one method later
while looking complete. I was wrong twice in a row about having found them all.

**Measured on `dev_wh01_om1`:** 754,813 unitloads · 341,113 roots (`carrierunitload_id IS NULL`) ·
**0** using a 0 sentinel · **16,073 roots WITH children** = the affected population · 0 cycles
anywhere · max chain depth 2.

**Second defect, demonstrated not theorised:** an ANCESTOR cycle looped forever, because the
self-reference check compares each ancestor against the CHILD only. The regression test **times out
after 5s** against the old code. Closed with a `visited` set.

## Three claims of mine that were WRONG and are corrected in the PR/ticket

1. **"It fails safe" is true of the PRE-RUN only.** `deleteUnitLoadRecursive` carries **no
   `@Transactional`** (the file's only one is on `moveStockToNewDamagedContainer`), so with ≥2 children
   a throw while walking child #2 lands **after child #1's delete committed**.
2. **`STRICT_STUBS` turns ONE pre-existing test into a regression pin, not two.** Mockito raises
   `PotentialStubbingProblem` only when the mismatching call finds an as-yet **UNUSED** stubbing on
   that method (`DefaultStubbingLookupListener` filters on `!wasUsed()`).
   `shouldValidateUnitloadWithChildren` stubs only `findById(1L)` and has already consumed it → stays
   **GREEN**. Only `shouldValidateWithGrandchildrenHierarchy` reds, because it also stubs
   `findById(2L)` — a pin **by accident of stub ordering**, which a fixture reorder would destroy.
3. **`/deleteContainerRecursive` has NO UI caller** in either v2 UI (documented at
   `wms2-web-ui/store/handlingUnits/container.js:28-29`, asserted by two store specs). The pre-run
   copies gate `/deleteContainer` and `/bulkDeleteContainer`, which the web UI does call.

## The pattern worth carrying forward

**9 review findings across 2 lanes; exactly ONE was a code defect.** The other 8 were claims stated
more broadly than measured ("every test in this class…" → three of four) or assertions that could not
fail. The reviewer named it twice. **The code held up under both lanes; the write-ups did not.**

Traps hit here, all already documented elsewhere and walked into anyway:
- **`verify(never())` is vacuous when the call is unreachable** — deleting the guard means no walk, so
  "never asked for null" still passes. Needs a positive `verify(...)` FIRST. Hit twice on this ticket.
- **`OptionalSafetyArchTest` is pure call-site presence, no dataflow** — a provably-guarded
  `isEmpty()`-then-`get()` still violates it. Use `.orElse(null)`. See
  [[wms2-web-ui-coverage-instrumentation-disarms-render-source-pins]] for the sibling lesson.
- **Every `mvn test` re-prunes the tracked `archunit_store`** (this branch removed 5 `.get()` entries).
  Committing it silently re-freezes real violations — `git checkout --` it unless re-baselining
  deliberately in its own commit.
- **A bare `verify(x)` means EXACTLY ONCE.** `findById(1L)` is called twice in a 3-level walk (child's
  hop + grandchild's second hop) → `TooManyActualInvocations`. Pin `times(2)`; don't loosen to
  `atLeastOnce()` when the count IS the behaviour.

**STILL OPEN, unanswerable from code:** whether **SBDEV-2979's 478** measured container deletions were
leaves or childless roots. Consistent either way (a leaf never enters the loop) — but **if any were
nested, the trace is missing a branch and 3119 reopens.**

Found while re-triaging [[wms2-mobile-palletizing-has-two-duplicate-test-classes]]; that ticket's cleanup was
gated on this and is now unblocked.
