head: 3bcb4a69

# SBDEV-3353 P1: security and data-integrity review

- **Tree:** `.claude/worktrees/wms2-api/SBDEV-3353-security`, detached at `3bcb4a69`.
- **Diff:** `5fa9bef0...3bcb4a69`. It changes 10 production files and adds tests.
- **Reviewer lane:** security-reviewer, read-only. I ran no Maven, stash, checkout or restore.
- **Date:** 2026-09-24.

**Verdict: the control is sound for what it guards. It fails in the safe direction on all real data, and nothing in it blocks a merge. Risk level: LOW.**
There are 0 High and 0 Medium findings against the diff. There are 2 Low findings against the diff, and 3 findings on sibling routes that already existed and are unchanged by this PR. Those 3 are proposed for this ticket or a follow-up. They are not blockers.

## Summary

| # | Sev | Scope | Finding |
|---|---|---|---|
| L1 | Low | diff | TOCTOU (check-then-act race). The guard reads `unitloadId` from an entity loaded outside the transaction. The move then re-reads the row under `FOR UPDATE`. Only the damaged arm (`ignoreLock=true`) can exploit the gap. |
| L2 | Low | diff | Fail-open (unknown ⇒ proceed) is a code-level hole with zero real population: NOT NULL columns, 0 orphans on 6 tenants, and no writer can rename or retype. It should be pinned so it stays that way. |
| S1 | Medium (sibling, pre-existing) | ticket | `POST /v3/stockUnit/transferToDamaged` goes to `setLockDamaged`, which drains an **unlocked** parcel (H2) with `removeUnitLoadIfEmpty=true`. The consult's route sweep missed it. |
| S2 | Low (sibling, pre-existing) | ticket | Mobile putaway `storeBoxOnLocation` (flow-bin arm) drains an unlocked parcel. `adjustAmount` changes an unlocked parcel's quantity. |
| S3 | Info | ticket | `handleTruckOffLoading` and the whole-parcel `transferUnitLoadToLocation` are still unguarded. The spec already lists both. |

Live exposure for everything above is the H2 population: **1 row on WineCo UAT and 0 on Hydra PRD** (queries in §2).

---

## 1. Bypass surfaces

### 1a. Spring Data REST (SDR): closed, and not changed by this PR
- All three entities involved are in `SDR_WRITE_WITHDRAWN` (`RestConfiguration.java:441-553`):
  ```java
  net.aim_ai.wms.model.Stockunit.class,
  net.aim_ai.wms.model.Unitload.class,
  net.aim_ai.wms.model.UnitloadRecord.class,
  net.aim_ai.wms.model.UnitloadType.class,
  ```
- `configureUnwrittenResourceWriteExposure` (`:556`) disables `WRITE_VERBS = {POST, PUT, PATCH, DELETE}` (`:28`) at the collection, item and association level. It is wired at `:877`.
- These are **type-level exposure withdrawals**, not method-level `exported = false`. The known pitfall of a grep that matches `exported=false` on a method, which reads the result backwards, does not apply here. `@ReadOnlyProperty` does not apply either: this is a 405 withdrawal, not a property filter.
- Two instruments agree:
  1. The config above.
  2. `SdrWriteWithdrawalContextTest.java:160-163` lists `"Stockunit", "Unitload", "UnitloadRecord", "UnitloadType"` in its pinned set.
- Exported `@Modifying` search methods on `StockunitRepository`, `UnitloadRepository` and `UnitloadTypeRepository`: **0**. The only hit is a comment at `StockunitRepository:40`.
- The PR does not touch `RestConfiguration` or `repo/`. `git diff --stat` over those paths is empty, so the exposure is unchanged.
- **Consequence for the fail-open question:** nobody can rename type row 3 (`PATCH /v3/unitloadType/3 {"name":"package"}`) or retype a unit load over HTTP. An attacker has no SDR route into the guard's "type name ≠ Package ⇒ proceed" branch.

### 1b. MVC and `/rest/**`
- I swept `transferStockToUnitLoad(` and `.transferStock(` over `src/main`. No `controller/rest/**` class moves stock out of a unit load.
- `AdviceRestController:790` only looks up the Package type, to create one.
- No writer changes an existing unit load's `type_id`. `UnitloadService.createUnitload` (`:198-219`, `:229-253`) returns the existing row unchanged when the label already exists.
- `/rest/**` is internal-only (WMS↔OMS), per Nam 2026-08-27. Noted, not escalated.
- The operator routes that stay unguarded are in S1–S3.

