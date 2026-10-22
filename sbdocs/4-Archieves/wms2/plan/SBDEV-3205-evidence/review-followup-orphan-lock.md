# SBDEV-3205 follow-up — independent review: orphan-lock self-heal

**Verdict: APPROVE WITH FIXES**

Reviewer: independent lane (read-only). Target: worktree
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3205-followup`,
branch `bugfix/SBDEV-3205-followup-orphan-lock-self-heal`, diffed against `origin/develop` @ `e818ff11`.
No Maven was run (per constraint); no file in the worktree was modified.

The two production changes are **correct**. The query change genuinely selects the orphan row for the
reason claimed, and the null guard partitions the three cases correctly. What needs fixing is a factual
overclaim repeated in four comment blocks, and one test gap. Findings 1–3 are the same defect in three
places and should be fixed together.

---

## Findings

### 1. (Medium) The "no reachable path writes this state" claim is false — a **live** endpoint writes the orphan state today, and the comment names the wrong (dead) method as the risk

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java:1059-1064`

```java
// SBDEV-3205 follow-up: getOperatorId() can be null on an ORPHAN lock (lockedtooperator = true
// with no operator recorded) -- a state with no current writer, but reachable if a future
// change resurrects releasePickingOrder(Pickingorder), which clears operatorId without
// clearing the lock.
```

and `src/main/java/net/aim_ai/wms/repo/jpa/PickingorderRepository.java:78-79`

```java
// lock (lockedtooperator = true, operator_id NULL) — a state with no current production writer,
```

**What is wrong.** The author's sibling sweep found the `releasePickingOrder(Pickingorder)` overload
(line 262, `setOperatorId(null)` at line 319, lock untouched) and correctly established it has zero
`src/main` callers. It stopped there. A **second** method with the identical shape is live:

`MobilePickingService.releaseRegularPickingOrder(Long)` — line 700, Case 3 at lines 734-737:

```java
// Case 3: No positions picked — reset to pool
if (!anyPicked) {
    pickingOrder.setOperatorId(null);
    pickingOrder.setState(WmsConstants.State.PROCESSABLE);
    pickingorderRepository.save(pickingOrder);
```

`lockedtooperator` is never cleared. It is reachable over HTTP today:
`PickingController.java:253` `GET /v3/picking/releasePickingOrder/{id}` → line 261
`mobilePickingService.releaseRegularPickingOrder(id)`. The method takes an arbitrary picking-order id
from the path variable and performs **no section-picking-type check**, so an order that a rapid scan
locked (`setLockedtooperator(true)` at lines 1071-1072 or 1186-1187) and that has no picked positions
yet — precisely the state right after a scan — comes out of Case 3 as `lockedtooperator = true,
operator_id = NULL`. That is the orphan lock, written by production code, on the current `develop`.

I checked whether the shipped mobile UI actually drives it, and today it does not: in
`v2/wms2-mobile-ui`, only `components/picking/pick.vue:271` (`goBackToList`) dispatches
`picking/releasePickingOrder`, and `pages/picking.vue` routes that component to the **regular** flow
(`12_pick`) while the rapid flow lives on disjoint steps `21_package`–`25_verify`, none of which
dispatch it. So the claim is true of *the current UI* and false of *the API*. That distinction is
exactly what the comment must carry, because the endpoint is a plain authenticated GET.

This does not weaken the change — it strengthens it. The diff is not repairing a hypothetical anomaly;
it is repairing one that a live, unguarded endpoint can produce. But a future reader who trusts "no
current writer" will re-derive the wrong risk assessment, and the comment actively points them at the
dead overload instead of the live one.

**Suggested fix.** In both comment blocks, replace the absolute claim with the narrowed one, e.g.:

> …a state no path the current mobile UI drives, but one that `releaseRegularPickingOrder`
> (`GET /v3/picking/releasePickingOrder/{id}`, `MobilePickingService:734`) writes directly: it clears
> `operatorId` and resets the state without clearing `lockedtooperator`, and applies no
> section-picking-type check, so a rapid-picking order locked by a scan and released before any pick
> lands in exactly this state. The dead `releasePickingOrder(Pickingorder)` overload has the same shape.

