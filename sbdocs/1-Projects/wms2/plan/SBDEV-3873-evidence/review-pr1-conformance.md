# SBDEV-3873 PR 1: conformance review (Phase 3a, independent verifier lane)

- Date: 2026-10-22
- Worktree: `.claude/worktrees/wms2-api/SBDEV-3873`, HEAD `37cfa4ee`, tracked tree clean
- Commits: `6e7a4f31` (tests), then `37cfa4ee` (fix)
- Scope: §0 S5 and the PR-1 part of S8 (T5); §5 A1 and A2; §8 AC-1..AC-10 and AC-2b; §8.1 m1..m10 with their b-variants
- PR-W and PR 2 items are out of scope

## Verdict

**PASS with 1 PARTIAL (T5, a stale message) and 3 Low deviations.** All ten PR-1 ACs plus AC-2b are VERIFIED by fresh test runs, and 14/14 mutants are killed.

## Fresh evidence

The command, run by this lane at 13:41–13:42:

```
mvn -o -q test -Dtest='Sbdev3017TrancheGateContextTest,AdviceSetCommentContextTest,SdrCommentOnlyWritableContextTest,SdrPatchFieldFenceContextTest,AdviceServiceUnitTest,AdviceStateReadOnlyContextTest'
```

It exited 0 and the log has no `[ERROR]` lines. Counts from `target/surefire-reports` (timestamps 13:41–13:42):

| Class | tests | fail | err | skip |
|---|---|---|---|---|
| Sbdev3017TrancheGateContextTest | 5 | 0 | 0 | 0 |
| AdviceSetCommentContextTest | 13 | 0 | 0 | 0 |
| SdrCommentOnlyWritableContextTest | 5 | 0 | 0 | 0 |
| SdrPatchFieldFenceContextTest | 3 | 0 | 0 | 0 |
| AdviceServiceUnitTest, all nested classes (incl. `$SetComment` 3/3) | 62 | 0 | 0 | 0 |
| AdviceStateReadOnlyContextTest (T5) | 2 | 0 | 0 | 0 |

The five classes the brief names total 88 tests, which matches the mutation harness's `ran=88`.

## §0 in-scope rows

### S5: VERIFIED

**`Advice.java`.** Every declared field except `comment` carries `@ReadOnlyProperty`:

- name, number, allowoverdelivery, allowshortdelivery, dayofdelivery, dayofdeliveryuntil
- deliverynotenumber, externalid, shippedfrom, shippedto
- state (pre-existing), type, clientId, supplier, transferId, purchaseordernumber, note

`comment` is left unannotated.

**`Cyclecount.java`.** All declared fields are annotated: number, name, clientId, type, subtype, state (pre-existing) and comment.

These sets are enforced by the runtime invariant `SdrCommentOnlyWritableContextTest`, so this review does not rely on a list.

### S8 / T5: PARTIAL

The diff does not touch `AdviceStateReadOnlyContextTest`. `commentRemainsWritable` still passes, but its rationale is stale:

```
.as("the fix must be scoped to `state`; wms2-web-ui's saveComment PATCHes exactly "
        + "{id, comment} and must keep working")
```

The class javadoc lines 51–56 say the same: "`comment` ... is untouched by this fix".

After PR 1 the fence is no longer scoped to `state`. The UI caller is moving to POST `/setComment` in PR-W. §5 Fix C says: "T5 ... changes in **PR 1**: its rationale moves to the new endpoint plus the stop-gap invariant."

The assertion itself, comment writable, is still correct for PR 1, so this is a message and javadoc fix only. It was not done.

## §5 Fix A1: VERIFIED

**Annotations.** As listed under S5.

**Comments.** Comments on `Advice` and `Cyclecount` explain the fence. The SBDEV-3215 comments got "(SBDEV-3873: this comment predates the field fence ...)" addenda.

**Invariant test (`SdrCommentOnlyWritableContextTest`).**

- It reads runtime `PersistentEntities` and treats a property as declared when `p.getField() != null && p.getField().getDeclaringClass() == type`. It does not use `getOwner()`.
- `containsExactly("comment")` for Advice and `isEmpty()` for Cyclecount.
- For both classes it cross-checks the scan against reflection (`getDeclaredFields`, non-static, non-synthetic).
- `writableProperties_shouldAllHaveABackingField_whenScanned` fails on a writable property with `getField()==null`.

