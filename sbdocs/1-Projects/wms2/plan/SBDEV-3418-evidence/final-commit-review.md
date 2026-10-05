# SBDEV-3418 — independent review of the unreviewed final commit `ed2ed97a`

**Lane:** final-commit-review (5th lane; the only look at `ed2ed97a`)
**Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3418-final`, detached at `ed2ed97a`
**Diff under review:** `git diff afb67376..ed2ed97a` — 6 files, +167/−33
**Date:** 2026-09-23

## Verdict

**CHANGES REQUESTED.** Not safe to merge as-is.

The two Medium test-adequacy fixes (M1/C5 and M2/AC-1b) are **correct, measured and verified by
this lane** — they do exactly what the commit message claims, and I reproduced the mutation kill.

The problem is the Low-severity "sibling sweep" in the same commit. It **deleted a correct
statement from two production javadocs and replaced it with a false one**, asserted as measured
fact, and entrenched a third false claim with fabricated-sounding evidence. The claim that
`wms2-mobile-ui util/apiError.js` "does not exist anywhere in that repo" is wrong: the file is
present on `origin/develop`, `origin/main` **and** `origin/release`, added 2026-08-28, and its
`toastApiError` is wired into the `catch` block of **every** truck-loading and palletize store
action. The commit was derived from a local `wms2-mobile-ui` checkout that is **77 commits / ~7
weeks stale** — the exact failure the repo memory *"Derive cross-repo claims from origin/develop"*
exists to prevent.

On this ticket's own standard ("a confidently-worded false claim is a finding at the same severity
as a code defect"), that is a blocker. No runtime behaviour is affected — all six changes outside
the two tests are comments — so the fix is three javadoc edits, not a redesign.

## Summary table

| # | Sev | File | Issue |
|---|-----|------|-------|
| F1 | **High** | `MobilePalletizingService.java`, `MobilePalletizeWriteService.java`, `MobileTruckLoadingService.java` | The "`util/apiError.js` does not exist / the handheld shows a fixed network-error string" correction is **false on all three sites**. The file exists on develop+main+release and *is* what renders the ProblemDetail `detail`. A previously-correct statement was inverted. |
| F2 | Medium | `MobilePalletizingService.java` | The D2 design rationale was rewritten on F1's false premise, inflating a deliberately calibrated "UX-consistency improvement, **not** a rescue" into "the difference between a named, actionable message and a generic network error". The original calibration was the accurate one. |
| F3 | Low | `MobileTruckLoadingWriteService.java` | The lock-set derivation recipe fails as written (`No such file or directory`, exit 2) and, as a *rule*, cannot see the one non-repository lock acquisition inside `transferUnitLoadToLocation`. |
| F4 | Low | `MobileTruckLoadingWriteService.java` | Merged `TruckLoadOutcome` javadoc carries `@param` for 2 of the record's 5 components. Pre-existing, not introduced — but the merge was the moment to close it. |
| F5 | Info | `MobileTruckLoadingWriteServiceUnitTest.java` | C5 uses inline FQNs (`java.util.List.of`, `net.aim_ai.wms.model.Customerorder`) where the class already imports the short names. |

Items explicitly checked and found **correct** are listed under "Verified good" below, with evidence.

---

## F1 — High — the mobile-client correction is false on all three sites

### What the commit asserts

`MobilePalletizingService.java`:

> `⚠ An earlier revision of this sentence said it did, as a toast "via {@code wms2-mobile-ui util/apiError.js}" … **That file does not exist anywhere in {@code wms2-mobile-ui}**, and the real client drops every non-2xx into a {@code catch} that shows a fixed {@code "Error: Request failed due to a network or server issue. Please retry."} string`

`MobilePalletizeWriteService.java`:

> `⚠ The handheld does NOT render that detail: an earlier revision said it did, "as a toast (wms2-mobile-ui util/apiError.js)", and no such file exists in that repo.`

`MobileTruckLoadingService.java`:

> `A 409 {@code ProblemDetail} is not a shape it renders. Measured, not assumed: … every non-2xx lands in its {@code catch} and shows the fixed string … so the server's {@code detail} never reaches the operator.`

### Evidence that all three are false

The file exists on every long-lived branch:

```
$ cd /Users/np1076/dev/spk/owl/v2/wms2-mobile-ui
$ for ref in HEAD origin/develop origin/main origin/release; do git ls-tree -r "$ref" --name-only | grep -i apierror; done
--- HEAD ---            (absent)
--- origin/develop ---  test/util/apiError.spec.js , util/apiError.js
--- origin/main ---     test/util/apiError.spec.js , util/apiError.js
--- origin/release ---  test/util/apiError.spec.js , util/apiError.js
```

It was added specifically to fix the behaviour the commit now claims is current:

```
3174486b 2026-08-28 fix(errors): surface the backend's error message instead of a fixed generic red bar
```

`origin/develop:util/apiError.js` prefers exactly the field in dispute:

```js
if (typeof data.detail === 'string' && data.detail.trim()) {
  return data.detail
}
```

and its own header names the old behaviour as the *bug it removed*:

```js
 * Every store action used to answer ANY rejected request with one fixed string — "Error: Request
 * failed due to a network or server issue. Please retry." — throwing away the message the backend
 * sent.
```

The truck-loading store's `scanGate` — the exact action `MobileTruckLoadingService.scanGate`
answers — calls it on `origin/develop`:

```js
  async scanGate(context, data) {
    ...
    } catch(error) {
      console.log(error),
      toastApiError(this.$toast, error)
```

So does every palletize action (`origin/develop:store/palletizing.js`, line 1 `import { toastApiError } from '~/util/apiError'`; `scanParcel`, `scanPallet`, `rapidScanPallet`, `rapidScanParcel` each call `toastApiError` in their catch). All 13 stores import it.

`plugins/axios.js` `onError` does not intercept first — it toasts only for `status === 403 && body.reason`, so a 409 rejects straight through to the store catch:

```js
    const status = error && error.response && error.response.status
    if (status === 403 && body.reason) {
```

And the `detail` the operator would see is the one the deleted text quoted verbatim
(`RestExceptionHandler.java`):

```java
    protected ResponseEntity<ProblemDetail> handlePessimisticLock(PessimisticLockingFailureException ex) {
        ProblemDetail problemDetail = ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT, "The record is currently locked by another operation. Please retry.");
```

### Why the author got it wrong

```
$ git -C v2/wms2-mobile-ui status --short --branch
## develop...origin/develop [behind 77]
$ git log -1 --date=short --format='%h %ad'          # local HEAD
aa3a4dde 2026-07-28
$ git log origin/develop -1 --date=short --format='%h %ad'
5b1d3363 2026-09-16
```

The local checkout predates the fix by a month. A `find` on the working tree returns nothing, which
reads exactly like "the file does not exist anywhere in that repo".

### Impact

No runtime behaviour. But the commit (a) deleted a correct statement, (b) replaced it with a false
one at *higher* confidence ("Measured, not assumed", "does not exist **anywhere**"), and (c) left
that false claim in three `src/main` files where the next reader will trust it. The "Corrected under
SBDEV-3418" attribution makes it harder, not easier, to unwind.

### Ask

Revert all three to the substance of the pre-`ed2ed97a` text (the handheld **does** render the
ProblemDetail `detail` as a toast, via `wms2-mobile-ui util/apiError.js`), and cite
`origin/develop`, not a working tree. Deleting the whole cross-repo claim is also acceptable — it is
not load-bearing for any assertion in this class.

---

## F2 — Medium — the D2 rationale was inflated on F1's false premise

`MobilePalletizingService.java`, introduced by this commit:

```
 * So the translation buys
 * MORE than "UX consistency": it is the difference between a named, actionable message and a
 * generic network error.
```

It replaced:

```
 * That is a UX-consistency
 * improvement, <b>not</b> a rescue from an unhandled failure.
```