Whether `releaseRegularPickingOrder` should also clear the lock is a separate question. Per the repo's
ticket policy this belongs on the **existing** SBDEV-3205 ticket (its own tier is well under T3 — one
line, one file, reversible), not on a new one. I would note it rather than fix it in this diff: after
this change the timeout job self-heals it within the timeout window, so it is no longer load-bearing.

---

### 2. (Low) Same overclaim in the integration-test fixture javadoc, plus a confusing tense

**File:** `src/test/java/net/aim_ai/wms/integration/ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest.java:104`

```java
/** Locked but {@code operator_id IS NULL} — an orphan lock no reachable path writes today; now released. */
private static final long ORPHAN_LOCKED = 320508L;
```

**What is wrong.** Two things. First, "no reachable path writes today" is the Finding 1 claim, and it is
wrong for the same reason. Second, "now released" reads as a property of the fixture row when it is a
property of the query's output — the row is seeded identically before and after; only the SELECT
changed.

This also answers the question of whether ORPHAN_LOCKED needs the `HELD_TOTES`-style **SYNTHETIC**
caveat now that it is used positively. It does not — the correction runs the other way. `HELD_TOTES`
really is synthetic (I confirmed `setLockedtooperator(true)` appears in `src/main` only at
`MobilePickingService:1072` and `:1187`, both rapid-picking paths, so a locked TOTES_ON_CART order
cannot be written), and its caveat is accurate as it stands. ORPHAN_LOCKED is the opposite: it is the
one anomaly row in this fixture that a live endpoint *can* produce, and the javadoc currently claims it
cannot.

**Suggested fix:**

```java
/**
 * Locked but {@code operator_id IS NULL} — an orphan lock. Not written by any flow the mobile UI
 * drives, but {@code MobilePickingService.releaseRegularPickingOrder} (GET
 * /v3/picking/releasePickingOrder/{id}) writes it directly: it nulls operatorId without clearing the
 * lock and applies no picking-type check. Selected for release since the SBDEV-3205 follow-up.
 */
```

---

### 3. (Low) Same overclaim in the new unit test's comment

**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePickingServiceUnitTest.java:1608-1609`

```java
// stuck in this state 500s. No production path writes this state today (see
// PickingorderRepository's SBDEV-3205 comment), but nothing ever clears lockedtooperator
```

**What is wrong.** Third copy of the Finding 1 claim. It also forwards the reader to
`PickingorderRepository`'s comment, so fixing that one without this one leaves a dangling pointer to a
corrected claim.

**Suggested fix.** Since this comment already delegates, shorten it to delegate fully rather than
restate: "The state is reachable — see `PickingorderRepository`'s SBDEV-3205 follow-up comment for the
writer." That keeps the fact in one place.

---

### 4. (Low) The release job has no per-row error isolation, and this diff widens the set it iterates

**File:** `src/main/java/net/aim_ai/wms/schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java:154-160`

```java
for (Pickingorder pickingOrder : pickingOrders) {
    ...
    pickingOrder.setOperatorId(null);
    pickingOrder.setLockedtooperator(false);
    pickingorderRepository.save(pickingOrder);
}
```

**What is wrong.** `Pickingorder` extends `AbstractBaseEntity`, which carries `@Version`
(`AbstractBaseEntity.java:34`). A picker claiming a row between the job's SELECT and its `save` produces
`ObjectOptimisticLockingFailureException`, and there is no per-row try/catch — the first collision
aborts the remaining rows for that tenant and is caught only at the tenant level, where it records a
`tenantFailure`.

**Not introduced by this diff, and I would not fix it here.** The query returned zero rows for months,
so this was latent; `e818ff11` made it live and this follow-up adds one more row shape to the set. The
scan-vs-job race itself is benign in both directions — the job's write is idempotent, and a scan that
loses simply retries — so the only cost is the truncated batch and a spurious tenant-failure metric.
Flagging so it is a known, recorded property rather than a surprise on the first real dev run. It is
one `try/catch` around the loop body if it is ever wanted.

Regarding the double-fix question generally: the query path and the guard path do **not** conflict. The
guard converts an orphan into a normally-held row (operator set, lock set, `modified` bumped by the
save), which restarts the timeout window, so the job cannot then yank it from the picker who just
claimed it. The `pickinginprogress = false` collision guard is untouched. The two fixes cover disjoint
windows: the guard covers the seconds before the timeout elapses, the job covers an orphan nobody scans.
That is complementary, not redundant.

---

### 5. (Low) No test pins "locked to the SAME user proceeds"; dropping the third conjunct is a surviving mutant

**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePickingServiceUnitTest.java`, nested class `RapidPickingPackageScan`

