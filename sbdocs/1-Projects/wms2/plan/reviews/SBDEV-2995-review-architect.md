I have what I need. Full report follows.

---

# ARCHITECT REVIEW — SBDEV-2995

**Verdict: the plan's *problem* is real but its *map of the problem* is wrong at 3 of its 4 Fix-A sites, and its verify script cannot distinguish a correct implementation from five different broken ones.** I built five near-miss shadows; **all five score `22 pass, 0 fail`**, identical to a correct shadow.

All citations are `origin/develop` = `e7b3b88` unless marked `3abb1f22`.

---

## I. STEELMAN ANTITHESIS

> **The plan diagnoses "the sentinel is not a valid destination" when the actual defect is "desktop palletising forgot the type check that mobile palletising has." Fixing the stated symptom needs an unmerged PR, a shared collaborator, a sysprop coupling and four call sites. Fixing the actual defect is one line, self-contained, and catches 324,153 more wrong containers.**

### The evidence

**A1. Three of the four Fix-A sites are already guarded. I read them.**

`ParcelMonitorViewService.palletiseAndTruckLoad` — the existing-label branch is not a permissive branch at all:

```java
// ParcelMonitorViewService.java:287-305
Optional<Unitload> palletOpt = unitloadRepository.findByLabelid(palletName);
if (palletOpt.isEmpty()) { … create … } else {
    throw new BusinessException("Pallet with name=" + palletName + " already exists!");   // :304
}
```

There is **no reachable existing-label path**. `assertCanReceiveStock(pallet)` inserted there is unreachable code, and `pallet` is still `null` at that point. The plan's §3 key-file table ("`126-152, 284-310` | Bug 1, **both copies**") and §2's "Same insertion in `palletiseAndTruckLoad:287`" are both wrong. Verify row `A3` would pin dead code into the tree permanently.

`MobilePalletizingService.scanPallet` and `.scanPalletBulk` — both existing-label branches open with a type check:

```java
// MobilePalletizingService.java:257-258   (and identically :350-351)
if (!pallet.getTypeId().equals(pallet_type.getId())) {
    throw new BusinessException("Not a pallet: " + pallet.getLabelid());
}
```

Measured on four tenant DBs, the sentinel's `type_id` is **0 (`Default`)** on `dev_wh01_om1`, `wh01_hydra_v2`, `wh01_shipitez_v2` and **1 (`PickLocation`)** on `wh01_hydra_v2t`. `Pallet` is `id=5` on all of them. The sentinel is rejected as *"Not a pallet: Nirwana"* on mobile **today, on every tenant, deterministically**. `scanPalletBulk`'s shipping-method branch catches it too (`shippingmethod_id IS NULL` → *"Pallet Nirwana has no shipping method!"*).

So §2's "**Mobile is not better-guarded here**" is exactly backwards — and the plan *knew* this fact: §0 row 9 uses "the sentinel's type is `Default`, not `Pallet`" as its reason to file receiving-assign as out-of-scope. The same fact was not carried across to row 3.

**The reachable Fix-A surface is one site: `ParcelMonitorViewService.java:147-152`** — the only existing-label branch in the estate with no type check.

**A2. The right guard is therefore the type check, and it is empirically free.**

On `dev_wh01_om1`, unit loads with `carrierunitload_id IS NULL` and type ≠ Pallet — i.e. what `palletise`'s else branch accepts as a carrier **today**:

| type | count |
|---|---|
| Case | 299,426 |
| PickLocation | 23,597 |
| Tote | 1,064 |
| Package | 66 |
| **Default (the sentinel)** | **1** |

`assertCanReceiveStock` — a *location*-based predicate — refuses exactly **1** of those 324,154. A type check refuses all of them.

And the regression risk is measured zero, on the same population the plan already cites for R1:

```sql
SELECT t.name, count(*) FROM unitload_record r JOIN unitload u ON u.labelid=r.tounitload
JOIN unitload_type t ON t.id=u.type_id WHERE r.activitycode='PALLETIZING' GROUP BY 1;
```
`dev_wh01_om1` → **Pallet: 412,170** (nothing else). `wh01_hydra_v2` → **Pallet: 9,389** (nothing else). Every palletising operation ever recorded on both tenants targeted a Pallet-type carrier.

