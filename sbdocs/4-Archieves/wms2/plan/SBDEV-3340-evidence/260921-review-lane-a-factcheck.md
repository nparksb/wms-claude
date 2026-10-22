# SBDEV-3340 shadow-gate measurement — adversarial fact-check (lane A)

Reviewed 2026-09-21. Target: `260921-shadow-gate-retirement-measurement.md` (same directory).
Code read from `origin/develop` @ `f2ee75f1` via `git show`, never the working tree (which sits on
`bugfix/SBDEV-2890-transaction-detail-ul-picks`). SQL re-run independently against
`wms2-hydra` (PRD), `nywh-hydra-uat`, `c1wh-shipitez-uat`, `nywh-shipitez-uat`, `wsl-wineco-uat`.
`wms2-wineco-dev` not re-run (dev; every other environment agreed).

**Headline: the numbers all hold. The instrument's characterisation does not.** Four of the
document's framing claims are broken or partially broken; none of them moves the enable/hold
verdict, and one of them (F1) changes what the zeros are allowed to prove.

---

## Method note — a stronger positive control than the document's

The document's control is `under_constrained_type > 0`: "a destination type with constraint rows
exists, therefore the join resolved". That proves the join, not the **predicate**. Mine adds a
counterfactual arm over the identical rows — *what would this query say if the minted type had been
`Tote` instead of `Case`?*

| DB | `would_refuse` (actual, `Case`) | **CONTROL** `would_refuse` if the type were `Tote` |
|---|---|---|
| wms2-hydra (PRD) | 0 | **5** |
| nywh-hydra-uat | 0 | **369** |
| c1wh-shipitez-uat | 0 | **2 230** |
| nywh-shipitez-uat | 0 | **77** |
| wsl-wineco-uat | 34 | **36** |

Non-zero on every tenant: the refusal branch does evaluate true when it should. The zeros are true
zeros, not a silent predicate failure. (This is the control the document should have carried.)

---

## §1 — "The substitute instrument is STRICTLY STRONGER"

### VERDICT: **BROKEN** — severity **High**

It is not a superset of the shadow log. It is a **subset**.

The gate logs *before* the mint and *outside* transaction control; the `unitload_record` row is
written *inside* `transferStock`, which is
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`
(`StockunitService.java:319`). Everything the document needs is in the ordering:

```
StockunitService.java:374   assertMintedContainerIsPermittedAtDestination(palletLocation, …, "pallet-carrier", …)  ← LOG.warn fires here
StockunitService.java:376   unitLoad = unitloadService.createUnitload(…)                                            ← row written here
StockunitService.java:377   stockunitBusinessService.transferStockToUnitLoad(…)                                     ← can throw
StockunitService.java:378   unitloadBusinessService.transferUnitLoadToCarrier(…)                                    ← can throw
```

Post-mint `BusinessException` throw sites, all of which roll the row back while the log line
survives (logging is not transactional):

- `StockunitBusinessService.java:206` — `amount= … requested is more than available=`
- `StockunitBusinessService.java:212` — `Stock not allowed on destinationUnitload=`
- `StockunitBusinessService.java:229` — `Mixed stock not allowed on unitLoad=`
- `UnitloadBusinessService.transferUnitLoadToCarrier` (:349 → `transferUnitLoadToCarrierCore`)
- `StockunitService` new-container site: `throw new BusinessException("No permission to alter damaged stock")`,
  reached **after** the `createUnitload` at :560

Those are ordinary operator errors on a split, not exotic paths.

**It is measurable, and it is not zero.** Unit-load numbers are allocated by
`SequenceTransactionService` under `@Transactional(…, propagation = Propagation.REQUIRES_NEW)`
(:23), so an allocation survives the caller's rollback — a burned number is a create attempt that
did not commit.

```sql
-- wms2-hydra (PRD)
SELECT (SELECT sequencenumber FROM los_sequencenumber WHERE classname='UNIT_LOAD') AS seq_high_water,
       count(DISTINCT label) FILTER (WHERE label ~ '^UL[0-9]+$') AS ul_distinct_labels