**What is wrong.** The guard now has three cases and the class covers two of them. `orphan` (new test)
covers `operatorId == null`; `shouldThrowWhenLockedToDifferentOperator` covers a foreign operator;
`shouldReturnFirstUnpickedPosition` and `shouldThrowWhenNoPicksLeft` both set
`setLockedtooperator(false)`, so they do not exercise the guard at all. Nothing sets
`lockedtooperator = true` **with** `operatorId = 1L` (the scanning user).

Consequence: the mutant that deletes the third conjunct —

```java
if (pickingOrder.getLockedtooperator() && pickingOrder.getOperatorId() != null) {   // mutant
```

survives the whole class. Different-operator still throws, orphan still passes the guard,
lock-false still passes. But the legitimate owner re-scanning their own package would now get
`"parcel=… locked to operator=<themselves>"`. The reported PIT result does not close this: PIT's
`NegateConditionalsMutator` flips `!equals` to `equals`, which `shouldThrowWhenLockedToDifferentOperator`
kills; it does not model conjunct removal.

**Suggested fix.** Add one sibling test, cloned from `shouldReturnFirstUnpickedPosition` with
`setLockedtooperator(true); setOperatorId(1L);` and the same successful-return assertions. Roughly
fifteen lines, and it makes the guard's third case observable.

---

## Checked and found fine

- **Query semantics against the ORPHAN_LOCKED fixture row.** Walked all five remaining predicates
  against the seeded row (`ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest:322`):
  `lockedtooperator = true` ✓, `pickinginprogress = false` ✓, `modified = now() - 10 minutes` against a
  `now() - 40s` bound ✓, `state = STARTED` below the `PICKED` bound ✓, section `SECTION_RAPID` is
  `RAPID_PICKING` ✓, and `pickingorder(...)` seeds a matching `pickingorder_position` so the two INNER
  JOINs hold ✓. It is selected on its own merits, not as a join artifact. `SELECT DISTINCT` plus one
  position per order means no duplicate-row effect.
- **Guard case partition.** Orphan (`lock && null`) → short-circuits at the second conjunct, falls
  through, claimed at line 1071. Foreign operator (`lock && 999 && !999.equals(1)`) → throws, unchanged.
  Same user (`lock && 1 && !1.equals(1)`) → false, falls through, unchanged. Unlocked → false at the
  first conjunct, unchanged. No case is mishandled. The guard also protects
  `userRepository.findById(pickingOrder.getOperatorId())` on the next line, which would otherwise throw
  `InvalidDataAccessApiUsageException` on a null id.
- **Boxed-Long comparison.** Uses `.equals`, not `==`. No repeat of the under-128 reference-comparison
  trap.
- **First-operand unboxing.** `getLockedtooperator()` returns `Boolean` (`model/Pickingorder.java:126`)
  and is unboxed before the new guard, so a null flag would still NPE. Not a live risk: the column is
  `NOT NULL DEFAULT false` (confirmed against `wms2-wineco-dev` `information_schema`), the field
  initialiser is `false`, and `lock_flag_null = 0` on every tenant queried. Correctly left alone.
- **Job loop null-safety.** `ReleaseExpiredPickingOrdersFromUserJob:156-158` only logs and nulls
  `operatorId`; it never dereferences it. Orphan rows entering the release set cause no NPE there.
- **No write-traffic regression.** The job's update sets `lockedtooperator = false`, so a released
  orphan stops matching `lockedtooperator = true` on the next run. No per-minute rewrite loop — the
  trap `alreadyReleasedRowIsNotSelected` guards against is not reintroduced.