**Residual inherited fields** (id, version, created, modified) were left open, as the plan accepts for PR 1.

## §5 Fix A2: VERIFIED

**Controller.** `AdviceController.setComment`:

```java
@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_INBOUND_BOL)
@PostMapping(path= "/setComment", consumes = "application/json", produces = "application/json")
```

- The body is the typed record `AdviceCommentRequest(Long id, String comment)`.
- The response is `{id, comment}` with 200.

**Service.** `AdviceService.setComment`:

- It is annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.
- A null id raises `ApiInvalidParameterException`, which `RestExceptionHandler:60` maps to 422.
- A comment with `length() > 255` raises the same exception, before the load.
- It loads with `findById(id).orElseThrow(() -> new EntityNotFoundException("Advice", id))`, then calls `setComment` and `save`. That is an entity save, so `@Version` applies.
- It calls no state method and no OMS or outbox service.

## §8 PR-1 acceptance criteria

| AC | Status | Evidence |
|---|---|---|
| AC-1 | VERIFIED | `Sbdev3017TrancheGateContextTest` has `row("AdviceController","/v3/advice/setComment","WEB_UI_VIEW_INBOUND_BOL")` and `hasSize(232)`. 5/5 pass. |
| AC-2 | VERIFIED | `setComment_shouldWriteOnlyTheComment_whenBodyCarriesOtherAdviceFields` uses `BaseRollbackIntegrationTest` (H2, no class-level tx). It seeds a RETURN advice and POSTs comment plus externalid, clientId 999, type REGULAR, allowoverdelivery true and state OPEN. It asserts comment=="x", that every reflected declared column except comment equals its seeded value, that `created` is unchanged, and that `version == seeded+1`. Pass. |
| AC-2b | VERIFIED | `setComment_shouldLeaveVersionUnchanged_whenCommentIsAlreadyTheStoredValue`: version equals the seeded value. Pass. |
| AC-3 | VERIFIED | webAppContext MockMvc; the mode is pinned explicitly (`SdrGuardMode.OFF`); `AccessService` answers per function from `HELD`. No-function caller: 403, `requiredFunction`==INBOUND_BOL, comment and version unchanged. CYCLECOUNT-only caller: 403, row unchanged. INBOUND_BOL caller: 200, comment written. 3 pass. |
| AC-4 | VERIFIED | 256 chars gives 422 with comment and version unchanged; 255 chars gives 200 and is stored. Pass. The unit twin `setComment_shouldRejectBeforeLoading_whenCommentExceeds255Chars` also pins "before load" with `verifyNoInteractions(adviceRepository)`. |
| AC-5 | VERIFIED | Three tests, each asserting the DB value after reload: `""` stores `""`; `null` stores NULL; `{id}` with no key stores NULL. Pass. |
| AC-6 | VERIFIED | Unknown id gives 404. It also asserts ProblemDetail `title=="Entity Not Found"` and that `detail` contains "Advice", so a no-handler 404 cannot pass. Pass. |
| AC-7 | VERIFIED | Placed where the plan says: `AdviceServiceUnitTest$SetComment.setComment_shouldSaveOnlyTheCommentAndNotifyNoOne_whenAdviceExists` runs the real `@InjectMocks` service with `verifyNoInteractions(omsNotificationService, outboxService, messageService)`. Those are AdviceService's real OMS, outbox and message collaborators (fields at AdviceService:64, :84, :90). There is also an HTTP twin that counts outbox_message and message rows. Pass. Assessment of the deviation is below. |
| AC-8 | VERIFIED | `SdrCommentOnlyWritableContextTest`, 5/5, as described under A1. |
| AC-9 | VERIFIED | `SdrPatchFieldFenceContextTest`. The mode is set explicitly to ENFORCE_RULED and the caller holds INBOUND_BOL+CYCLECOUNT. Advice PATCH `{externalid:EVIL, comment:y}` returns 2xx, externalid unchanged, comment=="y". Cyclecount PATCH `{name:EVIL}` returns 2xx, name unchanged. JSON-Patch `replace /externalid` returns 400, unchanged. 3/3 pass. |
| AC-10 | VERIFIED | `setComment_shouldReturn422_whenIdIsMissing`: 422 and comment unchanged. Unit twin `setComment_shouldRejectBeforeLoading_whenIdIsMissing`. Pass. |

