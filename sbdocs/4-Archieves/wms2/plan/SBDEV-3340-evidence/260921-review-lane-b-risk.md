---
title: SBDEV-3340 — review lane B (risk): should TRANSFER_DESTINATION_CONSTRAINT_ENFORCED be switched on?
date: 2026-09-21
lane: B — risk review (independent of the measurement lane)
reviews: 260921-shadow-gate-retirement-measurement.md
code_basis: origin/develop (read via `git show origin/develop:<path>`); gate merged 873189c8, live on PRD since v0.0.26
---

# Review lane B — risk

## Bottom line

**ENABLE** on **Hydra PRD**, then **ShipItEZ c1wh UAT**, **ShipItEZ nywh UAT**, **Hydra UAT** — but for a
different reason than the measurement doc gives, and **only after F1 below is accepted**, because the
rollback lever the doc describes does not exist.

**HOLD** on **WineCo UAT / dev** — I agree with the measurement's verdict and disagree with its reasoning.
The config question it poses is the wrong question (F2).

The honest framing of the value: this gate will **almost never fire**. Hydra PRD has **5** `MANUAL_SPLIT`
mints in its entire recorded history. Enabling buys close to nothing in refused-bad-traffic terms. What it
does buy — and what the measurement document never argues — is **route coherence**: the sibling route
already enforces this rule unconditionally today, so the current behaviour makes the outcome depend on
geometry rather than on policy. That, not risk mitigation, is the case for enabling, and it is a good
enough one at a cost of ~0.

Recommending **against** would also have been defensible. I am not making that call because the downside
is measurably bounded at three named locations per tenant and the incoherence is real.

---

## 1. Blast radius of the throw

### 1.1 Who can reach the two gated mint sites

`StockunitService.transferStock` has exactly **three** callers in `src/main`, verified by
`git grep -n "transferStock(" origin/develop -- src/main`:

| # | Caller | Route | Transaction shape |
|---|---|---|---|
| 1 | `StockUnitController.transferStock` :156 | Web/mobile **Move Stock**, single row | controller **not** `@Transactional` → each call is its own tenant tx |
| 2 | `StockUnitController.bulkTransferStock` :270 | Web **Transfer Stock**, multi-row | loop; **one tx per id** |
| 3 | `CancellationReversalService.completeReversal` :355 | **Return-to-Stock** | joins the caller's tx (REQUIRED) → whole reversal |

`TransferOrderController` :101 calls `mobileTransferOrderService.transferStock(...)`, a **different method
on a different service**. The handheld Transfer Order screen therefore does **not** pass through the gate
at all. This matters for §3.

### 1.2 What the operator sees

`messages.properties:16`:

```
unitloadTypeNotPermittedOnLocation=Unit load type %1$s is not permitted on location %2$s (location type %3$s).
```

Rendered, e.g. *"Unit load type Case is not permitted on location FinishedPicking (location type totes)."*