## 2. Fail direction: every "proceed" input for a real Package

The guard (`SourceContainerGuard.java:56-81`) answers "proceed" when any of these holds:

| Input | Code | Reachable on real data? |
|---|---|---|
| `stockunit.unitload_id` null | `if (unitloadId == null) return;` | No. Column NOT NULL, 0 rows on 6/6 tenants |
| Unit load not found | `findById(unitloadId).orElse(null)` → `assertNotParcel(null)` returns | No. 0 orphan stock units on 6/6 |
| `unitload.type_id` null | `sourceUnitload.getTypeId() == null` | No. Column NOT NULL, 0 rows on 6/6 |
| Type row missing | `.orElse(false)` | No. 0 orphan `type_id` on 6/6 |
| Type name ≠ `"Package"`, exact and case-sensitive | `WmsConstants.UNIT_LOAD_TYPE_PACKAGE.equals(type.getName())` | No. Every tenant has exactly `id=3, name='Package'` and no variant |

- The name is compared **exactly** (`"Package".equals(...)`, `WmsConstants.java:873`). That is correct, not a weakness:
  - Every production parcel is created with the type resolved by the same exact-match `unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PACKAGE)`, followed by `orElseThrow`. The sites are `CustomerorderService:637`, `BillofladingService:848`, `CustomerorderBatchService:799`, `AdviceService:226` and `AdviceRestController:790`.
  - A tenant whose row was spelled differently could not pack at all.
  - So the guard and the producer use the same instrument, and a case-insensitive compare would add nothing.
- It is also safe that the guard resolves by `typeId` rather than `findByName`: it reads the name of the very row the parcel points at.

### Per-tenant `unitload_type` (read-only, verbatim)

```sql
select t.id, t.name, (select count(*) from unitload u where u.type_id=t.id) as ul_count from unitload_type t order by t.id
```

- **wms2-hydra (Hydra PRD):** `[{'id': 0, 'name': 'Default', 'ul_count': 0}, {'id': 1, 'name': 'PickLocation', 'ul_count': 146}, {'id': 2, 'name': 'Tote', 'ul_count': 8}, {'id': 3, 'name': 'Package', 'ul_count': 221}, {'id': 4, 'name': 'Case', 'ul_count': 492}, {'id': 5, 'name': 'Pallet', 'ul_count': 48}, {'id': 6, 'name': 'Cart', 'ul_count': 1}]`
- **wsl-wineco-uat:** `[{'id': 0, 'name': 'Default', 'ul_count': 1}, {'id': 1, 'name': 'PickLocation', 'ul_count': 29403}, {'id': 2, 'name': 'Tote', 'ul_count': 1032}, {'id': 3, 'name': 'Package', 'ul_count': 469625}, {'id': 4, 'name': 'Case', 'ul_count': 351538}, {'id': 5, 'name': 'Pallet', 'ul_count': 19251}, {'id': 6, 'name': 'Cart', 'ul_count': 1}]`
- **nywh-hydra-uat:** `[{'id': 0, 'name': 'Default', 'ul_count': 1}, {'id': 1, 'name': 'PickLocation', 'ul_count': 552}, {'id': 2, 'name': 'Tote', 'ul_count': 101}, {'id': 3, 'name': 'Package', 'ul_count': 9404}, {'id': 4, 'name': 'Case', 'ul_count': 3066}, {'id': 5, 'name': 'Pallet', 'ul_count': 1178}, {'id': 6, 'name': 'Cart', 'ul_count': 0}]`
- **nywh-shipitez-uat:** `[{'id': 0, 'name': 'Default', 'ul_count': 0}, {'id': 1, 'name': 'PickLocation', 'ul_count': 66}, {'id': 2, 'name': 'Tote', 'ul_count': 27}, {'id': 3, 'name': 'Package', 'ul_count': 1398}, {'id': 4, 'name': 'Case', 'ul_count': 127}, {'id': 5, 'name': 'Pallet', 'ul_count': 109}, {'id': 6, 'name': 'Cart', 'ul_count': 0}]`
- **c1wh-shipitez-uat:** `[{'id': 0, 'name': 'Default', 'ul_count': 1}, {'id': 1, 'name': 'PickLocation', 'ul_count': 2997}, {'id': 2, 'name': 'Tote', 'ul_count': 230}, {'id': 3, 'name': 'Package', 'ul_count': 109966}, {'id': 4, 'name': 'Case', 'ul_count': 14865}, {'id': 5, 'name': 'Pallet', 'ul_count': 1345}, {'id': 6, 'name': 'Cart', 'ul_count': 1}]`
- **wms2-wineco-dev:** `[{'id': 0, 'name': 'Default', 'ul_count': 1}, {'id': 1, 'name': 'PickLocation', 'ul_count': 23597}, {'id': 2, 'name': 'Tote', 'ul_count': 1075}, {'id': 3, 'name': 'Package', 'ul_count': 397383}, {'id': 4, 'name': 'Case', 'ul_count': 320874}, {'id': 5, 'name': 'Pallet', 'ul_count': 16952}, {'id': 6, 'name': 'Cart', 'ul_count': 1}]`