**A3. The minimal fix has none of the plan's coupling.** No PR #167 dependency (R3, rated *High — blocking*, evaporates). No `DestinationEligibilityService` injection into two more services. No inheritance of a sysprop whose rollout criterion was measured on a different workflow (see §II). It is the same line mobile already has, which is the strongest possible argument that it is the house idiom for this question.

**Where the antithesis does *not* reach:** Fix B1 and B2 in `ReceivingService` are genuine and survive intact — that is a `Pallet`-type-blind path (`unassignPallet:687-697`) and a real non-atomicity (`updatePallet:636`). The antithesis is against Fix A's design and scope, not against the ticket.

---

## II. REAL TRADEOFF TENSION (irreducible)

**Consolidation onto a shared collaborator and per-site correctness are in genuine conflict here, and no amount of extra work dissolves it.**

`DestinationEligibilityService.assertCanReceiveStock` (`3abb1f22`) has two clauses with two different governance regimes:

```java
// DestinationEligibilityService.java @3abb1f22
if (WmsConstants.STORAGE_LOCATION_NIRVANA.equals(locationName)) { throw … }   // UNGATED
String reason = gatedViolationReason(destination, locationName);              // lock != NOT_LOCKED, or Shipped
if (enforcing()) { throw … } else { LOG.warn("SBDEV-2994 shadow: …"); }        // TRANSFER_DESTINATION_ELIGIBILITY_ENABLED, default OFF
```

Calling it from `palletise` buys the ungated Nirvana clause **and simultaneously enrols palletising in 2994's gated rollout**. SBDEV-2994's own class javadoc states the retirement protocol: *"run one operating cycle, count the [shadow] lines, enable where the count is zero."* Those lines will be counted on **move-stock** traffic. The day an operator flips that sysprop for a tenant on move-stock evidence, **palletising silently acquires two new refusal rules it was never measured against.**

- Empirically the immediate blast radius is small: on both measured tenants every Pallet at `Palletizing`, `StagingLane*`, `Gate_*` and `EmptyPallets` carries `entity_lock = 0`. (Only `Shipped` pallets are locked — 15,876 on wineco-dev at `entity_lock=405`.) So today the gate would fire on ~nothing.
- But that is a *fact about current data*, not a property of the design. The coupling is permanent and invisible: nothing in `SyspropService`, the sysprop description, or 2994's plan says "this flag also governs outbound palletising."