FROM unitload_record WHERE recordtype='CREATED';
-- seq_high_water = 502, ul_distinct_labels = 490, max_ul_number = 502
```

**12 of 502 UL allocations on Hydra PRD (2.4 %) never produced a committed `unitload_record` row.**
Activity code is unattributable (a burned number carries none), so this bounds the loss rather than
attributing it — but it is a measured, non-zero, structurally-inevitable gap. The same arithmetic is
useless on WineCo/c1wh, where the label space is reused (`wsl-wineco-uat`: 1 672 556 `CREATED` rows
over 354 719 distinct `UL…` labels) and `max_ul_number` is 1.79 × 10¹² — epoch-shaped labels, not
sequence-shaped ones.

A second, smaller structural gap in the same direction: `UnitloadService.createUnitload(String name, …)`
(:199-218, and the `spawnLocation` overload at :231-251) is a **find-or-create** — on a label hit it
returns the existing unit load and writes **no** record. `MobilePalletizeWriteService.java:288`
documents this in so many words. Both gated sites route through the number-generating overload
(:190), so a hit needs a generated number to collide with a live label; implausible, but it is a
path where the gate logs and no row appears.

**Correct statement:** *In shadow mode the DB derivation reproduces every gate event whose
transaction COMMITTED. It is blind to any transfer that reached a mint site and then rolled back —
12 of 502 UL allocations on Hydra PRD did exactly that. A `would_refuse = 0` therefore does not
entail a shadow-log count of zero; it entails zero among committed transfers.*

Why it does not change the verdict: a rolled-back transfer moved no stock, so a refusal there costs
the operator an error message they were already going to get. But the document's sentence
"**every** event that emits a shadow line also writes a durable row" and the claim that the DB and
the log "agree by construction" are both false as written, and the second is the load-bearing one.

---

## §2 — "The prescribed instrument cannot be read, and never could be"

### VERDICT: **PARTIALLY BROKEN** — severity **Medium**

Every *code* fact checks out:

- `src/main/resources/logback-spring.xml` — one `ConsoleAppender`; the `RollingFileAppender` block
  is inside `<!-- … -->` and the root logger references `CONSOLE` only.
- `application.properties` — no `logging.file.name` / `logging.file.path` anywhere (lines 4-12 are
  the whole logging block); `management.endpoints.web.exposure.include=health,info,metrics,hikaricp,prometheus,tenantpool`
  (:150) — no `logfile`, no `loggers`.
- `Dockerfile`, `Dockerfile_new`, and all three `.github/workflows/docker-image*.yml` — nothing
  redirects, mounts, or ships stdout.
- The shadow line *is* emitted: `logging.level.net.aim_ai=DEBUG` (:8), and it is a `LOG.warn`.

**What the document missed is the runtime.** `.gitlab-ci.yml` (which the brief's file list and the
document both skip — only the GitHub workflows were checked) ends its image job with
`echo "Use this url to deploy this image in kubernetes - ${BUILD_TAG}"`, and the project's own
infrastructure note records deployment as **Portainer webhooks**. On either runtime, stdout-only is
the *recommended* logging configuration, and `kubectl logs` / Portainer's container-log viewer /
`docker logs` is a first-class readout. Nothing here proves an aggregator exists or that retention
covers an operating cycle — but "an instrument that cannot be read, and never could be" describes a
missing mechanism, and the mechanism is the platform standard one.

**Correct statement:** *The application exposes no in-app or HTTP readout of its own logs — stdout
is the only sink. Reading `SBDEV-3340 shadow` therefore requires container-runtime access
(Portainer's log view, `docker logs`, `kubectl logs`), which this session does not have and which no
runbook in `sbdocs/` documents. Retention is the runtime's default and may be shorter than one
operating cycle.*

Proposal **P2** in the document is the right response and survives this correction intact — it is an
access/ownership gap, not an absent instrument.

---

## §3 — Re-running the tenant numbers (five DBs, my own SQL)

### VERDICT: **CONFIRMED** — exact agreement, no disagreement to record

My query is count-based with correlated subqueries and a counterfactual control arm; the
document's is `EXISTS`-based with a `LEFT JOIN` CTE. Same rows, different shape.

| DB | mints_total | unresolved dest | under constrained | **would_refuse** | first → last |
|---|---|---|---|---|---|
| wms2-hydra (PRD) | 5 | 0 | 5 | **0** | 2026-08-13 → 2026-09-03 |
| nywh-hydra-uat | 373 | 0 | 369 | **0** | 2022-04-28 → 2026-04-28 |
| c1wh-shipitez-uat | 2 246 | 0 | 2 230 | **0** | 2022-09-07 → 2026-09-16 |
| nywh-shipitez-uat | 77 | 0 | 77 | **0** | 2025-08-13 → 2025-11-13 |
| wsl-wineco-uat | 27 921 | 3 | 36 | **34** | 2020-03-04 → 2026-09-15 |

Every figure matches the document, including the three unresolved WineCo destinations.

The 33/1 decomposition, re-derived by grouping rather than by hand:

```sql
-- wsl-wineco-uat, the 34 refusable rows grouped
-- → overstock pallet | EmptyPallets | Case | benjaminlobo | 2022-12-17 | 33
-- → overstock pallet | Transfer     | Case | adampetersen | 2026-02-18 |  1
```

Exact match, including both operator names and both dates.

Post-deploy (≥ 2026-09-15; `v0.0.26` is dated **2026-09-15**, confirmed by `git log -1 v0.0.26`):
Hydra PRD **0** MANUAL_SPLIT mints; c1wh **7** mints / **0** refusable (2026-09-16);
WineCo UAT **1** mint — `TransferLane07`, `cases and pallets`, `adampetersen`, unconstrained.
All match.

Two supporting facts I checked that the document asserts without evidence:

- `CODE_MANUAL_SPLIT = "MANUAL_SPLIT"` (`WmsConstants:1035`), `UnitloadRecordType.CREATED = "CREATED"`,
  `UNIT_LOAD_TYPE_BOX = "Case"` (:874) — so the `recordtype`/`activitycode` filter is the right one.
- `873189c8` **is on `origin/main`** (the gate appears 4× in `origin/main`'s `StockunitService.java`),
  so recommending an enable on Hydra PRD is not recommending a toggle for code that is not on the
  production branch. Whether the *running* prd image is at or after that merge was not verified here
  (`/api/public/version` not queried); if it is behind, enabling is a harmless no-op.

---

## §4 — The completeness words

### 4a. "Every `itemdata` defaults to Case" — **CONFIRMED**

```sql
SELECT count(*) FROM itemdata i LEFT JOIN unitload_type t ON t.id = i.defultype_id
WHERE t.name IS DISTINCT FROM 'Case';   -- 0 on all five
SELECT count(*) FROM itemdata i LEFT JOIN unitload_type t ON t.id = i.defultype_id
WHERE t.id IS NULL;                     -- 0 on all five  (no NULL / dangling defultype_id)
```
Totals 2 814 / 2 725 / 3 495 / 1 364 / 10 614 — the document's figures. The second query matters and
the document did not run it: a NULL or dangling `defultype_id` would fall through to the
`UNIT_LOAD_TYPE_BOX` fallback at `StockunitService:360` and `:556`, which is also `Case`, so the
conclusion is doubly safe.

### 4b. "`flowbin` never reaches the gate" — **PARTIALLY BROKEN** — severity **Medium**

True of **one** of the two mint sites. The flow-bin branch is at `StockunitService.java:400`, inside
the `else` arm — the *new-container* path:

```java
} else {                                                   // :382  "transfer to new container"
    Location destinationLocation = locationRepository.findByName(locationName)…   // :392
    if (locationType.getSltname().equals(WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)) {  // :400
        … resolves the fixed-location assignment's unit load, mints nothing …     // :402-426
    } else {
        … new-container gate at :558, createUnitload at :560 …
```

The **pallet-carrier** gate at `:374` is in the `if (isTransferToExistingContainer)` arm (:325-381),
which contains **no flow-bin check at all**. Its destination is `palletLocation` — the location the
scanned pallet currently occupies (`:371`), whatever type that is. A `Pallet`-type unit load resting
at a flow-bin location therefore reaches the gate with a flow-bin destination, and flow-bin refuses
`Case` on every tenant (§4c) — so it would be refused under enforcement.

It is unreachable today by **data**, not by **code**:

```sql
SELECT count(*) FROM unitload u
 JOIN location l ON l.id = u.storagelocation_id
 JOIN location_type lt ON lt.id = l.type_id
 JOIN unitload_type ut ON ut.id = u.type_id
WHERE lt.sltname = 'flowbin' AND ut.name = 'Pallet';     -- 0 on all five tenants
```
Positive control for that zero — the same join, ungrouped, on Hydra PRD returns
`flowbin | PickLocation | 135`, so flow-bin locations do hold unit loads and the join resolves.

**Correct statement:** *A flow-bin destination cannot reach the new-container mint site, because the
flow-bin branch precedes it and mints nothing. The pallet-carrier site has no such branch — it is
reached with whatever location the scanned pallet stands in. No `Pallet` unit load rests at a
flow-bin location on any of the five tenants today (0/5, control 135 non-Pallet ULs at Hydra
flow-bins), so the route is unreachable by data. One pallet parked in a flow bin puts 179–2 470
locations per tenant behind the gate.*

Note this does **not** taint the measurement: the document's `would_refuse` query never excluded
flow-bin destinations in the first place, so its zeros already cover them.

### 4c. Forward-exposure table — **CONFIRMED**

Re-derived per location **type** rather than per location:

| tenant | flowbin | overstock pallet | overstock box | cases and pallets | totes | packages | NoRestriction | System |
|---|---|---|---|---|---|---|---|---|
| Hydra PRD | 179 ✗ | 47 ✓ | 14 ✓ | 13 ✓ | 2 ✗ | 1 ✗ | 11 (0 cons.) | 0 |
| c1wh UAT | 2 470 ✗ | 203 ✓ | 47 ✓ | 13 ✓ | 2 ✗ | 1 ✗ | 45 (0 cons.) | 0 |
| WineCo UAT | 2 149 ✗ | **12 ✗** | 3 ✓ | 583 (0 cons.) | 2 ✗ | 1 ✗ | 120 (0 cons.) | 20 (0 cons.) |

✓ = permits `Case`, ✗ = has constraint rows and `Case` is not among them, `(0 cons.)` = fail-open.
Identical to the document, including WineCo's `overstock pallet` (12 locations) being the sole
tenant-config outlier. The `flowbin` ✗ is real but unreachable per §4b.

### 4d. "No RTS destination on any tenant resolves to a reachable REFUSES-Case type" — **PARTIALLY BROKEN** — severity **Medium**

Conclusion right, instrument wrong. `CancellationReversalService.java:355` replays
`log.getPickfromlocationname()` where `log` is a **`CustomerorderCancellationLog`** (table
`customerorder_cancellation_log`) — not `pickingorder_position`, which is what the document's RTS
table counts.

```sql
SELECT COALESCE(lt.sltname,'<UNRESOLVED>'), count(*)
FROM customerorder_cancellation_log cl
LEFT JOIN location l ON l.name = cl.pickfromlocationname
LEFT JOIN location_type lt ON lt.id = l.type_id
GROUP BY 1;
-- wms2-hydra (PRD) : flowbin | 16     (all 16 under a constrained type, all 16 refuse Case)
-- wsl-wineco-uat   : (no rows)
-- c1wh-shipitez-uat: (no rows)
```

RTS has only ever run on Hydra PRD, 16 rows, every one a flow-bin pick face — which mints nothing.
The document's most alarming RTS figure, "**unresolved 21 388**" WineCo positions, belongs to a table
the RTS path has never read; WineCo's actual replay population is **zero rows**.

Also worth stating, because the document's §"Enforcement would not abort any Return-to-Stock
reversal" does not: `CancellationReversalService:355` passes `isTransferToExistingContainer = false`,
so RTS can only ever reach the **new-container** gate, never the pallet-carrier one — and only when
the destination is non-flow-bin *and* the whole-unit-load relocate branch does not take it first.

**Correct statement:** *`pickingorder_position` is a forward-looking proxy for where a future
reversal could land; the population RTS actually replays is `customerorder_cancellation_log`, which
holds 16 rows on Hydra PRD (all flow-bin) and zero on WineCo and c1wh. Both instruments agree: no
reversal on any tenant has ever replayed a destination that would be refused.*

### 4e. "The gate is off everywhere" — **CONFIRMED** (for the five tenants I can reach)

`SELECT count(*) FROM los_sysprop WHERE syskey='TRANSFER_DESTINATION_CONSTRAINT_ENFORCED'` → **0**
on all five. The document checked two tenants explicitly and generalised; the generalisation holds.
Structurally: `getSysvalue` returns `null` on a miss and `Boolean.parseBoolean(null)` is `false`
(`StockunitService:298`), so absent does read as off.

### 4f. Mint-site enumeration — **CONFIRMED, and complete**

`unitloadService.createUnitload(…)` appears at 31 call sites across `src/main`. Exactly **five** pass
`CODE_MANUAL_SPLIT`: `StockunitService:376` and `:560` (both gated) and
`MobileTransferOrderService:412`, `:418`, `:424` (all ungated). I checked the two multi-line calls a
literal-grep would miss — `ClubLineOrderProcessor:141` is `CODE_PACKAGING_CLUB`,
`MobileReplenishService:1103` is `CODE_REPLENISHMENT`. The document's blind spot #1 / proposal P1
enumeration is exhaustive, not merely illustrative.

---

## §5 — Failure modes of the enable recommendation

### 5a. The refusal returns **HTTP 200**, and a bulk move partially applies — severity **Low**

`StockUnitController.java:156` wraps `transferStock` in `catch (BusinessException e) { errors.add(…) }`
and returns `ResponseEntity.ok(errorMap)` — a 200 carrying `errors[0].message`. The bulk endpoint
(`:270`) does the same **inside a per-id loop**, so under enforcement a multi-select move refuses the
constrained stock units, moves the rest (each `transferStock` is its own transaction), and returns
200. That is pre-existing behaviour for every `BusinessException` on this endpoint, not new — but
"enabling the gate" means operators will meet it, and no 4xx will appear in any HTTP-status-based
monitoring.

Not a trap: message resolution is sound. `BusinessException(String key, Object... parameter)` calls
`super(resolveMessage(Locale.getDefault(), key, parameter))`, so `getMessage()` is the rendered
sentence, not the key — the 1-arg `"placeholder"` trap does not apply. The bundle entry exists in
both files with the argument order the gate's comment claims:
`messages.properties:16` and `messages_en_US.properties:345` →
`unitloadTypeNotPermittedOnLocation=Unit load type %1$s is not permitted on location %2$s (location type %3$s).`

### 5b. The enable recipe is correct, but `workstation` is the load-bearing field — severity **Low**

```java
// SyspropRepository.java:29-31  — "legacy code incorrectly assumes one result"
@Query(value = "select sysvalue from los_sysprop where syskey = :syskey and workstation = 'DEFAULT' order by client_id LIMIT 1", nativeQuery = true)
String findSysvalueBySyskey(@Param("syskey") String syskey);
```

`getSysvalue` (`SyspropService:333-336`) uses only this. Consequences the document does not state:

- `client_id` is **ignored** except as a tie-break — the document's "`client_id = 0`, matching the
  sibling rows" is harmless but not the reason the recipe works.
- `workstation = 'DEFAULT'` **is** required. A row created through the System Properties screen with
  any other workstation value turns nothing on and reports no error.
- This gate is per **tenant**, all-or-nothing — per-client and per-workstation enablement are
  impossible for it, unlike the four-level fallback `getStringDefault` uses.
- Cache direction is the reverse of the document's note: `@Cacheable(… unless = "#result == null")`
  means the *miss* is never cached, so **enabling takes effect on the next read**, while **disabling
  by deleting the row waits out the TTL** with a cached `true`. Prefer `setSysvalue`/the screen for
  the rollback, since it carries `@CacheEvict`; a direct `DELETE` does not.

Hydra PRD's `los_sysprop` has 152 rows, 0 duplicate `syskey`s, 1 distinct `client_id` (0 =
`System-Client`), and `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED = 0|DEFAULT|false` — so the sibling
shape the document copies is right.

### 5c. Nothing else reads `location_constraint` in a way enforcement disturbs — **CONFIRMED**

Readers of `LocationConstraintService.isUnitloadTypePermitted` / `locationConstraintRepository`:
`PutawayDestinationResolver:247`, `PutawayDestinationValidator:175`, `UnitloadBusinessService:275/281`
(inside `transferUnitLoadToLocation`), `LocationConstraintService:53/59/81/85`,
`UtilRestController:827/830`. None is behind `TRANSFER_DESTINATION_CONSTRAINT_ENFORCED`; the sysprop
gates only whether `assertMintedContainerIsPermittedAtDestination` throws. Note
`UnitloadBusinessService:322` already throws the *same* message key unconditionally from the
relocate path, so operators can already see this sentence today — enforcement widens who sees it,
it does not introduce it.

### 5d. Hydra PRD's "enable" rests on five lifetime events — severity **Low**

Positive control I added: `recordtype='CREATED'` rows on Hydra PRD since 2026-09-15 = **72**
across all activity codes, of which **0** are `MANUAL_SPLIT`. The database is live and the zero is a
true zero — but the gated shape has occurred 5 times in Hydra PRD's entire history and 0 times since
the deploy. The evidence supports *"the blast radius is 3 locations and no historical event would
have been refused"*; it does not support *"one operating cycle was observed clean"*, which is what
the retirement instruction asked for. Recommend saying so in the recommendation row rather than
leaving "0 refusable events in the whole record" to carry it.

---

## §6 — Blind spot #5 is resolvable, and resolves clean

The document lists `location.name` uniqueness as unverified. It is verifiable in one line:

```sql
SELECT count(*) FROM (SELECT name FROM location GROUP BY name HAVING count(*) > 1) d;  -- 0 on all five
```

So the `l.name = ur.tolocation` join is 1:1 on every tenant measured and the blind spot can be
struck. (Related, and genuinely unenforced: `unitload.labelid` uniqueness exists only in the v1→v2
onboarding set — `db/v1-to-v2-onboarding/schema/V2.1.01__add_unique_constraint_unitload_labelid.sql` —
not in `db/migration`, so tenants provisioned outside that path have no such index. That is what
makes the find-or-create in §1 worth naming rather than dismissing.)

---

## Findings summary

| # | Claim | Verdict | Severity |
|---|---|---|---|
| F1 | "The substitute instrument is STRICTLY STRONGER" / "every event that emits a shadow line also writes a durable row" | **BROKEN** — it is a subset; post-mint rollback drops the row and keeps the log line; 12/502 burned UL numbers on Hydra PRD | **High** |
| F2 | "`flowbin` never reaches the gate" | **PARTIALLY BROKEN** — true only of the new-container site; the pallet-carrier site has no flow-bin branch. Unreachable by data (0/5), not by code | **Medium** |
| F3 | RTS analysis | **PARTIALLY BROKEN** — measured `pickingorder_position`; the replay source is `customerorder_cancellation_log` (16 rows Hydra, 0 WineCo, 0 c1wh). Same verdict, wrong instrument | **Medium** |
| F4 | "The instrument cannot be read, and never could be" | **PARTIALLY BROKEN** — code facts confirmed, but `.gitlab-ci.yml` (unchecked) names kubernetes and the deploy is Portainer; stdout is the platform-standard readout | **Medium** |
| F5 | Enable recipe / sysprop semantics | Correct, incomplete reasoning — `workstation='DEFAULT'` is load-bearing, `client_id` ignored, cache lag applies to **disable** not enable | **Low** |
| F6 | Refusal ergonomics | Not stated — refusal surfaces as HTTP 200 with `errors[0].message`; bulk move partially applies. Message resolution itself is sound | **Low** |
| F7 | Hydra PRD confidence | Not stated — 5 lifetime gated events, 0 post-deploy (control: 72 non-MANUAL_SPLIT creates). Low blast radius ≠ an observed clean cycle | **Low** |
| F8 | Blind spot #5 (`location.name` uniqueness) | Resolvable and clean — 0 duplicates on all five; strike it | **Low** |

**Re-derived and CONFIRMED unchanged:** all five tenants' `mints_total` / `unresolved` /
`under_constrained` / `would_refuse` / date ranges; the 33-vs-1 decomposition with both operators and
both dates; the all-`Case` `itemdata` census plus the NULL/dangling check the document omitted; the
location-type exposure table on three tenants including WineCo's 12-location outlier; the gate
sysprop being absent on all five; the five-site `MANUAL_SPLIT` mint enumeration; the post-deploy
counts; `v0.0.26` dated 2026-09-15; and that `873189c8` is on `origin/main`.

**Bottom line on the decision:** the enable/hold recommendation survives — enable on the four
all-zero tenants, hold WineCo pending the `overstock pallet` config question. What must change is the
document's claim about what its zeros prove (F1), and three framings that a later reader would
otherwise inherit as settled (F2, F3, F4).