**Result:** all 6 tenants have an identical 7-row seed. No tenant has a Package-like type under another name, and there is no case variant. In every tenant, Package is the most or second-most populated type, which is the positive control.

### Null and orphan inputs, all 6 tenants (identical result on each)

```sql
select (select count(*) from unitload where type_id is null) ul_null_type, (select count(*) from unitload u where type_id is not null and not exists (select 1 from unitload_type t where t.id=u.type_id)) ul_orphan_type, (select count(*) from stockunit where unitload_id is null) su_null_ul, (select count(*) from stockunit s where not exists (select 1 from unitload u where u.id=s.unitload_id)) su_orphan_ul, (select is_nullable from information_schema.columns where table_name='unitload' and column_name='type_id' limit 1) type_id_nullable, (select is_nullable from information_schema.columns where table_name='stockunit' and column_name='unitload_id' limit 1) su_ul_nullable
```

Every one of the six tenants returned:

`[{'ul_null_type': 0, 'ul_orphan_type': 0, 'su_null_ul': 0, 'su_orphan_ul': 0, 'type_id_nullable': 'NO', 'su_ul_nullable': 'NO'}]`

### Live population a guard could matter for

```sql
select s.entity_lock su_lock, u.entity_lock ul_lock, l.name loc, count(*) from stockunit s join unitload u on u.id=s.unitload_id join location l on l.id=u.storagelocation_id where u.type_id=3 and coalesce(s.entity_lock,-1)<>405 group by 1,2,3
```

- **Hydra PRD:** `[]`.
  - Control: `select s.entity_lock, count(*) … where u.type_id=3 group by 1` returns `[{'entity_lock': 405, 'count': 491}]`.
  - So all 491 Package stock units on PRD are shipped, and there is **zero** live PRD exposure today.
- **WineCo UAT:** `[{'su_lock': 100, 'ul_lock': 0, 'loc': 'Gate_01', 'count': 63}, {'su_lock': 100, 'ul_lock': 0, 'loc': 'Packaging', 'count': 15}, {'su_lock': 0, 'ul_lock': 0, 'loc': 'Packaging', 'count': 1}]`. This matches the consult: H1 = 78 lock-100 rows, H2 = 1 unlocked row.

### L2 (Low): the fail-open is defensible, but it is only guaranteed by data
- **Location:** `SourceContainerGuard.java:70-77`:
  ```java
  if (sourceUnitload == null || sourceUnitload.getTypeId() == null) {
      return;
  }
  boolean isParcel = unitloadTypeRepository.findById(sourceUnitload.getTypeId())
      .map(type -> WmsConstants.UNIT_LOAD_TYPE_PACKAGE.equals(type.getName()))
      .orElse(false);
  ```
- **Why this direction is acceptable:**
  - Every "proceed" input is unreachable on 6/6 tenants because of NOT NULL constraints, zero orphans, and no rename or retype writer (§1).
  - The consult's safety argument ("no arm reaches Nirvana for a non-Package type") holds.
  - The PR's own removal of `Package` from `TYPES_THAT_REST_IN_A_STORAGE_LOCATION` does not make the fail-open worse. Its only caller, `StockunitService.java:525`, sits inside `transferStock`, after the guard.