**The tension:** you can have one predicate for "can this container receive stock" (fewer spellings, one place to fix, 2994's whole thesis) **or** you can have each screen own a refusal rule whose rollout it controls (no cross-workflow coupling). You cannot have both, because the collaborator's value *is* that its semantics are shared, and its risk *is* that its semantics are shared. Splitting the gate per call site rebuilds the fragmentation. Ungating everything re-imports 2994's unmeasured 411,862-row exposure into a second workflow.

The plan does not name this tension. §6.1's *"Feature flags: **No** — Deliberately ungated … Fix A inherits ungated behaviour **for free**"* is the load-bearing error: it is free **only for the Nirvana clause**. The gated clauses come along attached, dormant, and will wake up on someone else's decision.

---

## III. PRINCIPLE VIOLATIONS

**PV-1 — Fix chosen before the sites were read (§0, §2).** §0 is presented as the plan's methodological centrepiece ("swept by enumerating every `findByLabelid`… then triaging each", with a self-congratulatory note about needing a fourth bucket). Three of its four Fix-A rows are wrong, and each is falsifiable by reading ~10 lines of the cited method. The triage classified by *call shape* (`findByLabelid` → attaches stock) without reading the guard immediately following.

**PV-2 — A stated mechanism that does not operate (§2 Bug 2, §4 Fix B2, §10 R2).** `updatePallet:636-647` invokes `unassignPallet` and `assignPallet` as **`this.`-self-invocations**. Spring's proxy never intercepts those, so their `@Transactional` annotations are inert on this path — today and after B2. §2's `unassignPallet(pallet.getLabelid());   // commits` is right about the outcome but wrong about the cause (the commits come from `unitLoadBusinessService.transferUnitLoadToLocation`, a *different* bean, at `:676`/`:697`). §4's "Both callees are already `@Transactional`; under `REQUIRED` they join the new outer transaction rather than opening their own" and R2's mitigation both reason about a `REQUIRED` join that never happens. **B2 still works** (the controller→`updatePallet` hop *is* proxied) — but the plan cannot be trusted to have reasoned correctly about propagation anywhere else, and a reviewer who "improves" the fix by relying on `unassignPallet`'s own annotation will ship a no-op.

**PV-3 — The one blocking measurement was deferred, and its query is wrong (§11 Q4 / R4).** Q4 defers to implementation time the query that decides whether B1 is safe. Two defects in it:
- It uses Postgres `!~` (unanchored) to model Java `String.matches` (anchored). `verifyPalletOrCartLabel:617` is `label.matches(pattern)`. A label like `XIN-123456Y` passes `~` and fails `.matches`. Use `!~ '^(CART-\d{4}|IN-\d{6})$'`.
- It has **no type filter**, so it counts every Case/Tote at those locations. Run as written on `dev_wh01_om1` it returns **3,811 "failures"** — 3,759 of them `Case`-type ULs that can never reach `unassignPallet`. That is a false alarm that will read as "B1 is unshippable."

Run correctly (`type = Pallet`): **0 of 184** at PutAwayLane and **0 of 11** on hydra-uat fail; **14 of 57** at `EmptyPallets` on wineco-dev fail (`PM-015489`… — outbound pallets, matching `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL = 'PM-%1$06d'`, reachable only via `POST /v3/receiving/updatePallet` with an outbound label). **R4's real residual is 14 rows on one tenant, not "Medium/unknown".** The plan could have closed this in one query and chose not to.

**PV-4 — A new failure mode introduced without analysis (B1).** `verifyPalletOrCartLabel:616-620` does `label.matches(syspropService.getSysvalue(KEY))`. If `STRING_PATTERN_INBOUND_PALLET` is absent for a tenant, `getSysvalue` returns `null` and `Pattern.compile(null)` NPEs. `unassignPallet` currently never touches `syspropService` and is total (`if (unitload == null) return;`). After B1 it can 500. The key is present on the tenants I checked, but nothing in §6.1/§9/§10 records the new dependency.

**PV-5 — §0's entry-point enumeration for row 4 is incomplete, and B2's blast radius is understated.** Row 4 names two entry points. `updatePallet` has **four** callers: `ReceivingController:203` (`/setPallet`), `:253` (`/createAndSelectPallet`), `:329` (`/unlinkSelectedPallet`), `:365` (`/updatePallet`). B2 widens the transaction on all four. Worse for B2's stated goal: `/setPallet` and `/createAndSelectPallet` call `receivingService.createPallet(palletName)` **before** `updatePallet` (`ReceivingController:202`, `:245`), and `createPallet:701` is not `@Transactional` either — so a later `assignPallet` failure still leaves an orphaned freshly-created pallet. **B2 delivers atomicity for 2 of the 4 entry points**; the plan claims it unconditionally.

**PV-6 — §11 Q1's stated reasons are the wrong reasons (see §IV.1).**

**PV-7 — Divergence claimed as convergence (§4 "Why the collaborator and not a local check").** Post-plan the estate holds: `DestinationEligibilityService` (location-based), the mobile type checks at `MobilePalletizingService:257`/`:350`, `verifyPalletOrCartLabel` (regex, now at a 4th site), `resolvePalletByLabelId:623-631`'s type check, `MobileMoveUnitloadService:122` (lowercased label string), `:135` (identity), `:139-143` (source location), and a **new** `assertSourceUnitLoadMovable`. That is **eight** spellings across three mechanisms. Fix A migrates one site onto the collaborator and adds three unnecessary ones; Fix B1 adds a regex site; Fix C adds a private helper. The plan's own §4 rationale ("the estate already had four spellings… adding local checks here makes it six") is used to justify a change that makes it eight.

**PV-8 — §7.6's validation claim is materially overstated.** "22 pass / 0 fail — no false-REDs" and "seven near-miss WRONG shadows — each caught by exactly the intended row." See §VI: five further near-misses, including two that make the fix a complete no-op, are not caught by any row. `RUN_MVN` also defaults to `0`, so the headline 22/0 is a **grep-only** result; no test is ever executed.

---

## IV. THE FIVE ATTACK TARGETS

### 1. §11 Q1 — should the sentinel just be locked at creation?

**No — but every reason the plan gives is wrong, and the two decisive reasons are missing.**

The plan's three reasons don't hold:
- *(b) "three C-category sites resolve the sentinel expecting it usable."* I grepped every `Unitload.getEntityLock()` read in `src/main/java`. **Neither retirement path reads the sentinel's lock.** `UnitloadBusinessService.sendToNirvana:371-399` reads `nirvanaUnitload.getId()` and `nirvanaLocation.getId()` only; `StockunitBusinessService.sendStockUnitToNirvana:401-424` reads `nirvanaUnitload.getId()` only. `transferUnitLoadToLocation:169` checks the **destination Location's** lock, not the unit load's. Locking the sentinel breaks neither. Reason (b) is unsubstantiated.
- *(c) "blast radius is estate-wide."* The reads that would newly fire are `UnitloadService.buildCaseLabel:233` (needs stock, sentinel has none usable) and `MobileCycleCountService:131/163/208/345/416` — cycle-counting the sentinel is not a workflow. Narrow, not estate-wide.

The two reasons that actually decide it:

**(i) It would fix neither bug in this ticket.** `ParcelMonitorViewService.palletise` never reads `Unitload.getEntityLock()`. `ReceivingService.unassignPallet` never reads it either — and its `ignoreLock=true` at `:697` gates the *Location's* lock (`UnitloadBusinessService:161-171`), so it is irrelevant in both directions. Q1's premise — *"would make every lock-aware guard in the estate catch this at once"* — is false for the two screens the ticket is about. `DestinationEligibilityService.gatedViolationReason` *would* catch a locked sentinel, but only when `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` is on, and it is **default OFF**.

**(ii) A `getNirvana()`-only change is a no-op on all six databases.** `UnitloadService.getNirvana():195-211` only constructs when `findByLabelid` misses. All six tenants already have the row. Setting `setEntityLock(GOING_TO_DELETE)` there would take effect on **zero** existing tenants and would need a data migration the plan explicitly rules out (§6.1 *"No schema or data change"*). §2.4's claim that this is "the origin of `entity_lock = 0` on all six databases" is unverifiable and probably false for the five migrated/seeded ones.

**Recommendation:** keep the decision, replace the reasoning with (i) and (ii). Q1 is not "worth its own ticket" — as scoped (`getNirvana()` only) it is worth nothing.

### 2. Is a hard dependency on an open PR the right structure? Is `assertCanReceiveStock` semantically right here?

**No on both counts.**

*Structure.* R3 is self-rated **"High — blocking"**, and §6.1 makes merge of #167 a hard precondition. That is a plan choosing to be blocked. Fix B1+B2 have no such dependency and could ship today. Fix A's *only* reason to depend on #167 is reuse — and reuse buys the wrong predicate (below). Split the ticket: B1+B2 now, A after.

*Semantics.* `assertCanReceiveStock(Unitload destination)` answers **"is this container a live stock location?"** Palletising asks **"is this container a pallet I may load parcels onto?"** Those coincide on the sentinel by accident. Concretely:
- It is location-based, so it passes a `Tote` at `Palletizing`, a `Case` in a rack, a `PickLocation` UL — 324,154 containers on one tenant that `palletise` will still accept.
- Its own javadoc names the escape hatch: *"a dangling location FK is the only way to reach a Nirvana-parked unit load past the sentinel check below, since detection is by resolved location NAME."* I verified the FK resolves today — `location` row `id=0, name='Nirwana'` exists on all four DBs I queried, so Fix A does fire. But the guard is one `storagelocation_id` write away from silently doing nothing, whereas `type_id` is not something any workflow moves.
- It drags the gated clauses along (§II).

### 3. Mixing `verifyPalletOrCartLabel` with the collaborator — defensible?

**Yes for B1 specifically; the plan's stated reason is not the good one.** §4/Q2 justify it as "source-side vs `(Unitload destination)`". The better justification: `unassignPallet`'s sibling `assignPallet:652` already calls exactly this, so B1 is *restoring parity*, not choosing a mechanism. That is the strongest possible defence and it costs nothing.

But it entrenches fragmentation only because Fix A also fragments. If Fix A becomes the type check (§I), the plan reads coherently: **each receiving/palletising site asserts the property its sibling already asserts.** That is a real principle. "Route everything through the 2994 collaborator" is not achievable here and the plan half-abandons it anyway.

On R4: acceptable — **14 rows on one tenant**, all outbound `PM-######` pallets at `EmptyPallets`, reachable only by typing an outbound label into a receiving endpoint. Close Q4 with the corrected query (PV-3) and mark R4 Low.

### 4. Fix B2 — propagation, lock duration, external I/O

- **Propagation:** works, for a reason the plan gets wrong (PV-2). Self-invocation means the callees' annotations are inert; the real join happens at `unitLoadBusinessService.transferUnitLoadToLocation` (`:676`, `:697`), a different bean, `REQUIRED`, which joins the new outer transaction. Fix the plan's text.
- **`rollbackFor` is load-bearing, not decorative.** `BusinessException extends Exception` and `FacadeException extends Exception` — **both checked**. Spring's default rollback rule covers only unchecked. `@Transactional(value="tenantTransactionManager")` without `rollbackFor` makes B2 a **complete no-op**. Verify row `B3` does not check `rollbackFor` (§VI-2).
- **Lock duration:** roughly doubles on the unassign+assign path. `transferUnitLoadToLocation` recurses the carrier tree (`processTransfer`), so a PutAwayLane pallet with many children now holds one transaction across two full traversals. Real but modest; §8 row 4's "no external I/O inside" is correct — I checked, there is no print/notify inside either callee.
- **Missing from §8/§9:** B2 also widens `/setPallet` and `/createAndSelectPallet` (PV-5), where it does not achieve atomicity anyway.

### 5. Is the layering right? Converge or diverge?

**Diverges.** Eight spellings across three mechanisms after this plan (PV-7). The convergent version is: **one mechanism per question.** "Is this a pallet?" → `typeId == Pallet` (`MobilePalletizingService:257`, `:350`, `resolvePalletByLabelId:628` already do it). "Does this label look like an inbound pallet?" → `verifyPalletOrCartLabel`. "Can this container receive stock?" → `DestinationEligibilityService`, on stock-transfer paths only. Fix A currently uses mechanism 3 to answer question 1.

---

## V. §0 ENUMERATION — RE-AUDIT

| Row | Plan's call | Verdict |
|---|---|---|
| 1 `PMV:129` | A → Fix A | ✅ **Correct — the only real Fix-A site.** No type check at `:147-152`. |
| 2 `PMV:287` | A (latent) → Fix A | ❌ **Wrong.** `:304` throws on any existing label. Unreachable; `pallet` is `null`. Delete the row and verify row `A3`. |
| 3 `MPS:209, 316` | A → Fix A | ❌ **Wrong.** Type check at `:257-258` / `:350-351` rejects the sentinel (`type_id` 0 or 1; Pallet = 5) on all 4 DBs queried. `scanPalletBulk`'s shipping-method branch rejects it too (`shippingmethod_id IS NULL`). Delete rows `A4`, and `A5`'s MPS half. |
| 4 `RCV:684` | A′ → Fix B | ✅ Correct (signature `:681`, `findByLabelid` `:684`, relocate `:697`). Entry points understated — 4 not 2 (PV-5). |
| 5 `RCV:636` | Fix B2 | ✅ Real. Mechanism mis-stated (PV-2). |
| 6 `MMU:254` | A′ → Fix C | ✅ Real, and **more severe than "lowest priority"** — see below. |
| 7, 8 | closed by 2994 | ✅ Confirmed at `3abb1f22`: `StockunitService.transferStock` calls `assertCanReceiveStock`; `StockUnitController` folded onto `canReceiveStock`. |
| 9 | B — `verifyPalletOrCartLabel` gates | ✅ Confirmed for `resolvePalletByLabelId:623` and `assignPallet:652`. |
| 10–14 | B | Spot-checked 13 (`createUnitload` is idempotent-return, reached only post-regex) and 14. No objection. |
| 15–17 | C, preserve | ✅ Confirmed. Neither retirement path reads the sentinel's lock (§IV.1). |
| **Mobile sweep, `MMU:126`** | ✅ ×3 | The `:135` identity check works (`AbstractBaseEntity:70-75` compares by id) — but it is redundant: `:122`'s lowercased label compare already catches it. |

**Nothing reaches the sentinel that the plan filed as B.** The enumeration errs in one direction only: it over-collects. That is the safer direction, but it inflates the fix from 1 site to 4 and hard-binds the ticket to an unmerged PR to reach three sites that need nothing.

**One thing the plan missed at row 6.** `MobileMoveUnitloadService.scanDestination:264` does `stockunitRepository.findByUnitloadId(sourceUnitLoad.getId())` and iterates. For the sentinel that materialises **210,167 `Stockunit` entities** on wineco-dev (§1.5's own figure), then `checkReservedStock` iterates them again with a `pickingorderPositionRepository` query per row. That is not "defence in depth" — it is an unauthenticated-shaped OOM/timeout on a mobile endpoint. Fix C **must** be placed before `:264`, and the plan does not say where it goes. No verify row pins C's ordering (contrast `A2`, `B2`).

---

## VI. VERIFY SCRIPT — RE-AUDIT

**Baselines reproduce.** Unfixed `e7b3b88`: `4 pass / 18 fail / 1 skip`. Note the *relevant* baseline — branching off develop **after** #167 merges, per §6.1 — is `6 pass / 16 fail` (`D1`, `D2` go green). §7.6 quotes the wrong one.

**What the three validation passes missed.** I built five near-miss shadows off `3abb1f22` (script and shadows under `/tmp/claude-1000/`). **All five score `22 pass, 0 fail, 1 skip` — byte-identical to the correct shadow.**

| # | Shadow | Why it is wrong | Score |
|---|---|---|---|
| **W1** | `assertCanReceiveStock(pallet)` placed in the **`palletOpt.isEmpty()` CREATE branch** instead of the `else` branch | **The bug is 100% unfixed.** `'Nirwana'` exists → takes the `else` branch → never sees the guard. | **22/0** |
| **W2** | `@Transactional(value = "tenantTransactionManager")` on `updatePallet` — **no `rollbackFor`** | Both exceptions are **checked**; Spring will not roll back. **Fix B2 is inert.** | **22/0** |
| **W3** | `private void assertSourceUnitLoadMovable(Unitload u) throws BusinessException { }` — **empty body**, called from both sites | **Fix C is inert.** | **22/0** |
| **W4** | `assertCanReceiveStock` called **twice inside `scanPallet`**; `scanPalletBulk` untouched | Only satisfies `A4`'s count. Second mobile site unguarded. | **22/0** |
| **W5** | The outbound regex **hoisted out of the create branch** to before `findByLabelid` | The exact change §4 says is "Not proposed" and `P1`'s comment says it pins. | **22/0** |

**Root causes**

1. **`A1`/`A2` cannot see branch structure.** They slice `palletise` and assert `assertCanReceiveStock` appears, and appears before `transferUnitLoadToCarrier(` at `:206`. Both branches of the `if` are before `:206`, so **the guard's branch is invisible to the script** — the single most important structural fact about this fix. `A1`/`A2` need to slice from `} else {`/`findByIdForUpdate(palletOpt` to `getCarrierunitloadId() != null`, not the whole method.
2. **`B3` omits `rollbackFor`.** `check_B3` requires only `tenantTransactionManager` adjacency. §7.2's *test* asserts `rollbackFor` contains both types — the verify row does not, and `RUN_MVN` defaults to `0`, so nothing ever executes that test. This is the **highest-severity hole**: W2 ships a fix that does exactly nothing while the plan, the script and the reviewer all read green.
3. **`C1`/`C2` are pure name-and-arity checks.** No assertion that the extracted method contains anything, no ordering row, no test row for `MobileMoveUnitloadServiceUnitTest` at all (§5 lists it as modified; no `T` row covers it).
4. **`A4` counts occurrences, not sites.** `grep -c >= 2` cannot distinguish two guards in one method from one guard in each.
5. **`P1` does not pin what its comment claims.** `code_contains 'SYSTEM_PROPERTY_STRING_PATTERN_OUTBOUND_PALLET_KEY'` is a file-wide grep for a constant name; the comment says *"The regex must remain in the create branch."* It cannot detect a hoist. Same class of defect as the `grep -qv` the script's own header records as a caught baseline defect.
6. **`A3` re-uses `\z`** — the exact anchor the header condemns in lesson 8 and the `method_body` comment ("`\z` is never a safe method-slice end anchor"). It is de facto safe only because `palletiseAndTruckLoad:235` happens to be the last method in a 475-line file. The next method added below it silently reopens the hole.
7. **`T4`/`T5`/`T6` are token greps against a test file.** All three are satisfied by the ~6-line stub files I wrote (`assertThat(ex.getKey()).isEqualTo(…)`, `InOrder io = …`, `never()`) — files that do not compile, let alone test. With `RUN_MVN=0` nothing catches that.

**Minimum repairs**
- `A1`/`A2`: re-anchor to the `else` branch (`findByIdForUpdate\(palletOpt` … `getCarrierunitloadId\(\) != null`). If Fix A becomes the type check, assert `getTypeId\(\).*equals` in that slice instead.
- `B3`: require `rollbackFor` naming both `BusinessException` and `FacadeException`, still adjacent to `public Unitload updatePallet(`.
- `C1`: require the extracted body to contain `getNirvana\(` (or the chosen identity predicate). Add `C3`: called **before** `findByUnitloadId(` in `scanDestination`.
- `A4`: two `method_body`-scoped rows, one per mobile method.
- `P1`: assert the regex `throw` lies *inside* the `palletOpt.isEmpty()` slice.
- `A3`: `method_body`, not `\z`. Better: **delete `A3` and `A4` entirely** once §0 rows 2 and 3 are corrected.
- Make `RUN_MVN=1` the default, or stop describing the grep-only result as acceptance.

---

## VII. SYNTHESIS

The ticket is real. `ParcelMonitorViewService.palletise:147-152` will attach parcels to the retirement sentinel and flip orders to `PALLETIZED`, and `ReceivingService.unassignPallet:687-697` will relocate the sentinel with `ignoreLock=true` from a non-transactional caller. Both are worth fixing. `priority: normal` is right — zero occurrences in 412,170 `PALLETIZING` and 153,572 `UNASSIGN_INBOUND_PALLET` rows, and zero quantity at risk.

**Recommended shape:**

1. **Split the ticket.** Fix B1 + B2 have no dependency on PR #167 and close a real non-atomicity. Ship them first, on their own branch. This deletes R3 from that half of the work.
2. **Re-scope Fix A to one site with the type check.** `palletise`'s else branch gets `if (!pallet.getTypeId().equals(palletType.getId())) throw new BusinessException("Not a pallet: " + pallet.getLabelid());` — verbatim parity with `MobilePalletizingService:257-258`. Zero regressions across 421,559 measured palletisings on two tenants; catches 324,154 wrong containers instead of 1; no PR #167 dependency; no sysprop coupling. **Delete Fix A at `palletiseAndTruckLoad:287` and both mobile sites — they are already guarded.**
3. **If the collaborator is kept anyway** (a defensible call — it is the only guard that catches a Pallet-type UL parked at Nirwana, which the type check misses), then use it **in addition to** the type check, at `palletise` only, and **record in §6.1 that palletising is now governed by `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED`** so whoever flips that sysprop knows what else moves.
4. **Fix C:** place `assertSourceUnitLoadMovable` **before** `scanDestination:264`, cite the 210,167-row materialisation as the reason, and give it a test + a verify ordering row.
5. **Close Q4 now** with the corrected query; downgrade R4 to Low with the 14-row figure.
6. **Rewrite §2 Bug 2, §4 Fix B2 and R2** to say self-invocation, not `REQUIRED` join.
7. **Fix `B3` before anything else in the script.** W2 is the shadow that scares me: a one-token omission that makes the fix inert, invisible to every gate the plan has.

**On the plan's own terms:** its §7.6 discipline — three-direction validation, near-miss families, recording the mutation that turned out to be wrong — is the right discipline and it caught real defects. It failed here not because the discipline is wrong but because the near-miss family was drawn from the *plan's* model of the fix. Every one of my five shadows is a mutation the author would not have thought to write, because each corresponds to a place the plan is confidently wrong. That is the general lesson: **a near-miss family generated by the plan's author cannot test the plan's blind spots.** The mutations have to come from reading the code, not from reading the plan.