## §8.1 mutants m1–m10 and b-variants

Source: `mutation-pr1.md` and `mutants.py`. I checked the anchors in `mutants.py` but did not re-run the mutants.

| Mutant | Plan: must turn red | Recorded kill | Status |
|---|---|---|---|
| m1 | AC-3 403 cases, AC-1 | both AC-3 403 tests plus tranche drift "1 of 232" | VERIFIED |
| m1b | AC-3 CYCLECOUNT-only, AC-1 | 13 AdviceSetComment failures incl. the m1b-tagged one, plus tranche drift | VERIFIED |
| m2 | AC-2 | AC-2 declared-columns assertion (m2 message) | VERIFIED |
| m3 | AC-4 | unit `...Exceeds255Chars` (attributable); context test errors via DataIntegrityViolation | VERIFIED |
| m4 | AC-2 version | AC-2 `version == seeded+1` (m4 message) | VERIFIED |
| m4b | AC-2b | AC-2b version-unchanged (m4b message) | VERIFIED |
| m5 | AC-8, AC-9 | AC-8 Advice writable set; AC-9 PATCH and JSON-Patch | VERIFIED |
| m5b | AC-8, AC-9 | AC-8 Cyclecount; AC-9 cyclecount PATCH | VERIFIED |
| m6 | AC-8 | AC-8 Advice writable set | VERIFIED |
| m6b | AC-8 reflection cross-check | first apply refused (anchor ×3), re-run killed: 4 failures incl. both `...DeclaredScan_shouldEqualReflection` | VERIFIED, but the re-run output is summarised, not verbatim |
| m7 | AC-7 | Mockito NoInteractionsWanted on `outboxService` | VERIFIED, with a deviation (below) |
| m8 | AC-5 | AC-5 null and absent-key tests | VERIFIED |
| m9 | AC-6 | AC-6 404 (m9 message) | VERIFIED |
| m10 | AC-10 | unit missing-id (attributable); context test errors via InvalidDataAccessApiUsage | VERIFIED |

## Deviations and gaps

1. **T5's message and javadoc are stale.** The PARTIAL above. Risk: low (documentation inside a guard).
   - Fix: reword `commentRemainsWritable`'s `.as(...)` and the class javadoc lines 51–56. The new text should say that `comment` is the single SDR-writable declared Advice field for the stop-gap, pinned by `SdrCommentOnlyWritableContextTest`, and that the UI moves to POST `/v3/advice/setComment`.

2. **The AC-7 HTTP twin's javadoc is stale.** `AdviceSetCommentContextTest` still says "The unit-level `verifyNoInteractions` test is still owed by the implementation." It is no longer owed: `AdviceServiceUnitTest$SetComment` delivers it. Risk: low. Fix: drop that sentence.
   - On the AC-7 placement: it conforms. The authoritative assertion is the real-service unit test, as the plan requires. The HTTP twin is additive.
   - The twin cannot see a read-only collaborator call, and m7 was such a call (deviation 3). For an `enqueue`, the twin's outbox-row count would also turn red. Acceptable.

3. **m7 was applied as `outboxService.isKeyPresent("mutant")`, not the plan's `outboxService.enqueue`.** Risk: low.
   - `verifyNoInteractions` fails on any call, so the plan's literal mutant is killed a fortiori by the same test.
   - Record this in the PR body's mutant table so the substitution is visible.

4. **The §6 file list differs from what shipped.** Risk: low.
   - §6 names `AdviceSetCommentIntegrationTest` plus an `AdviceControllerUnitTest` `@Nested SetComment`.
   - Shipped instead: `AdviceSetCommentContextTest`, `SdrPatchFieldFenceContextTest` (AC-9), and `AdviceServiceUnitTest$SetComment`.
   - `AdviceControllerUnitTest` has no `setComment` test.
   - No AC depends on the controller unit test. The plan places AC-7 away from it, and AC-3 needs the real dispatch. So nothing in scope is lost.
   - Fix: reconcile §6 when §15 is updated.

5. **Plan §15 still says "Not started."** This is bookkeeping for the executor at PR time. It is not a PR-1 code defect.

## Not checked by this lane

- The full suite against the baseline. That is a separate floor item, owned by the executor.
- The dev probes M1 and M1b, which run after merge.