- **Residual risk:** the guarantee is only as strong as "a Package always resolves". The one mechanism that could break it is a missing `unitload_type` row, and the FK is not enforced by this code.
- **Optional hardening** (Nam's call; it does not reverse the decision): log the fail-open branches at WARN, so an impossible state becomes visible instead of silent:
  ```java
  // GOOD (optional): proceed, but make the "cannot happen" state observable
  if (sourceUnitload == null || sourceUnitload.getTypeId() == null) {
      LOG.warn("SBDEV-3353 guard: source container unresolved (unitload={}) — proceeding unguarded",
               sourceUnitload == null ? null : sourceUnitload.getId());
      return;
  }
  ```

## 3. TOCTOU (L1, Low)

- **Location:** `StockunitService.java:332` (the guard) against `StockunitBusinessService.transferStockToUnitLoad` (the act). The same applies to `MobileTransferOrderService.java:367`.
- **Mechanism:**
  1. The web controller loads the entity outside any transaction (`StockUnitController.java:150`, `stockunitRepository.findById(id)`, with `spring.jpa.open-in-view=false`).
  2. It passes the now-detached `Stockunit` into `@Transactional transferStock`.
  3. The guard reads `stockUnit.getUnitloadId()` **from that detached snapshot, with no row lock**.
  4. The act then re-reads the row:
     ```java
     sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)...
     entityManager.refresh(sourceStockunit);
     ...
     final Long sourceStockunitUnitloadId = sourceStockunit.getUnitloadId();
     Unitload sourceUnitload = unitloadRepository.findByIdForUpdate(sourceStockunitUnitloadId)
     ```
  5. `MobileTransferOrderService.transferStock` has **no `@Transactional` at all**, so its window runs from the controller load to the first split call.
  6. If `packageOrder` re-homes the stock unit into a Package and commits inside that window, the guard has validated the Tote, and the act drains the Package.
- **Why it is rated Low:**
  - Packing only re-homes lock-100 (PICKED_FOR_GOODSOUT) stock and keeps the lock.
  - After the re-read, every `ignoreLock=false` arm refuses lock 100 (`if (!ignoreLock) … "is locked="`).
  - The whole-UL arm refuses any lock (`SourceLockGuard`).
  - The QF-damaged arm needs lock 103.
  - The **only** arm that can exploit the window is the plain damaged arm (`CODE_DAMAGED, …, true, true`, `:593`). That requires an operator to damage tote stock in the few milliseconds while that same stock unit is being packed.
  - Before this PR that exact move was **allowed anyway**: tote stock with lock 100 could be damaged, and packing it afterwards is the pre-existing race. So the window does not reopen a hole the PR closed. It narrows the PR's new guarantee from "never" to "not unless it races packing".
- **Pessimistic locks are held by the act, not the guard.** In order they are: Pickingorder (activity-classified), then source stock unit, source unit load, source location, destination unit load, destination stock unit, destination location. The guard takes none of them.
- **RTS is not exposed.** `CancellationReversalService.completeReversal` re-loads the stock unit inside its own transaction, then does `setEntityLock(NOT_LOCKED); save; entityManager.flush()` before `transferStock`. That UPDATE row-locks the stock unit and is checked against `@Version`. A packer that committed in between causes an optimistic-lock failure and a rollback, and a later packer blocks behind the row lock.
- **Optional remediation:** evaluate the guard against the locked row. The cheapest version is inside the already-transactional `StockunitService.transferStock`:
  ```java
  // BAD: reads a detached snapshot
  SourceContainerGuard.assertStockNotInParcel(stockUnit, unitloadRepository, unitloadTypeRepository);
  // GOOD: take the SU row lock first (the same lock transferStockToUnitLoad takes next, so lock order is unchanged)
  Stockunit locked = stockunitRepository.findByIdForUpdate(stockUnit.getId())
      .orElseThrow(() -> new EntityNotFoundException("StockUnit", stockUnit.getId()));
  entityManager.refresh(locked);
  SourceContainerGuard.assertStockNotInParcel(locked, unitloadRepository, unitloadTypeRepository);
  ```
- **Caveat on that remediation:** it takes the SU lock *before* the Pickingorder lock that `transferStockToUnitLoad` takes first (the "Hook B" order: Pickingorder before Stockunit). That inverts the documented lock order, so **do not apply it without an architect check**.
- **Given the population, accepting L1 is reasonable.** On Hydra PRD, 0 unshipped parcels exist and 0 rows would be exposed.

## 4. Error message and logging

- **Operator text** (`messages*.properties`): `Container %1$s is a parcel (Package). Stock cannot be moved out of a parcel: …`. The only parameter is `Objects.toString(labelid, String.valueOf(id))`, which is the parcel label the operator already scanned or sees, or its id as a fallback. There are no SKUs, customer or order data, stack traces or internal names. **No leak.**
- **Rendering:** both controllers render `e.getMessage()`, and for the keyed constructor `BusinessException.getMessage()` resolves the bundle (`resolveMessage(null, key, parameter)`). The operator sees the sentence, not the raw key.
- **Logging:**
  - The guard itself logs nothing.
  - The keyed `BusinessException` constructor logs `LOG.info("key={} {}", key, params)`, i.e. `key=transferStockSourceIsParcel PKG-…`. That is harmless.
  - The pre-existing `LOG.debug("start with stockUnit={}, …, comment={} …")` at `StockunitService:324` is unchanged by this PR, and the comment is clamped.
  - Nothing sensitive is logged.

## 5. RTS rollback and outbox

- `completeReversal` is `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` (`CancellationReversalService.java:190`).
- `BusinessException extends Exception` is checked (`BusinessException.java:14`), so it would **not** roll back by default. The explicit `rollbackFor` is what makes it roll back, and it is present.
- `StockunitService.transferStock` carries the same `rollbackFor` (`:320`) and joins the transaction with REQUIRED propagation, so the inner throw marks the transaction rollback-only regardless.
- **Order of side effects:**
  1. The pre-validate loop, including the recovered-`picktostockunit_id` `logRepository.save`.
  2. The movement loop: lock clear, flush, `transferStock`. **The guard throws here**, at the top of `transferStock` and before `mintUnitloadLabel` (the REQUIRES_NEW sequence write). So nothing escapes the rollback through a separate transaction.
  3. The outbox enqueue happens **only after** both loops (`:430-466`, `if (remaining.isEmpty())`). A refusal therefore never reaches it. No OMS notification is enqueued before the refusal.
- There is no `catch` around `transferStock` in `completeReversal`; the only `catch` is the serialization one at `:463`.
- **Independent evidence:** the IT `CancellationReversalParcelSourceIntegrationTest.aReversalOutOfAParcelIsRefusedAndRollsBackTheLockClear` reads back through a new read-only `TransactionTemplate` and finds `entity_lock == 100`, `unitload_id` still the parcel, `reversal_completed_at` null, and 0 `ORDER_BATCH_REVERSAL_COMPLETED` outbox rows. The Case control enqueues exactly 1 row, so that zero is not a test that passes on nothing.
- **Verdict: fails safe.** The one cost is availability: that CO's reversal stays pending and OMS never gets REVERSAL_COMPLETED for it. That is the intended "manual intervention" outcome, and the population today is 0 (0 `reversal_required` logs on WineCo UAT and Hydra UAT, per the consult).

---

## Sibling routes, pre-existing, not introduced by the PR (for the ticket, not blockers)

These come from the same fix discipline: look for other routes into the same outcome, not just the one reported. The outcome here is "stock leaves a parcel while `parcel_id`, the BOL and OMS still name it". All three routes are live only for **H2** (an unlocked parcel after a PACKED force-cancel: 1 row on WineCo UAT, 0 on Hydra PRD). Lock-100 and 405 parcels are refused by their existing lock switches.

### S1 (Medium, sibling): `transferToDamaged` drains an unlocked parcel into Nirvana
- **Location:** `StockunitService.setLockDamaged` (reached from `StockUnitController:553/:595` via `/v3/stockUnit/transferToDamaged` and the bulk endpoint, and from `ReturnAdviceAutoReceiveService:1003`), then `UnitloadService.moveStockToNewDamagedContainer`:
  ```java
  switch (stockUnit.getEntityLock()) {
      case WmsConstants.BusinessObjectLockState.NOT_LOCKED:
          break;
  ...
  // TODO check locks on unit load
  ...
  Stockunit damagedStock = stockunitBusinessService.transferStockToUnitLoad(
      stockUnit, container, amount, WmsConstants.CODE_DAMAGED, null, comment, false, true);
  ```
- **Effect:** this is the same corruption the PR closes on `transferStock`'s damaged arm (H1/H2). `removeUnitLoadIfEmpty=true` sends an emptied parcel to `relocateEmptiedContainer` → `default:`, i.e. `sendToNirvana`, which is irreversible. A stock-change message goes to OMS.
- **Why it was missed:** `setLockDamaged` never calls `transferStock`, and the consult's sweep regex did not match `moveStockToNewDamagedContainer`.
- **Why it is rated Medium rather than High:** it needs the H2 state, which is 1 row on UAT and 0 on PRD.
- **Remediation:** a one-line call to the same guard, after the lock switch. Its tier is under T3, so it goes on **this** ticket if Nam agrees:
  ```java
  // in StockunitService.setLockDamaged, after the lock switch
  SourceContainerGuard.assertStockNotInParcel(stockUnit, unitloadRepository, unitloadTypeRepository);
  ```
  Keep `ReturnAdviceAutoReceiveService` in mind: it damages freshly received stock, which is never in a Package. Confirm that with the test.

### S2 (Low, sibling): mobile putaway and web `adjustAmount`
- **Mobile putaway:** `MobilePutAwayService.storeBoxOnLocation` resolves the source by any label (`findByLabelid` / `IgnoreCase`) with no type restriction. Its flow-bin arm, `transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad, sourceStockUnit.getAmount(), CODE_PUT_AWAY, null, null, false, true)` (`:557`), drains an unlocked parcel and retires it to Nirvana. The consult classified putaway as "non-operator", but this endpoint is operator-driven with a free-form scan.
- **`adjustAmount`:** `StockunitService.adjustAmount` (`/v3/stockUnit/adjustAmount`) accepts NOT_LOCKED stock and rewrites a parcel's quantity. Arguably that is a legitimate count correction; it is listed only for completeness.
- **Remediation:** the same guard in `storeBoxOnLocation` before the flow-bin transfer. `adjustAmount` needs Nam's decision.

### S3 (Info): already known and deliberately out of scope
- `MobileMoveUnitloadService.handleTruckOffLoading` is unguarded (it is an open question for Nam in `implementation.md`).
- `scanDestination`'s whole-container `transferUnitLoadToLocation` relocates a parcel whole, without draining it.
- `MobileMoveUnitloadService.transferStock`'s `case UNIT_LOAD_TYPE_PACKAGE:` is now unreachable dead code.

**What I'd do first:** S1, since it is one line under the same key with the same test shape, then S2 putaway. Neither blocks this PR.

---

## OWASP pass (scoped to this change)

- **A01 Access control:** no new routes. The existing function gates on `/transferStock` and `/bulkTransferStock` are unchanged. SDR writes on the three entities are withdrawn (§1a).
- **A03 Injection:** none. There is no new query, and the guard uses `findById` with a Long.
- **A04 Insecure design:**
  - The control is type-keyed and sits before the arm dispatch.
  - It covers every arm and amount on the 3 guarded services.
  - The residuals are the sibling routes S1–S3 and the L1 race.
- **A05 Misconfiguration:** the key is present in both bundles, which `messageKey_shouldBePresentInEveryBundleWithAPositionalLabel` pins. It uses positional `%1$s`.
- **A06 Components:** no dependency change. I skipped `mvn dependency-check` because the task said to avoid Maven and the pom is untouched.
- **A08 Integrity:** the RTS rollback is verified (§5).
- **A09 Logging:** refusals are logged at INFO by `BusinessException`. Fail-open branches are silent (L2, optional).
- **A10 SSRF:** not applicable.
- **Secrets scan of the diff:** `git diff 5fa9bef0...3bcb4a69 | grep -iE 'password|secret|token|api[_-]?key'` finds no credentials added.

## Security checklist

- [x] No hardcoded secrets in the diff
- [x] Inputs validated: every null and miss path is handled, and all are unreachable on 6/6 tenants
- [x] No injection surface introduced
- [x] Authz and bypass: SDR writes withdrawn for Stockunit, Unitload and UnitloadType (config plus context test). No `/rest/**` stock-out path
- [x] Fails safe on RTS: `rollbackFor` covers the checked `BusinessException`, and the outbox is after the refusal point
- [x] Error text leaks only the parcel label or id
- [x] Dependencies: unchanged (no audit run, since the pom is untouched and Maven was avoided)
- [ ] TOCTOU on the web and mobile paths (L1): accepted or optional
- [ ] Sibling routes S1 and S2: proposed for this ticket