With `apiError.js` in place, the untranslated 409 already yields a named, actionable message ("The
record is currently locked by another operation. Please retry."). The claimed difference does not
exist, and the sentence it replaced was the correctly calibrated one. This matters beyond wording:
it is the stated justification for plan §3.6 (D2), so a future reader weighing whether D2 is worth
keeping is being handed an inflated case for it.

Restore the "UX-consistency improvement, not a rescue" framing.

---

## F3 — Low — the lock-set derivation recipe does not work, and cannot see the lock that matters

`MobileTruckLoadingWriteService.java`:

```
 *       Derive the current set with
 *       {@code grep -n "Repository\.\(find\|get\)" UnitloadBusinessService.java} inside
 *       {@code transferUnitLoadToLocation}. The three that matter:
```

Two problems.

**As written it fails.** There is no `UnitloadBusinessService.java` at any root a reader is likely
to be in:

```
$ grep -n "Repository\.\(find\|get\)" UnitloadBusinessService.java
grep: UnitloadBusinessService.java: No such file or directory   (exit 2)
$ grep -c "Repository\.\(find\|get\)" src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java
44
```

Exit 2 vs exit 1 is the only thing distinguishing that from a true zero — and it prints 44 hits for
the *whole file*, not for the method, so the "inside `transferUnitLoadToLocation`" qualifier is
doing work the command does not do.

**As a rule it is incomplete in the one direction that matters.** The pattern matches only
`Repository.find|get`, so it cannot see the one *locking* call inside the method:

```java
        if (PickLineActivityCodeClassifier.classify(activityCode, null) == PickLineActivityCodeClassifier.Bucket.BLOCK_REALIGN) {
            List<Long> treeStockUnitIds = pickLineRealignmentService.collectStockUnitIdsForUnitloadTree(unitload);
            pickLineRealignmentService.lockOwningPickingorders(treeStockUnitIds);
        }
```

It also misses `entityManager.refresh(destinationLocation)` and the three
`…Repository.findNameById` / `stockunitRepository.findByUnitloadId` reads.

Mitigating, and why this is Low rather than Medium: `lockOwningPickingorders` is **unreachable from
this path**. `scanGate` passes `WmsConstants.CODE_TRUCK_LOADING`, which is not in
`PickLineActivityCodeClassifier.BLOCK_REALIGN_CODES` (that set is `CODE_MOVE_FIX_ASSIGNMENT`,
`CODE_MANUAL_TRANSFER`, `CODE_TRANSFER`, `CODE_ON_HOLD`). So the javadoc's *substance* — the three
named business rows, and the "benign today" verdict — is correct, and I verified the four
reference-row repositories it now names are all genuinely there
(`fixLocationAssignmentRepository.findByAssignedlocationId`,
`locationConstraintRepository.findByStoragelocationtypeId`, `locationTypeRepository.findById`,
`unitloadRepository.findByCarrierunitloadId`).

Suggested: give the path (`src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`),
widen to `\(Repository\|Service\)\.` or drop the recipe and state the rule instead ("every read
inside `transferUnitLoadToLocation` that is not one of these three is configuration/reference"),
and add one sentence noting the `BLOCK_REALIGN`-gated Pickingorder lock and why `CODE_TRUCK_LOADING`
misses it.

---

## F4 — Low — `TruckLoadOutcome` javadoc documents 2 of 5 components

The merge itself is **correct** and the stated reason is true: Javadoc binds only the last of two
adjacent block comments, so the detachment rationale genuinely was being dropped. Good catch.

But the merged block is still:

```java
     * @param gateName          the gate the pallet was moved to, …
     * @param gateNewlyAssigned true only when this scan is what put the gate on the BOL …
     */
    public record TruckLoadOutcome(List<Customerorder> orders, Unitload pallet, Billoflading bol,
                                   String gateName, boolean gateNewlyAssigned) {
```

`orders`, `pallet` and `bol` have no `@param`. The two present are in correct relative order. This
is pre-existing (the pre-merge second block had the same two), so the merge did not degrade it —
but it is the one edit that was already touching this block.

---

## F5 — Info — C5 style

`MobileTruckLoadingWriteServiceUnitTest.java` uses `java.util.List.of(2L, 3L)` and
`new net.aim_ai.wms.model.Customerorder()` inline; the surrounding class uses the imported short
names. Cosmetic only.

---

## Verified good — with evidence

### 1. C5 genuinely discriminates (brief item 1) — CONFIRMED, measured

I reproduced the mutation kill in this worktree. Baseline:

```
MobileTruckLoadingWriteServiceUnitTest   tests="12" errors="0" skipped="0" failures="0"
```

Applied the hoisted-guard mutant the javadoc names (all-duplicates pass first, then the orphan
pass), re-ran, and restored the file from a `/tmp` copy (no `git checkout`/`restore`/`stash` was
used at any point; final `git status` is clean):

```
tests="12" errors="0" skipped="0" failures="1"
  failing: scanGate_shouldReportTheEarlierParcelsDefect_whenAPalletCarriesBothAnOrphanAndADuplicate
  message: Expecting throwable message: "Too many orders with the same parcel found"
           to contain: "PARCEL001" but did not.
```

Exactly one of twelve, attributable, and the diagnostic names both sides of the inversion — the
commit message's claim is accurate. C3 and C4 stayed green under the mutant, confirming they cannot
see the ordering.

The fixture really does produce both defects. `parcelIds` is the stub's
`findIdsByCarrierunitloadIdOrderById(1L) → [2L, 3L]`; `findParcelOrderIdsByParcelIdIn` returns only
rows for parcel **3** (twice), so parcel 2 is absent from `orderIdByParcelId` (orphan) and parcel 3
lands in `duplicateParcelIds`. The loop under review is:

```java
        for (Long parcelId : parcelIds) {
            if (duplicateParcelIds.contains(parcelId)) {
                throw new BusinessException("Too many orders with the same parcel found");
            }
            if (!orderIdByParcelId.containsKey(parcelId)) {
                throw new BusinessException("unexpectedUnitLoadDoesNotHaveOrder",
                        lockedParcels.get(parcelId).getLabelid());
            }
        }
```

**No unguaranteed `parcelIds` ordering.** In the test the order is fixed by the stub; in production
by the query name (`…OrderById`), which the class javadoc already flags as load-bearing ("The
ordering comes from the query, not from a sort here, so it cannot be dropped by a call-site edit").

**`hasMessageNotContaining("Too many orders")` is not doing something subtle.** I traced
`BusinessException.getMessage()`: the 1-arg ctor sets `key="placeholder"`, and both
`messages.properties` and `messages_en_US.properties` define `placeholder=%1s`, so the hoisted
mutant's message resolves to the literal `"Too many orders with the same parcel found"`. The
assertion fires. The orphan side is robust to bundle/locale fallback too: if
`unexpectedUnitLoadDoesNotHaveOrder` resolves (it is in `messages_en_US`, `%1s` behaving as a
min-width-1 `%s`) the message is `Unexpected unit load PARCEL001 found, has no order!`; if the
default locale falls back to the base bundle where the key is absent,
`concatenateKeyAndParameter` yields `unexpectedUnitLoadDoesNotHaveOrder, 'PARCEL001'`. `PARCEL001`
is present either way. AssertJ evaluates `hasMessageContaining` first, which is why the mutant's
reported failure is the one the commit message quotes.

### 2. The new AC-1b witness is genuinely non-vacuous (brief item 2) — CONFIRMED by source

PHASE D ordering, read from `MobileTruckLoadingWriteService.scanGate`:

```java
        if (pendingOutboundLocationId != null) {
            bol.setOutboundlocationId(pendingOutboundLocationId);
        }
        …
        bol = billofladingRepository.save(bol);
        …
        unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false, …);

        BillofladingPosition palletBOLPos = billofladingPositionService.createEntity(bol, operator);
```

The gate write and its `save` are **both ahead** of `transferUnitLoadToLocation`; the first
`createEntity` is **after** it. So the old witness (`findByBillofladingId(bolId).isEmpty()`) really
was structurally vacuous for a failure injected at the transfer, and the new one really is written
before the throw. The control is meaningful: `newBol()` never sets `outboundlocationId`, so
`before.getOutboundlocationId()` is genuinely null, and the guard the test relies on
(`!ignoreLock && destinationLocation.getEntityLock() != NOT_LOCKED →
FacadeException("STORAGELOCATION_LOCKED")`) fires after the gate write.

**The "no annotation mutant can kill a data witness here" claim holds.**
`transferUnitLoadToLocation` carries its own `rollbackFor = {BusinessException, FacadeException}`,
so the physical transaction is already rollback-only when control returns; with `rollbackFor`
deleted *or* replaced by `noRollbackFor = FacadeException.class`, the outer boundary still cannot
commit and still raises `UnexpectedRollbackException`. The javadoc says exactly this and explicitly
withdraws the witnesses as evidence for the annotation ("they must not be cited as evidence that
the annotation is pinned. The exception assertion is what pins it"). **It does not overclaim** — it
claims only discrimination against a structural regression (the header write escaping the boundary,
e.g. a `REQUIRES_NEW` split), which is exactly what it can catch.

⚠ **Not executed by this lane.** Per the lane brief I ran no integration test, so AC-1b's *result*
is unverified here; the reasoning above is static. It does compile (`mvn -o test` compiles the whole
`src/test` tree and exited 0).

### 3. The `gateNewlyAssigned` claims about develop — CONFIRMED against `origin/develop`

`origin/develop:MobileTruckLoadingService.java` `scanGate`:

```java
        if (billOfLading.getOutboundlocationId() == null) {
            billOfLading.setOutboundlocationId(gate.getId());
            truckLoadingMobileDTO.setBolGateName(gate.getName());
        } else if (!billOfLading.getOutboundlocationId().equals(gate.getId())) {
```

— the `setBolGateName` is in the "no gate defined yet" branch **only**, as claimed. And `loadOrder`:

```java
        truckLoadingMobileDTO.setBolGateName(billOfLading.getOutboundlocationId() == null ?
            null : locationRepository.findById(…).getName());
```

— the setter runs unconditionally (conditional *value*), on a different method and a different
request, as the new parenthetical says. Both accurate.

### 4. Other claims introduced or edited by this commit

| Claim | Verdict |
|---|---|
| "Javadoc binds only the last [of two adjacent blocks]" | **True** — the merge rescues a genuinely dropped paragraph |
| `O(1)` → `O(log n)` for `TreeSet.add`, and "the natural ordering of Long IS the ascending order the canonical lock sequence requires" | **True**; the surrounding claim survives the edit intact (`distinctOrderIds = new TreeSet<>()`) |
| `StaleObjectStateException` → `ObjectOptimisticLockingFailureException` → 409 with `retryable=true`, not 500 | **True** — `RestExceptionHandler.handleOptimisticLock` sets `HttpStatus.CONFLICT` and `problemDetail.setProperty("retryable", true)` |
| `@AfterEach`: "`findByBillofladingId` is a plain derived query, so a null argument yields `is null` and an empty list rather than throwing" | **True enough** — Spring Data's `SIMPLE_PROPERTY` null handling builds `isNull`; either way it returns empty rather than throwing, so the retracted "was a reported failure" framing is the right correction |
| "the three business rows … `unitloadRepository.findById(carrierunitloadId)`, `locationRepository.findById(storagelocationId)`, and the reference rows `locationTypeRepository` / `fixLocationAssignmentRepository` / `locationConstraintRepository` / a second `findByCarrierunitloadId`" | **All present** in `transferUnitLoadToLocation`; see F3 for what the *recipe* misses |
| "12/12 write-service unit, 21/21 outer unit" | **True** — `MobileTruckLoadingWriteServiceUnitTest` 12/12 and `MobileTruckLoadingServiceTest` 21/21, both re-run in this worktree at `ed2ed97a` |

Note for anyone re-running: `MobileTruckLoadingServiceUnitTest` (11 tests, nested classes) is a
**different** class from `MobileTruckLoadingServiceTest` (21). The "21" refers to the latter.

### 5. Did the Low fixes break anything? — No

Nothing in this commit outside the two test files is executable. Full local run at `ed2ed97a`:

```
MobileTruckLoadingWriteServiceUnitTest        12/12 green
MobileTruckLoadingServiceUnitTest (+nested)   11/11 green
MobileTruckLoadingServiceTest                 21/21 green
```

(23 and 21 respectively; `mvn -o test -Dtest=…`, JaCoCo emits a harmless
`Unsupported class file major version 69` instrumentation warning on Mockito-generated auxiliary
classes that does not affect results.)

---

## Method / hygiene

- Every command run in `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3418-final`.
  `v2/wms2-mobile-ui` read-only, via `git show origin/<ref>:<path>` — never the working tree, and
  never edited.
- No `git checkout --`, `git restore` or `git stash`. The mutant was applied by script over a
  `/tmp`-scratchpad copy and restored with `cp`; closing `git status` is clean.
- `pgrep -fl "maven|surefire|failsafe"` was empty before each run. No `mvn verify`, no
  `*IT` / Testcontainers run — the sibling lane's postgres was never touched.
- Stale-surefire-XML trap avoided: reports were deleted before the final combined run, and counts
  read from freshly written XML.

## What has to change before merge

1. **F1** — fix the three mobile-client claims in `MobileTruckLoadingService`,
   `MobilePalletizingService` and `MobilePalletizeWriteService`; cite `origin/develop`.
2. **F2** — restore `MobilePalletizingService`'s calibrated "UX-consistency improvement, not a
   rescue" framing for D2.
3. **F3** — repair or replace the lock-set derivation recipe.
4. **F4/F5** — optional, at the author's discretion.

None touches executable code, so no re-run of the suite is required beyond a compile — but per the
repo rule that fix commits do not ship unreviewed, the corrections themselves need one more look,
and the `wms2-mobile-ui` checkout should be fetched before that look is taken.