- **Move Stock (callers 1 and 2)** — `StockUnitController` :157-159 catches it and returns **HTTP 200**
  with `{"errors":[{... "message": <rendered text>}]}`; the UI renders `errors[0].message` verbatim
  (the controller's own comment at :172 records this for the mobile store).
- **Return-to-Stock (caller 3)** — `OrderCancellationController.completeReversal` :62 declares
  `throws BusinessException`, so `RestExceptionHandler` :142-149 maps it to **422** with
  `title="Business Rule Violation"`, `retryable=false` and the same rendered text as `detail`.

The message names the **location the operator chose**, which is actionable. It also names a **container
type they never chose** — `Case` comes from `itemdata.defultype_id` and every `itemdata` row on every
tenant defaults to it. **[F6 — Low]** The operator has no remedy other than picking a different
destination; that is a legitimate action, so this is confusing rather than dead-ending. No change
recommended, but support should expect "what is a Case?" tickets.

### 1.3 Rollback and committed side effects

At **both** call sites the gate is invoked **before** `unitloadService.createUnitload`
(`StockunitService.java` :374 then :376; :558 then :560). So at the moment of refusal:

- **no container has been minted**;
- **no stock record, no `unitload_record` row, no OMS message.** The only outbound OMS message on this
  path (`messageService.sendStockChangeMessage`, the *moved-to-Damaged* branch) sits **after** the mint;
- the enclosing transaction rolls back cleanly — `transferStock` carries
  `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`,
  so the checked exception really does roll back rather than commit half the work.

**[F5 — Low] One thing is *not* rolled back: unit-load label sequence numbers.** `createUnitload(Location, …)`
opens with `basicService.generateNumber(EntityPrefixes.UNITLOAD, "UNIT_LOAD")`, and `UnitloadService`'s own
javadoc for `mintUnitloadLabel` names that as *"the `REQUIRES_NEW` sequence write
(`SequenceTransactionService:23`)"*. In a multi-position RTS reversal (§2) where position 1 mints and
position 3 refuses, position 1's label number is burned permanently while its row rolls back. Cosmetic —
a gap in the label series, not data loss — but it is the one thing that survives the rollback, and per
`burned-sequence-numbers-prove-a-code-path-ran` those gaps are also how you later date the event.

**[F4 — Medium] `bulkTransferStock` partially applies.** Because `StockUnitController` is not
`@Transactional`, each `stockunitService.transferStock(...)` in the loop is **its own committed
transaction**, and the `catch (BusinessException)` at :277-279 is **inside** the loop. A bulk transfer of
10 rows into a constrained bin therefore commits the ones that pass and lists errors for the ones that
refuse, returning **HTTP 200** either way. This is pre-existing behaviour for every `BusinessException` on
that endpoint, not something the gate introduces — but enabling adds a *new* systematic refusal reason to
an endpoint that fails per-row and reports it in a body the UI may or may not surface per row. Worth
knowing before someone bulk-moves a shelf into `Packaging`.

---

## 2. The RTS interaction — the javadoc's warning is accurate, and the exposure is nil

The warning in `StockunitService.assertMintedContainerIsPermittedAtDestination`'s javadoc:

> ⚠ **Before enabling a tenant, consider the RTS caller.** `CancellationReversalService` replays a logged
> `pickfromlocationname` as the destination, so an enforced refusal there aborts the WHOLE reversal with a
> message naming a container type the operator never chose and cannot change.

**Verified accurate on both halves.**

*Whole reversal.* `completeReversal` is
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`
(:190). The movement loop at :268 calls `transferStock` at :355 with **no try/catch**. `transferStock`'s own
`@Transactional` uses the default `REQUIRED` propagation on the same manager, so it **joins** rather than
nests. A refusal on position 3 of 5 therefore unwinds positions 1 and 2 as well.

*What that costs.* Less than the phrasing suggests, and this is the part worth stating plainly: the abort
is **atomic and clean**. The outbox enqueue (:455-466) sits *after* the loop and is never reached; the
`reversal_completed_at` / `reversal_completed_by` stamps (:441-447) roll back with everything else; the
`PICKED_FOR_GOODSOUT` clear and its `entityManager.flush()` (:349-352) roll back too. Nothing is
half-done, nothing is told to OMS, and the row stays `pending` for a retry. That is the *correct* failure
shape — it is exactly what SBDEV-3316 was fixed to produce. So "needs manual recovery" overstates it: it
needs the destination configuration fixed, then a retry, with no data repair in between. **Severity of the
RTS interaction as such: Low**, given the shape.

*Whether it can fire at all.* The measurement doc answers this from `pickingorder_position`, a proxy. I
went at the **direct** table instead — `customerorder_cancellation_log.pickfromlocationname` is literally
the string `transferStock` is handed at :355:

```sql
SELECT coalesce(lt.sltname,'<<UNRESOLVED>>') AS dest_type, count(*) AS log_rows,
       count(*) FILTER (WHERE cl.reversal_completed_at IS NULL) AS still_pending,
       bool_or(EXISTS (SELECT 1 FROM location_constraint lc JOIN unitload_type ut ON ut.id=lc.unitloadtype_id
                        WHERE lc.storagelocationtype_id=l.type_id AND ut.name='Case')) AS permits_case
FROM customerorder_cancellation_log cl
LEFT JOIN location l ON l.name = cl.pickfromlocationname
LEFT JOIN location_type lt ON lt.id = l.type_id
GROUP BY 1;
```

| DB | result |
|---|---|
| `wms2-hydra` (**PRD**) | **16 rows, every one `flowbin`, all still pending** |
| `nywh-hydra-uat` | **0 rows** |
| `wsl-wineco-uat` | **0 rows** |

`flowbin` takes the *other* arm of `transferStock` — the
`locationType.getSltname().equals(STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)` branch — which resolves
the fixed-location assignment's existing unit load and **mints nothing**, so it never reaches the gate.

**Verdict: RTS exposure is zero on every tenant, measured on the actual table rather than a proxy.**
The 16 Hydra PRD rows are consistent with `wms2-rts-completereversal-moves-no-stock` (0/16 PRD rows).
**[F8 — Low, corrective]** the measurement doc should cite this table rather than `pickingorder_position`;
same verdict, and it removes blind spot #5's `location.name`-uniqueness worry for the RTS half, since the
population is 16 rows and they all resolve to one location type.

---

## 3. Is enabling worth it? Both sides.

### 3.1 The case FOR — the one the measurement doc does not make

`UnitloadBusinessService.transferUnitLoadToLocation` **already enforces this exact predicate,
unconditionally, behind no sysprop at all** (`UnitloadBusinessService.java` :280-325):

```java
if (locationConstraintList != null && !locationConstraintList.isEmpty()) {
    if (!locationConstraintService.isUnitloadTypePermitted(
            destinationLocation.getTypeId(), unitload.getTypeId())) {
        …
        throw new BusinessException(WmsConstants.MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION,
                unitloadTypeName, destinationLocation.getName(), locationTypeName);
```

Same predicate. Same message key. No flag.

That is the route `transferStock` takes when
`stockUnit.getAmount().compareTo(amountToTransfer) == 0 && !flaOpt.isPresent() && stockUnitList.size() == 1
&& unitloadService.restsInStorageLocation(suUnitLoad)` — i.e. when the move happens to *drain* the source
container. So **today**, on any tenant:

- move a **whole** `Case` container to a `totes`-only bin → **already refused**, today, no flag;
- move **part** of it to the same bin → **succeeds**, mints a `Case` there.

Whether the rule applies is decided by whether the quantity happens to equal the row's amount. That is
geometry, not policy. SBDEV-3341 made precisely this argument for the source-lock guard on the same two
arms ("the lock policy of a Move Stock would depend on whether the move happens to drain the container —
which is geometry, not a lock question"). The identical argument holds here and is stronger, because the
sibling already throws the same key.

**Enabling does not introduce a new rule. It stops one of two sibling routes exempting itself from a rule
the system already enforces.**

### 3.2 What the silent success actually costs downstream

Modest, and I want to be accurate rather than alarming. `isUnitloadTypePermitted` has six consumers
(`git grep -n "isUnitloadTypePermitted" origin/develop -- src/main`): this gate, the relocation throw
site, and four **putaway** consumers (`PutawayDestinationResolver` :247, `PutawayDestinationValidator`
:175, `PutawayConfigService`, `SkuPutawayQueryService`). Nothing in picking, cycle count, or the report/SDR
views reads it. So a mis-minted `Case` in a `totes` bin does **not** corrupt picking or counting — it sits
there, visible, and the putaway planner simply will not *choose* that bin again.

The real cost is narrower: the WMS ends up holding a state **its own move operation would have refused to
create**, in a lane whose whole purpose is single-type (`EmptyTotes` is where `relocateEmptiedContainer`
parks drained totes; `Packaging` on ShipItEZ holds 3 872 `Package` unit loads). Refusing at mint time is
better than silent success, but the margin is thin, and it is an *integrity* argument, not an
*operational-breakage* one.

### 3.3 The case AGAINST

1. **It will essentially never fire.** Hydra PRD: **5** `MANUAL_SPLIT` mints, ever; **0** refusable. The
   most recent refusable event on any tenant is **2026-02-18**, seven months ago.
2. **The invariant is not closed even with the flag on.** `MobileTransferOrderService.transferStock` mints
   via `unitloadService.createUnitload` at three sites (:412, :418, :424) with no constraint check and no
   flag. All three target `transferLane`, which is unconstrained on every tenant measured, so there is no
   live bypass — but "enforced" will be true of the web route and false of the handheld route, and anyone
   reading the sysprop name will assume otherwise. The measurement's **P1** proposal is the right call;
   I second it at **T2**.
3. **No rollback lever** — see F1.

### 3.4 Net

Enable. The cost is near zero, the downside is bounded at three named locations per tenant (§4.1), and
the incoherence in §3.1 is real and permanent otherwise. But present it internally as *"make the mint
route agree with the relocation route"*, not as *"close an exposure"* — the exposure is 0 events in
3.2 years and overselling it is how the next shadow gate gets waved through.

---

## 4. Rollout shape

### 4.1 What is actually at stake per tenant

Independently re-derived (the doc's join multiplies location counts by the number of constraint rows; its
published figures are nonetheless correct — I reproduced Hydra PRD's 179/47/14/13/11/2/1 exactly with a
clean join):

**Every reachable REFUSES-`Case` location on the four recommended tenants, by name:**

| tenant | location | location type | permits | unit loads there now |
|---|---|---|---|---|
| Hydra PRD | `EmptyTotes` | `totes` | Tote | 6 Tote |
| Hydra PRD | `FinishedPicking` | `totes` | Tote | 2 Tote |
| Hydra PRD | `Packaging` | `packages` | Package | 0 |
| ShipItEZ c1wh UAT | `EmptyTotes` | `totes` | Tote | 150 Tote |
| ShipItEZ c1wh UAT | `FinishedPicking` | `totes` | Tote | 0 |
| ShipItEZ c1wh UAT | `Packaging` | `packages` | Package | 3 872 Package |

**Not one unit load of a non-permitted type sits at any of them today.** The live state is fully
consistent with the constraints — which is itself evidence that nothing is routinely violating them.

Equally important, the **system locations are all safe**:

| Hydra PRD location | type | permits Case? |
|---|---|---|
| `Damaged` | `overstock box` | **yes** |
| `CycleCount` | `overstock box` | **yes** |
| `Clearing` (mobile's hardcoded destination) | `NoRestriction` | **fail-open** |
| `Transfer`, `EmptyPallets`, `Shipped` | `overstock pallet` | **yes** (Case,Pallet) |

So the Damaged workflow — which runs through the *gated* new-container arm, past the gate, before the two
`QUALITY_FAULT` sub-branches — is unaffected. That is the one path I was most worried about and it is
clean.

### 4.2 Order and watch

1. **Hydra PRD first**, not last. Counter-intuitive but correct: it is the lowest-traffic tenant on this
   path (5 mints ever), it is the tenant whose config I verified most thoroughly, and PRD is where the
   sibling gate `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` already has a row (`false`, `DEFAULT`,
   `client_id = 0`), so the operating convention exists. Match that row's shape exactly.
2. Then **ShipItEZ c1wh UAT**, **ShipItEZ nywh UAT**, **Hydra UAT** together — identical config shape,
   larger histories, all zero.
3. **Never WineCo** until §5.1 is resolved.

**What to watch.** Not the shadow log — it has no readout path (the measurement doc establishes that, and
I confirm it: `logback-spring.xml` on `origin/develop` has the `RollingFileAppender` commented out, no
`logging.file.name`, and `management.endpoints.web.exposure.include` omits `logfile`). Watch instead:

- the **support queue** for the rendered string `"is not permitted on location"` — it is the only channel
  that reaches a human;
- a weekly re-run of the measurement's `unitload_record` query. A refusal now shows as the **absence** of
  a row that would previously have appeared, so the instrument is "mints at constrained-and-not-permitted
  destinations stays at its pre-enable value and does not grow."

There is no metric to watch: per `wms2-metrics-exist-but-nothing-scrapes-them`, nothing scrapes Prometheus.

### 4.3 [F1 — HIGH] The rollback lever the doc describes does not exist

> The measurement doc says: *"Reversible by deleting the row — note `los_sysprop` reads are cached ~2 min
> and a direct SQL write skips the `@CacheEvict`."*

That implies a write **through the System Properties screen** does evict. **It does not.**

- The gate reads `syspropService.getSysvalue(KEY)`, which is
  `@Cacheable(value = "sysprops", unless = "#result == null", key = "…cacheKey(…) + ':' + #key")`
  (`SyspropService.java` :333-335).
- The **only** `@CacheEvict` on that cache is on `SyspropService.createSystemProperty` (:64).
- The System Properties screen does not call it. `wms2-web-ui/store/admin/configuration.js` :127 is
  `this.$axios.$put('/sysprop/' + data.item.id, data.item)` (and :224 for the batch form, :179 for delete)
  — straight into **Spring Data REST**, since `SyspropRepository` is
  `@RepositoryRestResource(collectionResourceRel = "sysprop", path = "sysprop")`. SDR writes hit the
  repository directly and never traverse `createSystemProperty`.

So **both** write paths — the screen and psql — are equally cache-blind. Consequences:

- **OFF → ON is immediate.** `unless = "#result == null"` means the absent row was **never cached**, so the
  very next mint reads the new row. No 2-minute wait to enable. *(The doc does not say this; it is the one
  place the caching situation is better than described.)*
- **ON → OFF takes up to 2 minutes and cannot be forced.** `"true"` **is** cached, TTL 2 min
  (`CacheConfig.java` :36 Caffeine / :60-62 Redis). Deleting the row leaves `"true"` live until expiry;
  after that the read returns `null`, which is not cached, so it stays off.
- **Per replica, probably.** `CacheConfig` selects Caffeine (JVM-local) unless the `redis` profile is
  active. Nothing in the repo activates it — `Dockerfile:45`'s `SPRING_PROFILES_ACTIVE` is commented out
  and `application.properties` only documents `spring.profiles.active=redis` as an option. If prod runs
  multi-replica without that profile, each replica expires independently. **Unknown to me** — it is an
  infra-side env var (Joe). Worth one question before enabling PRD.

**Practical rollback: delete the row, then wait 2 minutes, or restart the pods.** That is fine for this
change; it is not fine to *believe* it is instant while an operator is blocked. State it in the runbook.

---

## 5. Things the measurement treats as settled that are not

### 5.1 [F2 — Medium] The WineCo "config disagreement" is a false equivalence

The doc, and the `WmsConstants` javadoc before it, frame WineCo as the outlier:

> *"why does WineCo's `overstock pallet` exclude `Case` when four sibling tenants permit it? Fix the
> config or accept the refusal"*

I listed the actual locations. **WineCo's 12 `overstock pallet` locations are not overstock racking:**

```
EmptyPallets · Gate_01 · Gate_02 · Gate_03 · Gate_04 · Gate_05 · Gate_06
InboundWorkstation · Palletizing · PickUp_Zone · Shipped · Transfer
```

Every one is a **process / staging lane**. WineCo's racking lives on `cases and pallets` — **583**
locations, zero constraint rows, fail-open.

**Hydra PRD's 47 `overstock pallet` locations are a mixture**: racking (`1V4O1C1`, `1V5O1C1`, `INVZ1`…
`INVZ16`, …) **and** the same process lanes (`EmptyPallets`, `Gate_01`…`Gate_06`, `Shipped`, `Transfer`).

So the two tenants are not disagreeing about the same thing. WineCo **separated** racking from lanes and
constrained the lanes to `Pallet`; Hydra **conflated** them and had to widen the type to `Case,Pallet` to
keep its racking usable. On this reading **WineCo's configuration is the more coherent one**, and "fix the
config to match the siblings" would be actively wrong: widening WineCo's `overstock pallet` to permit
`Case` also widens `Gate_01`…`Gate_06`, `Shipped`, `Palletizing`, `PickUp_Zone` and `InboundWorkstation`.

The real question is narrower and answerable by a warehouse person, not by SQL: **should a partial Move
Stock be able to mint a `Case` at `EmptyPallets` and `Transfer`?** Those are the only two locations in the
34 (33 at `EmptyPallets` on 2022-12-17 by `benjaminlobo`; 1 at `Transfer` on 2026-02-18 by
`adampetersen` — I reproduced this decomposition independently). If yes, the fix is to move those two
locations to a type that permits `Case`, not to widen the type. If no, WineCo can be enabled as-is.

I keep the doc's **HOLD** verdict for WineCo. I replace its reasoning.

### 5.2 [F3 — Medium] Only one of the two gated mint sites is test-pinned

The gate's own javadoc argues that gating both routes is what makes the measurement meaningful:

> *"Gating only the other one would have produced a reassuring ~0 shadow count while this kept flowing."*

But the tests do not cover both. `git grep -rln "isUnitloadTypePermitted" origin/develop -- src/test`
returns one `StockunitService` test class, `StockunitServiceToteContainerRelocationUnitTest`, and all
three of its gate tests drive the **new-container** route through the helper `moveTheWholeRowToTheRack`.
`git grep -rn "pallet-carrier" origin/develop -- src/test` returns **nothing** — the route literal passed
at `StockunitService:375` appears in no test.

The three tests that do exist are good ones (they assert `getKey()` not the text, they pin argument order
by full-message equality under `Locale.ROOT`, and `permittedDestinationShortCircuitsBeforeTheGateIsRead`
kills the deleted-early-return mutant properly rather than via `UnnecessaryStubbing`). The gap is not in
the predicate, which is shared — it is in the **call-site wiring at :374**. A mutant deleting that one
call survives the suite, and that is the route **33 of WineCo's 34** violations came from.

This does not block enabling the four clean tenants (0 refusable events on either route). It does mean
the doc's *"The gate's own conditionals were PIT-killed on the original ticket"* is true of the helper and
**not** of the pallet-carrier call site. Recommend one test before WineCo is ever enabled.

### 5.3 Two smaller ones

- **[F7 — Info]** The doc's caching note is wrong in the *helpful* direction for enabling (immediate,
  because null is never cached) and wrong in the *unhelpful* direction for disabling (F1). Both belong in
  the runbook.
- **[F8 — Low]** The RTS analysis should be re-based on `customerorder_cancellation_log`, the table the
  code actually reads, rather than `pickingorder_position`. Same conclusion; one third the assumptions;
  and it makes the doc's own blind spot #5 (unverified `location.name` uniqueness) irrelevant for the RTS
  half. It also retires the doc's recorded 8.2 % / 10.7 % disagreement, which is a statistic about a
  proxy population.

I found **nothing** in the measurement's core numbers that is wrong. I reproduced independently: Hydra
PRD's location-type census (179/47/14/13/11/2/1), WineCo's per-type constraint map, the 33-at-EmptyPallets
+ 1-at-Transfer decomposition with dates, and the absence of a `TRANSFER_DESTINATION_CONSTRAINT_ENFORCED`
row on Hydra PRD alongside `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED=false` /
`TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED=true`.

---

## 6. Findings, severity-rated

| # | Severity | Finding |
|---|---|---|
| **F1** | **High** | Neither write path evicts the sysprop cache. The UI writes via SDR `PUT /sysprop/{id}`, which never reaches `SyspropService.createSystemProperty`'s `@CacheEvict`, so it is no better than psql. Rollback is bounded at the 2-min TTL and cannot be forced; likely per-replica (Caffeine) unless the `redis` profile is set in the deploy env — unverified. The doc's rollback instruction must be corrected before anyone relies on it. |
| **F2** | **Medium** | The WineCo config question is posed on a false equivalence. WineCo's 12 `overstock pallet` locations are all process lanes; Hydra's 47 mix lanes with racking. "Make WineCo match the siblings" would widen `Gate_01`…`Gate_06`, `Shipped`, `Palletizing` and more. The answerable question is whether `EmptyPallets` and `Transfer` should accept a `Case`. |
| **F3** | **Medium** | The **pallet-carrier** gate call site (`StockunitService:374`) has no test — no test references the `"pallet-carrier"` route literal. Deleting that call survives the suite, on the route 33 of WineCo's 34 violations used. |
| **F4** | **Medium** | `bulkTransferStock` applies partially: controller is not `@Transactional`, so each id commits independently and the `BusinessException` catch is inside the loop; returns 200 with a per-row error list. Pre-existing shape, newly reachable reason. |
| **F5** | **Low** | A refusal in a multi-position RTS reversal rolls the tx back but not the `REQUIRES_NEW` unit-load label sequence burned by earlier positions. Cosmetic gap in the label series. |
| **F6** | **Low** | The refusal names `Case`, which the operator never chose (it is the SKU's `itemdata` default) and cannot change from Move Stock. It does name the location they chose, so it is diagnosable. Expect support questions. |
| **F7** | **Info** | OFF→ON is effective immediately (`unless = "#result == null"` means the absent row was never cached). Better than the doc implies; the asymmetry with F1 should be documented. |
| **F8** | **Low** | Re-base the RTS analysis on `customerorder_cancellation_log` (the table the code reads) rather than `pickingorder_position`. Hydra PRD 16 rows all `flowbin`; Hydra UAT and WineCo UAT 0 rows. Same verdict, fewer assumptions. |

I second the measurement's **P1** (`MobileTransferOrderService`, 3 unguarded mint sites) at **T2**, and its
**P2** (shadow gates ship with no readout path) as a process item. Neither is filed — SBDEV-3340 is
`on prod`, so the carve-out applies and Nam confirms.

---

## 7. Floor

- **DB query confirming the symptom** — 8 queries across 4 databases (`wms2-hydra` PRD, `nywh-hydra-uat`,
  `c1wh-shipitez-uat`, `wsl-wineco-uat`): location-type census with a clean (non-multiplying) join;
  per-type constraint map; `customerorder_cancellation_log` destination-type breakdown; the
  would-refuse decomposition with dates and locations; current unit-load types at every constrained
  tote/package location; system-location types; `los_sysprop` `TRANSFER%` rows on two tenants.
  Positive control on each grouped query: the non-empty `permits` / `type_constrained` columns.
  One query of mine was **wrong first time** — joining `location_constraint` doubled the location counts
  (94 and 26 where the truth is 47 and 13); corrected, it reproduces the doc's figures exactly.
- **Failing test / mutation check** — not applicable, no code changed. Reviewed the existing gate tests
  instead and found the pallet-carrier gap (F3).
- **Independent review** — this file is that lane for the measurement document.
- **Full suite vs baseline** — not applicable, no code changed.
