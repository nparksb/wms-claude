# SBDEV-1512 Phase 1 — CONFORMANCE review

**Question graded:** did the implementation build what the plan specifies? (Not "is the code good.")
**Verdict: PARTIAL — the feature's happy path conforms; four specified behaviours were not built, and the §7 test programme is ~4/18 complete.**

- **Tree read (authoritative):** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1512-conformance` — a worktree used by this lane alone, **detached at `5136ed87`**, working tree clean, `git merge-base HEAD origin/develop` = `4bef7e77`, same 13-file / 1175-insertion diffstat as the branch tip. `v2/wms2-api` was never read.
- **Plan read:** `sbdocs/1-Projects/wms2/plan/SBDEV-1512-receive-damaged-from-returns.md` (2077 lines), §0, §3.1–§3.7, §4, §5.2, §7.1–§7.4, §8.

> ### ⚠ Provenance: every number and every citation below was re-derived in the isolated tree
>
> An earlier pass of this lane worked in the shared `…/wms2-api/SBDEV-1512` worktree. **All of it was
> re-run from scratch here and nothing from the shared tree is relied on.** Two things justify that
> beyond the instruction:
>
> 1. **The shared tree is being modified while it is read.** At 13:20 a `ps` census showed a running
>    `python3` rewrite inside `…/worktrees/wms2-api/SBDEV-1512` replacing
>    `resolveBoxtypeId(position), totalAmount, damagedAmount` with `… (int) totalAmount, damagedAmount`
>    — i.e. another lane is mid-edit on `ReturnAdviceAutoReceiveService.java`, widening `totalAmount`
>    and adding a narrowing cast. **That edit is NOT part of the commit under review:** at `5136ed87`
>    the declaration is still `int totalAmount = position.getAmountOfBottles() + damagedAmount;`
>    (line 378). A source citation taken from the shared tree after that point would grade code the
>    branch does not contain. Nothing here is.
> 2. **Three other Maven builds were live** (in `…/SBDEV-1512-codereview`, `…/SBDEV-1512`, and an
>    `SBDEV-3321` scratch tree). Those are *separate* worktrees with separate `target/` directories,
>    so the measured 238-errors-when-racing effect — which is same-worktree `target/` contention —
>    does not apply to the runs below. The residual cross-worktree hazard is the **Testcontainers
>    `withReuse(true)` container**, which is shared process-wide; it would surface as an IT red, and
>    both IT lanes came back green, so it did not fire.

## 1. Commands — re-run in the isolated tree, not trusted from anywhere

| Command | Result in `SBDEV-1512-conformance` @ `5136ed87` | Reported to me | Verdict |
|---|---|---|---|
| `mvn -o clean compile` | `BUILD SUCCESS` | — | ✅ |
| `mvn -o test` | `Tests run: 6638, Failures: 0, Errors: 0, Skipped: 1` / `BUILD SUCCESS` | 6638/0F/0E/1S | ✅ **confirmed exactly** |
| `mvn -o verify -Dit.test=ReturnAdviceAutoReceiveIntegrationTest …` | `Tests run: 9, Failures: 0, Errors: 0, Skipped: 3` / `BUILD SUCCESS` | green | ✅ confirmed (the 3 skips are the class's pre-existing `@Disabled` rows, not new) |
| `mvn -o verify -Dit.test=AdvicePositionDamagedColumnsIntegrationTest …` | `Tests run: 3, Failures: 0, Errors: 0, Skipped: 0` / `BUILD SUCCESS` | green | ✅ confirmed |

Toolchain: Microsoft OpenJDK 21.0.11, Maven 3.9.15 via sdkman. All four ran **sequentially in one
shell in this lane's own worktree**. No red was observed anywhere, so no red had to be attributed —
the failure mode the isolation exists to prevent did not arise, and the four numbers are unchanged
from the shared-tree pass, which is what you would expect of a race that only manufactures reds.

Baseline comparison: §8 records `6634 / 0F / 0E / 1S` measured at the TDD gate on this branch. Now
`6638 / 0F / 0E / 1S`. Delta **+4 = exactly the four new `AdviceRestControllerUnitTest$DamagedQuantity`
rows**; the gate figure already counted `DamagedReturnApiSurfaceContractUnitTest`'s 4 rows (2 of them
red at the time, green now). **Zero failures on both sides — no regression.**

### Source findings re-verified at `5136ed87` in the isolated tree

Each of F1–F6 was re-derived here, not carried over. Results byte-identical to the first pass:

| Finding | Re-check in the isolated tree | Result |
|---|---|---|
| F1 | `grep -n "damageFailed" -A2` on `ReturnAdviceAutoReceiveService.java` | `break;` at :790 — confirmed |
| F2 | `grep -c "STORAGE_LOCATION_DAMAGED"` → **0**; `grep -c "LocationRepository"` → **0**. *Positive control:* `grep -c "StockunitRepository"` → **3**, so the grep reads the file | confirmed absent |
| F3 | `git grep "DAMAGE_APPLY_FAILED" -- src/` → **0 hits**. *Positive control:* `RETURN_AUTO_RECEIVE_DAMAGE_FAILED` → 2 hits in the service, 4 in `WmsConstants` | confirmed absent |
| F4 | `grep -rn "MAX_UNITS_PER_POSITION" src/main/java` → **3 hits, all in `ReturnAdviceAutoReceiveService`** (:84, :388, :391); none in the controller | confirmed |
| F5 | `throw new BusinessException("SBDEV-1512: no stock unit recorded…` at :911 | confirmed |
| F6 | `git diff origin/develop...HEAD -- src/test/` → **12 added `@Test` methods total**; added-`@Test` count in `ReturnAdviceAutoReceiveServiceUnitTest` → **0** | confirmed |
| D8 hold | `git diff --stat` over `StockunitService`, `UnitloadService`, `StockChangeDto`, `SharedService`, `MobileMoveUnitloadService` → **empty** | confirmed honoured |
| Migration | `tail -3` of `V2.2.32__…sql` shows the exact two-column `ALTER` | confirmed |

⚠ **One live-coordination note for the lead, not a finding.** The in-flight `(int) totalAmount` edit in
the shared tree is adjacent to **F4** and appears to be another lane fixing an overflow in
`resolveRefs`. Two things are worth saying so the two lanes do not talk past each other: (a) in
`resolveRefs` an overflowed sum is already caught *by accident* — a wrapped-negative `totalAmount`
trips the existing `if (totalAmount < 1)` guard at :379 and is rejected — so that edit hardens a path
that currently fails safe; (b) **the controller path has no such guard**, which is why F4 is the sharper
instance and is not fixed by that edit. `new BigDecimal(getAmountOfBottles() + damaged)` at
`AdviceRestController:458` persists a wrapped-negative `notifiedamount` with nothing downstream to
reject it. Fixing only `resolveRefs` would leave the `permitAll()` floor exactly as porous as it is now.

---

## 2. §0 Affected Sites — row by row

| # | Site | Plan | Built? | Evidence |
|---|---|---|---|---|
| 1 | `json/AdvicePositionDto` | In | ✅ **implemented** | `src/main/java/net/aim_ai/wms/json/AdvicePositionDto.java`: `@JsonProperty("amount_of_bottles_damaged")` / `private Integer amountOfBottlesDamaged;` + getter/setter + `toString` extended. Boxed `Integer` per §3.1. |
| 2 | `service/ReturnAdviceAutoReceiveService` | In | ⚠ **PARTIAL** | `resolveRefs` / `bind` / `executeInternal` / `applyDamage` / `stampDamageApplied` / record deltas / `Status.DAMAGE_FAILED` all present. **Missing: §3.5 pre-flight (F2), `FailureReason.DAMAGE_APPLY_FAILED` (F3); damage loop `break`s where §3.4 says continue (F1).** |
| 3 | `ReceivingService.receiveGoods` → `List<Long>` | In | ✅ **implemented** | `public List<Long> receiveGoods(long advicePositionId, …)`; `createdStockunitIds.add(stockUnit.getId());` beside `stockunitBusinessService.createStockUnit(...)`; `return createdStockunitIds;` at method end. Source-compatible — `ReceivingController` untouched. |
| 4 | `WmsConstants` 6xx + both switches | In | ✅ **implemented** | `public static final int RETURN_AUTO_RECEIVE_DAMAGE_FAILED = 603;` with arms in **both** `getErrorCodeText` (4-arg template) and `getErrorCodeName`. `git grep -n "= 603;" -- src/main/java` returns only this constant — free, as the plan required. |
| 9 | `StockunitService.setLockDamaged` | Excluded / reused | ✅ **honoured — untouched** | `git diff origin/develop...HEAD --stat -- …/StockunitService.java` → empty. |
| 10 | `UnitloadService.moveStockToNewDamagedContainer` | Excluded | ✅ **honoured — untouched** | same, empty. |
| 11 | `controller/rest/AdviceRestController` | In (D6) | ⚠ **PARTIAL** | The D6-A/D6-B save-loop block is exactly §3.2's required form, including the ternary and the asymmetry (see §4 Q3). **Missing the second half of §5.2's floor — the `MAX_UNITS_PER_POSITION` cap (F4).** The warning envelope is confirmed generic (`warning.put("code", autoReceiveOutcome.code())`, …), so §0 row 11's "no envelope edit needed" claim holds. |
| 11a | `model/Adviceposition` | In | ✅ **implemented** | `private BigDecimal notifieddamagedamount;` and `private LocalDateTime damageappliedat;` — **both with no initialiser**, which is M4 and is the load-bearing bit (siblings `notifiedamount`/`notifiedcases` are `= BigDecimal.ZERO`). See F8 on the `LocalDateTime` choice. |
| 12 | `StockChangeDto` / `SharedService` | Excluded (D5/D8) | ✅ **honoured — untouched** | empty diff. |
| 13 | `V2.2.32` migration | In | ✅ **implemented, exact** | see §4 Q6. |
| 14 | `FileImportController` | Excluded | ✅ untouched |
| 17 | the three UIs | Excluded | ✅ out of repo |
| 18 | `oms-laravel-api` | Excluded | ✅ out of repo |
| 5,6,7,8,15,16 | qa-api / qa-ui / v1 | Phases 2–4 / 2a | **out of scope — not reported as gaps** |

**D8 hold confirmed.** The full changed-file list is 7 `src/main` files + 6 test files. `setLockDamaged`, `transferStock`, `StockChangeDto`, `SharedService` and `MobileMoveUnitloadService` are **all absent from it** — the withdrawal was honoured. No HIGH finding on that axis.

**FU-2 confirmed dropped, as briefed.** `AdviceRestController` still carries `Optional<Boxtype> optionalBoxtype = null;` assigned only inside `if (StringUtils.isNotEmpty(advicePosition.getBoxId()))` and then dereferenced unguarded at `Boxtype boxtype = optionalBoxtype.get();`. Not reported as a gap. ⚠ **But the plan document was not updated** — §5.2 still carries an unticked checkbox reading *"FU-2 — fix it here, in this edit … Leaving a known unrecoverable 500 untouched while editing the lines around it is not a scope boundary, it is an omission."* A later reader grading this branch against §5.2 will read that as a defect. It needs a one-line withdrawal note in the plan.

---

## 3. Findings

### F1 — HIGH — the damage loop stops at the first failure; §3.4 requires it to continue

§3.4, verbatim: *"If a damage step throws, the implementation records the first failure, **continues** applying damage to the remaining positions (they are independent, and half-damaged is strictly better than one-damaged), then runs `markFinished` and returns `DAMAGE_FAILED` naming the first failed SKU."*

`ReturnAdviceAutoReceiveService.executeInternal`, the damage loop's catch:

```java
                damageOutcome = AutoReceiveOutcome.damageFailed(plan.adviceNumber(), line.sku(),
                    plan.lines().size(), correlationId);
                break;
```

`break` — not `continue`. On an advice whose position 2 of 5 fails, positions 3–5 are never attempted even though they are independent and would have succeeded. Their damaged units stay at `entity_lock = 0`, sellable and pickable, and the advice is still flipped `FINISHED` by the `self.markFinished(plan.adviceId())` below the loop. Recovery is the `damageappliedat IS NULL` worklist for all four positions instead of one — a strictly larger manual-recovery surface than the plan sized, and the plan's own argument for the two-loop ordering ("half-damaged is strictly better than one-damaged") is the argument against this code.

**Nothing grades it:** the plan's T1.8 (`applyDamage_damagesRemainingPositionsAfterFirstFailure`, "Position 2 fails, position 3 is still damaged") was not written.

### F2 — HIGH — §3.5's conditional `Damaged`-location pre-flight is entirely absent

§3.5 specifies, in `resolveRefs`, after the per-position loop and only when some position has `damagedAmount > 0`, a `locationRepository.findByName(WmsConstants.STORAGE_LOCATION_DAMAGED).orElseThrow(...)` raising `ENTITY_DOES_NOT_EXISTS` with the `rejected_tenant_misconfigured` counter. §5.2 carries it as its own checklist row.

*Instrument:* `grep -n "STORAGE_LOCATION_DAMAGED\|locationRepository" src/main/java/net/aim_ai/wms/service/ReturnAdviceAutoReceiveService.java` → **zero hits for either token** (the file's only `locationRepository` mention is a comment at :415 about a *different* lookup). `LocationRepository` is not injected into the class at all — the constructor gained only `StockunitService` and `StockunitRepository`. *Blind spot:* a token grep misses a reflective or SpEL lookup; none is plausible here, and `git diff` over the constructor confirms the dependency was never added, which is a second instrument on the same conclusion.

Consequence, exactly what §3.5 exists to prevent: on a tenant whose `location` row named `Damaged` is missing or renamed — name-keyed, no unique index, no "DO NOT REMOVE" description, `initDB` throws rather than creating it — an advice carrying damage is now **accepted**, `adviceRepository.save` commits (burning `externalid` permanently, so every OMS retry dies on the duplicate guard), every position is received, `markFinished` runs, and the caller gets a `DAMAGE_FAILED` warning on a 200. The plan required a `400` **before** the save.

**Nothing grades it:** T1.5 and I3 were not written.

### F3 — MEDIUM-HIGH — `FailureReason.DAMAGE_APPLY_FAILED` was not added; `UNKNOWN` is used

§3.4's property table: *"`FailureReason` | new value **`DAMAGE_APPLY_FAILED`** | Names a *class* of condition."* §5.2 lists it in the same checkbox as `Status.DAMAGE_FAILED` and the `code()` arm, both of which **were** built. T1.7a asserts `reason DAMAGE_APPLY_FAILED`.

`git grep -n "DAMAGE_APPLY_FAILED" -- src/` → **no hits.** The `FailureReason` enum still ends at `UNKNOWN`, and `AutoReceiveOutcome.damageFailed(...)` passes `FailureReason.UNKNOWN` with a javadoc arguing that is "the honest answer".

That argument is a reversal of the plan, not an application of it: the enum's own security contract forbids *inventing a cause a probe cannot establish*, and `DAMAGE_APPLY_FAILED` invents nothing — the damage step demonstrably failed, which is why the branch is being taken. Consequence: the warning envelope built at `AdviceRestController` (`warning.put("reason", autoReceiveOutcome.reason().name())`) emits `"UNKNOWN"` for a damage failure — byte-identical to a receive-path `diagnose()` miss. The `code` field still distinguishes the two, so this is an information loss in the operator-facing channel D7 exists to feed, not a total one.

**Whichever way it is resolved, one of the two artefacts is now wrong** — either add the constant, or amend §3.4 and T1.7a.

### F4 — MEDIUM — the save-loop validation tier implements half of §5.2's floor

§5.2, one checklist row: *"**Validation in the POSITION SAVE LOOP** (H3) … reject `amount_of_bottles_damaged < 0`, **and** reject `amountOfBottles + damaged` above `MAX_UNITS_PER_POSITION`. **This loop runs unconditionally**; `resolveRefs` does not."*

Only the first landed. `grep -rn "MAX_UNITS_PER_POSITION" src/main/java` → **3 hits, all in `ReturnAdviceAutoReceiveService`** (the constant at :84, the guard at :388, the log at :391). The controller has no cap.

So the floor is still porous on exactly the three shapes its own comment enumerates: a REGULAR advice, a RETURN on an auto-receive-off tenant, and a RETURN with empty positions never enter `resolveRefs`, and an unauthenticated caller on this `permitAll()` endpoint can still put an unbounded `notifiedamount` into `SUM(ap.notifiedamount) as qtyRequired` (`AdviceRepository`) and `ap.notifiedamount AS orderedbottles` (`ReceivingDtoViewRepository`).

**This change also introduces a shape the pre-change code could not produce.** `position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles() + damaged));` is `int + int` with no cap on that path. Before, `notifiedamount` was written from one non-negative `int` and could never be negative. Now two large values silently overflow to a **negative** `notifiedamount`, which then feeds both reporting consumers and `AdviceService`'s short-delivery guard. Uncapped addition on an uncapped path is the mechanism; the cap §5.2 asked for is also the fix.

### F5 — MEDIUM — §3.3 step 1 specifies `IllegalStateException`; the code throws `BusinessException`

§3.3 step 1, verbatim: *"**Throw `IllegalStateException`, not `BusinessException`** — a broken loop-shape invariant is a programming error, and routing it into the `DAMAGE_FAILED` ladder would present a defect as 'stock received, advice FINISHED, operator please fix by hand'."*

`applyDamage`:

```java
        if (createdStockunitIds == null || createdStockunitIds.isEmpty()) {
            throw new BusinessException("SBDEV-1512: no stock unit recorded for advice position "
                + line.advicePositionId() + "; cannot apply the damaged quantity");
        }
```

and again for the `findById` miss. Both land in `catch (BusinessException | FacadeException | RuntimeException e)` → `DAMAGE_FAILED`, which is the outcome §3.3 forbade.

⚠ **The plan's own remedy does not work either, and this should be settled rather than mechanically "fixed":** `IllegalStateException` **is** a `RuntimeException`, so §3.3's prescription would be caught by the very clause §3.3 also mandates. The throw type cannot separate these two cases; only an explicit re-throw ahead of the general catch can. Flagged as a plan/implementation disagreement needing a decision, not as a one-line code edit.

### F6 — MEDIUM — the §7.1 unit programme is ~3 of 13 rows; `ReturnAdviceAutoReceiveServiceUnitTest` gained **zero** new tests

*Instrument:* `git diff origin/develop...HEAD -- src/test/ | grep -E "^\+.*(void |@DisplayName|@Nested)"` — the complete list of added test methods. Positive control: it returns the 4 `DamagedQuantity` rows and the 4 contract rows, so the instrument sees added methods.

The diff to `src/test/java/net/aim_ai/wms/unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java` is **two new `@Mock` fields, one constructor argument, and six arity fixes to existing `ResolvedLine` / `AutoReceiveLine` fixtures.** No `@Test` was added.

| Written | Not written |
|---|---|
| T1.17 ×2 (`absentDamagedKeyDoesNotNpe…` RETURN + REGULAR) | T1.1, T1.2, T1.3, T1.4 (`resolveRefs` validation tier) |
| T1.18 (2 of 3 shapes — see below) | T1.5 (pre-flight — untestable, F2) |
| a D6-A row (`presentDamagedKeyIsSummedIntoNotifiedamountAndRecorded`) | T1.6 (`bind` positional zip of `damagedAmount`) |
| I1 (`mixedReturn_receivesTotalAndLocksDamagedPortion`) | **T1.7a, T1.7b** — the only rows that exercise the `DAMAGE_FAILED` ladder at all |
| 4 reflection-contract rows (2 of them positive controls) | **T1.8** (F1's grade), T1.10, T1.11, T1.12, T1.19 |
| — | **I2, I3, I4, I5** |

§8's Phase 1 gate reads *"T1.1–T1.13 + I1–I5 green … PIT kills attributable"*. As built: 3 of 13 `T1` rows, 1 of 5 `I` rows, PIT not run (briefed as outstanding).

The consequential gap is **T1.7a/T1.7b plus I2–I5**: no test anywhere in the tree drives `setLockDamaged` to throw, so `Status.DAMAGE_FAILED`, the `603` text template, the `damage_failed` counter, the `markFinished`-still-runs property and the whole catch clause are **unexercised**. F1 and F3 both live inside that unexercised region, which is why a fully green suite did not surface either.

T1.18 as written covers two of its three named shapes (REGULAR, auto-receive-off); the third, *"a RETURN with an empty `positions` list"*, is **vacuous by construction** — an empty list means the `for (AdvicePositionDto advicePosition : adviceDto.getPositions())` body never runs, so there is nothing to validate. The plan's enumeration is wrong there, not the test; the test's `@DisplayName` ("all three paths") should be corrected to two.

### F7 — LOW — stale `V2.2.31` strings in two places

`src/test/java/net/aim_ai/wms/integration/AdvicePositionDamagedColumnsIntegrationTest.java` carries `@DisplayName("V2.2.31 adds notifieddamagedamount — …")` and `@DisplayName("V2.2.31 adds damageappliedat — …")`. The file is `V2.2.32`. The plan's frontmatter `status:` (line 8) likewise still says *"one V2.2.31 ALTER"* while every body reference (§0 row 13, §3.2, §4 row 0, §5.1 row 1, §5.2, §7.4 row 8, §10 D6-B) says V2.2.32. Cosmetic, but these are the strings an operator greps when reconciling a Flyway failure against a test name.

### F8 — LOW — `damageappliedat` is `LocalDateTime` against a `timestamp with time zone` column

Migration: `ADD COLUMN IF NOT EXISTS damageappliedat timestamp with time zone`. Entity: `private LocalDateTime damageappliedat;`, written as `position.setDamageappliedat(java.time.LocalDateTime.now());`.

The plan pinned the DDL (§3.2) but not the Java type, so this is a convention divergence rather than a spec violation. The repo's one existing `timestamptz` column mapped in `model/` is `PutawayConfigAudit.changedAt` (`V2.2.13` `changed_at timestamptz`), declared `private OffsetDateTime changedAt;`. `LocalDateTime` writes and reads through the JDBC session timezone and drops the offset, so worklist timestamps are only comparable across deployments if that session zone is uniform. `OffsetDateTime` matches both the column and the precedent.

### F9 — LOW — the `receiveGoods` javadoc is not attached to the method

In `ReceivingService`, the new `/** SBDEV-1512: returns the ids … */` block sits **between** `@Transactional(...)` and `public List<Long> receiveGoods(`. It compiles (a comment is legal there) but it is a floating comment, not a doc comment: `javadoc` and IDE hover will not show it. Move it above the annotation.

---

## 4. The six graded questions

| # | Question | Verdict |
|---|---|---|
| 1 | Every §0 in-scope row implemented? | **PARTIAL** — §2 table. 6 of 8 in-scope Phase-1 rows clean; rows 2 and 11 partial. All 7 excluded rows honoured (empty diffs). |
| 2 | §8 / §7 acceptance criteria | **PARTIAL.** *Full suite vs baseline* ✅ VERIFIED (6638/0/0/1 vs 6634/0/0/1, delta = the 4 new rows, 0 failures both sides). *T1.1–T1.13 + I1–I5 green* ❌ **MISSING** — 3/13 and 1/5 exist (F6). *PIT kills attributable* ❌ not run (briefed). *§5.1 row 1a Flyway / M11* — operator steps, no code artefact, not evidenced here. *One independent review lane with a report on disk* — this file. |
| 3 | Does `notifiedamount = undamaged + damaged` hold on **every** path that writes it, and is the save loop really unconditional? | ✅ **VERIFIED.** *Instrument A:* `grep -rn "setNotifiedamount" src/main/java` → 7 hits = the setter + **6 call sites**. Only `AdviceRestController` (the create loop) can see a damaged value; the other five — `ReceivingService` `createAdviceWithPositions` and `updateAdviceWithPositions`, `FileImportController`'s spreadsheet import, and `AdviceRestController`'s `createTransfer` and `createHubAndSpoke` — take DTOs with no damaged field, so `damaged ≡ 0` and the identity holds trivially there. *Instrument B (independent):* `grep "@Modifying"` over `AdvicepositionRepository`/`AdviceRepository` → the only bulk updates set `state`; a full `grep -rn "notifiedamount" src/main/java` leaves nothing but reads and comments, so there is no JPQL/native writer. Positive control: `@Modifying` is found in 21 repository files, so the grep works. *Blind spot:* a reflective or SpEL write would evade both instruments; none exists by either. **The loop is unconditional** — `for (AdvicePositionDto advicePosition : adviceDto.getPositions())` sits inside the per-advice loop with no advice-type, sysprop or auto-receive guard between the loop head and the write. |
| 4 | Is the damage pass reached where claimed and skipped where claimed? | ✅ **VERIFIED as specified — with F1's truncation.** Traced `execute` → `executeAsIntegrationUser` → `executeInternal`: **skipped** when `plan.lines().isEmpty()` (early `return …skipped(...)`); **skipped** when any position's receive throws (the catch `return AutoReceiveOutcome.partial(...)` sits *above* the damage loop, so no damage is applied at all); **per line, skipped** on `if (line.damagedAmount() <= 0) continue;`; otherwise **reached**. It is inside the `executeAsIntegrationUser` `SecurityContext` block, so `stockrecord` attribution to `oms_integration` holds as §3.3 requires. It is **not** inside any `afterCommit` callback, so §7.3 row 10's rail is respected. The one departure is that after a *damage* failure the pass stops early (F1). |
| 5 | Do the two validation tiers cover what the plan says? | ⚠ **PARTIAL.** Derived by reading control flow, not comments. *Floor* (`AdviceRestController` save loop, unconditional): rejects `amountOfBottlesDamaged != null && < 0` → ✅; **does not** enforce `MAX_UNITS_PER_POSITION` on the total → ❌ (F4). *Additional tier* (`resolveRefs`, runs only `if (autoReceive)`): negative check ✅, `total >= 1` relaxation ✅ (`int totalAmount = position.getAmountOfBottles() + damagedAmount; if (totalAmount < 1)`), cap on the total ✅ (`if (totalAmount > MAX_UNITS_PER_POSITION)` with the `rejected_amount_cap` counter), conditional `Damaged` pre-flight ❌ (F2). So the auto-receive tier is complete bar the pre-flight; the floor is half-built. |
| 6 | Does `V2.2.32` match §3.2's DDL exactly? | ✅ **VERIFIED, exactly.** `ALTER TABLE public.adviceposition ADD COLUMN IF NOT EXISTS notifieddamagedamount numeric(19,2), ADD COLUMN IF NOT EXISTS damageappliedat timestamp with time zone;` — two columns ✅, one `ALTER` ✅, `public.`-qualified ✅, `IF NOT EXISTS` on both ✅, nullable ✅, no default ✅, no backfill ✅, no explicit `BEGIN`/`COMMIT` ✅, multi-paragraph `-- WHY` header ✅ (48 lines, in the V2.2.26/V2.2.30 band). **Version free:** swept all **289** `refs/remotes/origin` refs for `V2.2.32__*` → **0 occurrences**; positive control on the same sweep, `V2.2.30__outbox_message_lane` → **18** refs, so the instrument reads the tree and the zero is real. Plan text and filename agree at every body reference; only the frontmatter `status:` line is stale (F7). |

---

## 5. Summary

**PARTIAL.** The specified happy path is built and demonstrably works end-to-end against a real Postgres: I1 proves a 7+3 return lands 3 units at `entity_lock = 103` at the `Damaged` location, leaves 7 sellable, raises the `DAMAGED`/`STOCK_CREATED` stockrecord sum by exactly 3, and writes `notifiedamount = 10` / `notifieddamagedamount = 3` / a non-null `damageappliedat`. D8's withdrawal and the FU-2 drop were both honoured. The migration and the `603` constant are exact.

What is not built is the **failure half** — the `Damaged` pre-flight that keeps a misconfigured tenant from burning an `externalid` (F2), the continue-past-a-failure behaviour (F1), and the `FailureReason` value that makes the warning legible (F3) — plus half the unconditional validation floor (F4). All four sit in the region the §7 programme was supposed to cover and does not (F6), which is why a fully green build does not contradict any of them.

**Ranked, with what I would do first:** F2 (accepted-then-burned advice on a misconfigured tenant, and the plan's own §5.2 row) → F4 (unauthenticated unbounded/overflowing `notifiedamount` on a `permitAll()` endpoint) → F1 (`break` → `continue`, one token, plus T1.8) → F6's T1.7a/T1.7b (nothing exercises the ladder at all today) → F3 and F5, which each need a *decision* — either the code or the plan is wrong and one of them must be amended.

*Lane discipline:* this is a conformance lane only. I did not grade code quality, security beyond conformance, or Phases 2–4. Every completeness word above names its instrument and its blind spot inline.