- **Sibling sweep of the NPE shape.** Every `getOperatorId()` dereference in `src/main`:
  `MobilePickingService:386` and `:422` (non-null receiver on the left), `:464`, `:753`, `:1364` (already
  `!= null &&` guarded), `:1228` (guarded by the `== null` early return at `:1223`),
  `ReleaseExpiredPickingOrdersFromUserJob:156` (log only). Line 1065 was the only unguarded one. The
  author's claim holds, and the chosen idiom matches the three existing guarded sites.
- **New unit test reaches the claim code.** Traced `rapidPickingScanPackage` end to end with the stubs
  given: label regex passes on `P-001`, `getForRapidPickingScanPackage` returns the order so the whole
  `customerOrderList` branch is skipped, `STARTED < PICKED` clears the already-picked throw,
  `sectionRepository.findById(1L)` returns `testSection` named `"TestSection"` matching the argument,
  the user lookup resolves, the guard falls through, `save` runs, and the `findByPickingorderId(1L)` loop
  returns `testPosition` at `RAW`. No earlier short-circuit. The test is a minimal differential against
  `shouldReturnFirstUnpickedPosition` — only the two lock fields differ.
- **The claim assertion is not vacuous.** `testUser.setId(1L)` at line 157, so
  `assertThat(testPickingOrder.getOperatorId()).isEqualTo(testUser.getId())` compares `1L` to `1L` rather
  than passing on a null-equals-null coincidence. It distinguishes "survived" from "claimed" as its
  `as(...)` message says.
- **Strict-stubs cleanliness.** Every stub in the new test is consumed on the traced path, including
  `pickingorderRepository.save(any())`. No `UnnecessaryStubbingException` risk.
- **Integration-test reflection harness still valid.** The edit does not touch `@Query`, the three named
  parameters, or their uniqueness, so `productionSql()`'s positional rebinding and its
  `doesNotContain(":")` assertion are unaffected.
- **Exact-set test.** `containsExactlyInAnyOrder(HELD_EXPIRED, ORPHAN_LOCKED)` still fails if any other
  fixture row leaks in, so the conjunction pin survives the widening. Order-independence is the right
  relaxation — the query has no `ORDER BY`.
- **Renamed tests still match what they assert.** `orphanLockIsSelectedAndSelfHealed` asserts
  `contains`; `releaseSetIsExactlyTheHeldExpiredOrderAndTheOrphanLock` asserts exactly those two. The
  updated comment on `reservedButNotLockedOrderIsNotSelected` is now accurate: with the predicate gone,
  that row and `ALREADY_RELEASED` are what pin `lockedtooperator = true`.
- **Live data.** `orphan_locked = 0` and `lockedtooperator IS NULL = 0` on all four tenant databases I
  could reach — `wms2-hydra` (prd), `nywh-hydra-uat`, `c1wh-shipitez-uat`, `wms2-wineco-dev`. The
  author's count reproduces. Two facts worth recording alongside it: no tenant currently holds *any*
  locked row, and only `wms2-wineco-dev` has a `RAPID_PICKING` section at all (1 of 15; every other
  tenant is `TOTES_ON_CART` only). The job filters on `sectionpickingtype = RAPID_PICKING`, so on
  today's data both `e818ff11` and this follow-up are no-ops in production. That is not an argument
  against the change, but it does mean neither fix can be validated against live traffic, and the
  integration test is the only instrument that will ever exercise it.
- **SDR route impact.** `PickingorderRepository` is `@RepositoryRestResource`-exported and this method
  keeps its `@RestResource`, so `…/pickingorder/search/getPickingOrdersToReleaseExpiredPickingOrders`
  remains reachable. Dropping the predicate only widens a read-only result set by the orphan shape —
  strictly a superset of the change already documented on the ticket, no new field or verb exposed. Worth
  one clause on the ticket ("held orders **and orphan locks**"); nothing more.
- **Style.** The guard matches the `getOperatorId() != null &&` idiom at lines 464, 753 and 1364 of the
  same file. Comment placement, `SBDEV-####:` prefix, decision-pin phrasing and the "flip deliberately"
  convention all match the sibling `totesOnCartOrderIsNotSelected` pin and the surrounding file.
- **Unrelated and left alone.** `SharedService:60` dereferences `goodsReceipt.getOperatorId()` into
  `findById` without a null check — a different entity and subsystem, outside this diff's blast radius,
  mentioned only so it is not mistaken for a missed sibling.
