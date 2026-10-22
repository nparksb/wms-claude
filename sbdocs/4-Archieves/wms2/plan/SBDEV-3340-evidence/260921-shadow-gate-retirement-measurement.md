# SBDEV-3340 — TRANSFER_DESTINATION_CONSTRAINT_ENFORCED shadow-gate retirement measurement

Measured 2026-09-21. **Revision 3** — reviewed by two independent lanes (reports alongside this file);
every correction they raised is folded in below and attributed. Status: **awaiting Nam's decision on
whether to enable per tenant.** No code changed and no sysprop was written.

## What was asked

`WmsConstants`, javadoc on `SYSTEM_PROPERTY_TRANSFER_DESTINATION_CONSTRAINT_ENFORCED_KEY`:

> To retire it: run one operating cycle, grep `SBDEV-3340 shadow`, and read the lines by their
> `route=` and `stockUnit=` fields, not only by count — enable per tenant where the count is zero.

## The prescribed instrument has no readout path available to this session

`logback-spring.xml` on `origin/develop` declares a **CONSOLE appender only** — the `RollingFileAppender`
is commented out. `application.properties` sets no `logging.file.name`, so `/actuator/logfile` does not
exist, and `management.endpoints.web.exposure.include` lists `health,info,metrics,hikaricp,prometheus,tenantpool`.
Nothing in `src/`, the `Dockerfile`, or the three `.github/workflows/docker-image*.yml` ships logs anywhere.

⚠ **Corrected (lane A, F4). An earlier draft said the log "cannot be read, and never could be" — that
overreaches.** It was written from an incomplete instrument set: `.gitlab-ci.yml` was never checked, and
the deployment is container-orchestrated (Portainer webhooks / kubernetes), where **stdout-only IS the
platform-standard readout**. The mechanism is not missing; the *access* is. This is an ownership gap —
whoever holds orchestrator access can read these lines today and nobody wrote down that they must.

## The substitute instrument, and what it is and is not

In shadow mode the gate logs and **then proceeds with the mint**. `UnitloadService.createUnitload`
("unitloadRecordService.recordForCreateUnitLoad") writes a `unitload_record` row with
`recordtype='CREATED'`, `activitycode` = the caller's code (`CODE_MANUAL_SPLIT` at both gated sites) and
`tolocation` = the destination location's name. Replaying today's `location_constraint` config over those
rows reproduces the gate's own predicate (`LocationConstraintService.isUnitloadTypePermitted`: fail-open on
zero constraint rows for the destination's location type, else membership of the minted type), back to 2020
rather than to the deploy.

### ⚠ It is a LOWER BOUND, not a superset — corrected from "strictly stronger" (lane A, F1, High)

The earlier draft had this backwards. The gate's `LOG.warn` fires **before** the mint and outside
transaction control; the `unitload_record` row is written inside `transferStock`, which is
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.
Any later throw in the same transaction — the three in `transferStockToUnitLoad` (over-amount,
`stockunitallowed`, mixed stock), `transferUnitLoadToCarrier`, or the "No permission to alter damaged
stock" throw that follows the new-container mint — **rolls the row back while the log line survives**.

That gap is measurable, because `SequenceTransactionService` allocates numbers `REQUIRES_NEW` and a burned
sequence number therefore commits alone: Hydra PRD's `los_sequencenumber.UNIT_LOAD` stands at 502 against
490 distinct committed `UL…` CREATED labels — **12 create attempts (2.4 %) that never committed**.

**So `would_refuse = 0` means "zero among committed transfers", not "zero shadow lines".** For the enable
decision the distinction is benign — a transfer that rolled back already failed, and enforcing the gate
would not change that outcome, only the message — but the claim has to be stated at its real strength.

### The query (run per tenant, unchanged)

```sql
WITH m AS (
  SELECT ur.id, ur.created, ur.tolocation, ur.unitloadtype,
         l.id AS loc_id, l.type_id AS loc_type_id, ut.id AS ul_type_id,
         (SELECT count(*) FROM location_constraint lc
           WHERE lc.storagelocationtype_id = l.type_id) AS n_constraints,
         EXISTS (SELECT 1 FROM location_constraint lc
                  WHERE lc.storagelocationtype_id = l.type_id
                    AND lc.unitloadtype_id = ut.id) AS permitted
  FROM unitload_record ur
  LEFT JOIN location      l  ON l.name  = ur.tolocation
  LEFT JOIN unitload_type ut ON ut.name = ur.unitloadtype
  WHERE ur.recordtype = 'CREATED' AND ur.activitycode = 'MANUAL_SPLIT'
)
SELECT count(*)                                                    AS mints_total,
       count(*) FILTER (WHERE loc_id IS NULL)                      AS dest_unresolved,
       count(*) FILTER (WHERE ul_type_id IS NULL)                  AS ultype_unresolved,
       count(*) FILTER (WHERE n_constraints > 0)                   AS under_constrained_type,
       count(*) FILTER (WHERE n_constraints > 0 AND NOT permitted) AS would_refuse,
       min(created)::date, max(created)::date
FROM m;
```

`under_constrained_type` is the **positive control**: large and non-zero on every tenant, so a
`would_refuse = 0` is a true zero and not a broken join.

## Results — all six v2 databases

| DB | env | mints_total | dest_unresolved | under constrained type | **would_refuse** | first → last mint |
|---|---|---|---|---|---|---|
| `wms2-hydra` (nywh) | **PRD** | 5 | 0 | 5 | **0** | 2026-08-13 → 2026-09-03 |
| `nywh-hydra-uat` | UAT | 373 | 0 | 369 | **0** | 2022-04-28 → 2026-04-28 |
| `c1wh-shipitez-uat` | UAT | 2 246 | 0 | 2 230 | **0** | 2022-09-07 → 2026-09-16 |
| `nywh-shipitez-uat` | UAT | 77 | 0 | 77 | **0** | 2025-08-13 → 2025-11-13 |
| `wsl-wineco-uat` | UAT | 27 921 | 3 | 36 | **34** | 2020-03-04 → 2026-09-15 |
| `wms2-wineco-dev` | DEV | 20 649 | 4 | 41 | **34** | 2020-03-04 → 2026-09-20 |

### Corroboration — three instruments now, not one

Lane A re-derived every tenant figure with differently-shaped SQL and a stronger control, and got **exact
agreement**, including the 33/1 decomposition down to both operator names and dates. This generic query
also independently reproduces figures the ticket derived by hand with different SQL: the **34**; the
**33 at `EmptyPallets` on 2022-12-17** (operator `benjaminlobo`) and **1 at `Transfer` on 2026-02-18**
(operator `adampetersen`); **78 500** WineCo picks from `cases and pallets`; and Hydra PRD's **267 locations**.

### Every would-refuse event is historical

WineCo's most recent is **2026-02-18**, seven months ago. Post-deploy — from `v0.0.26`, the first release
tag containing `873189c8`, cut 2026-09-15 (dev has run it since the 2026-09-14 merge):

- Hydra PRD: **0** `MANUAL_SPLIT` mints. Control (lane A): 72 non-`MANUAL_SPLIT` creates in the same
  window, so the database is live and the zero is about this route, not about traffic.
- ShipItEZ c1wh UAT: 7 mints, 0 refusable.
- WineCo UAT: 1 (`TransferLane07`, `cases and pallets`, unconstrained). WineCo dev: 1 (`StagingLane79`,
  same type). Neither refusable.

So the shadow log would have carried **zero lines** on every environment — subject to the lower-bound
caveat above.

## Forward exposure — the config surface

Every `itemdata` row on every tenant defaults to unit-load type **Case** (Hydra PRD 2 814/2 814, Hydra UAT
2 725, ShipItEZ c1wh 3 495, ShipItEZ nywh 1 364, WineCo 10 614) — one group-by row per tenant, so both mint
sites always mint `Case`. `UNIT_LOAD_TYPE_BOX = "Case"` (`WmsConstants:874`).

| tenant | REFUSES Case — flowbin | REFUSES Case — reachable | permits Case | unconstrained |
|---|---|---|---|---|
| Hydra PRD | 179 | totes 2 · packages 1 = **3** | overstock pallet 47 · overstock box 14 · cases and pallets 13 | NoRestriction 11 |
| Hydra UAT | 318 | totes 2 · packages 1 = **3** | overstock pallet 69 · overstock box 14 · cases and pallets 13 | NoRestriction 36 |
| ShipItEZ c1wh | 2 470 | totes 2 · packages 1 = **3** | overstock pallet 203 · overstock box 47 · cases and pallets 13 | NoRestriction 45 |
| ShipItEZ nywh | 96 | totes 2 · packages 1 = **3** | overstock pallet 67 · overstock box 6 · cases and pallets 13 | NoRestriction 15 |
| WineCo UAT | 2 149 | **overstock pallet 12** · totes 2 · packages 1 = **15** | overstock box 3 | cases and pallets 583 · NoRestriction 120 · System 20 |

On the four recommended tenants those three reachable locations are named: **`EmptyTotes`,
`FinishedPicking`, `Packaging`** (lane B). Not one unit load of a non-permitted type sits at any of them
today, and `Damaged`, `CycleCount` and `Clearing` all permit `Case` or fail open, so the damaged-stock
workflow is untouched.

### ⚠ "flowbin never reaches the gate" holds for ONE of the two sites (lane A, F2)

The flow-bin short-circuit sits inside the **new-container** arm, so a flow-bin destination there mints
nothing and never reaches the gate. The **pallet-carrier** gate is in the `isTransferToExistingContainer`
arm, which has **no flow-bin check at all** — its destination is the scanned pallet's own location.

It is unreachable by **data**, not by code: 0 `Pallet` unit loads at flow-bin locations on all five tenants
(control: 135 `PickLocation` unit loads at Hydra flow-bins, so the join resolves). **One pallet parked in a
flow bin puts 179–2 470 locations per tenant behind the gate**, since `flowbin` refuses `Case` everywhere.
That is the single condition that would turn a quiet gate loud, and it is an operational state, not a
code change.

## Enforcement would not abort a Return-to-Stock reversal

⚠ **Re-based on the right table (both lanes).** `CancellationReversalService` replays
`log.getPickfromlocationname()` off **`CustomerorderCancellationLog`**, not `pickingorder_position`.
Re-measured on the table the code actually reads:

| tenant | reversal-log rows by destination type |
|---|---|
| Hydra PRD | **16, all `flowbin`** — mints nothing |
| Hydra UAT | **0 rows** |
| WineCo UAT | **0 rows** |
| ShipItEZ c1wh | **0 rows** |

**Forward RTS exposure is zero on every tenant.** The `pickingorder_position` figures in revision 1
(827 552 WineCo flow-bin picks, 78 500 from `cases and pallets`, 21 388 unresolved) describe a table RTS
has never read. They remain valid as a picture of where picking happens — and the 21 388 unresolved
names are a real separate shape, failing earlier at `MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND` — but
they are not the RTS denominator and revision 1 was wrong to use them as one.

Lane B confirms the javadoc's warning is accurate on both halves — an enforced refusal *does* abort the
whole reversal — but the abort is atomic and clean: no outbox message, no `reversal_completed_at` stamp,
the row stays pending. A sequence number is burned (`REQUIRES_NEW`), which is cosmetic.

## The argument for enabling that this document originally missed (lane B)

`UnitloadBusinessService.transferUnitLoadToLocation` **already enforces this exact predicate,
unconditionally, behind no sysprop**, throwing the identical `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION`
key. That is the arm `transferStock` takes when the move drains the source container.

So today: moving a **whole** `Case` container into a totes-only bin is already refused; moving **part** of
it succeeds. Whether the rule applies is decided by geometry. **Enabling does not add a rule — it stops one
of two sibling routes exempting itself from a rule the system already enforces.** It should also be said
plainly that the gate will almost never fire: Hydra PRD has 5 `MANUAL_SPLIT` mints in its entire history.

## Gate state today

`TRANSFER_DESTINATION_CONSTRAINT_ENFORCED` has **no `los_sysprop` row on any tenant** (checked explicitly
on Hydra PRD and WineCo UAT; the constant is deliberately un-seeded by Flyway). Absent reads as off.
Siblings for contrast: `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` is `false` on Hydra PRD, `true` on
WineCo UAT; `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` is `true` on both.

## Recommendation

| tenant | recommendation |
|---|---|
| **Hydra PRD** | **Enable, first.** 0 refusable events in the whole record, 3 reachable REFUSES-Case locations, zero RTS exposure. Smallest population in the estate (5 lifetime mints), so it is also the cheapest place to be wrong. |
| Hydra UAT · ShipItEZ c1wh · ShipItEZ nywh | **Enable** after Hydra PRD — same shape, larger histories, all zero. |
| **WineCo UAT / dev** | **Hold.** 34 refusable mints against today's config, all historical. |

### ~~Precondition before enabling~~ — WITHDRAWN: lane B's F3 is FALSE (revision 3)

Lane B reported that only one of the two gated mint sites is test-pinned, on the evidence that **no test
references the `"pallet-carrier"` route literal**. That is a true statement about the literal and a false
conclusion about the guarantee. `StockunitServiceToteContainerRelocationUnitTest` contains
`palletCarrierMintSiteIsAlsoGated`, which drives the `isTransferToExistingContainer` arm with a scanned
pallet at `EmptyPallets` and asserts `verify(locationConstraintService).isUnitloadTypePermitted(...)` —
it pins the site by **behaviour**, and so never spells the route label the sweep searched for.

**Settled by running it, not by reading it** (2026-09-21, detached worktree at `origin/develop@f2ee75f1`):

| | result |
|---|---|
| baseline | `tests="8" errors="0" skipped="0" failures="0"` |
| mutant — the `assertMintedContainerIsPermittedAtDestination(palletLocation, …)` call deleted | `tests="8" failures="1"` |
| which test | **only** `palletCarrierMintSiteIsAlsoGated`, at its `verify` line |
| message | `Wanted but not invoked:` on `isUnitloadTypePermitted` — **attributable**, it names the gate |

The baseline run also emitted `SBDEV-3340 shadow: … via route=pallet-carrier …`, which is direct evidence
the suite exercises that site.

**There is no test gap and no precondition. Enabling needs no code change at all.**

This is the third time in this workspace that a name- or path-shaped search has established the absence of
a *string* and been read as the absence of a *guarantee*
(`absence-of-a-path-is-not-absence-of-the-guarantee`). It was caught here only because implementing the
"fix" started by opening the file the gap was supposed to be in.

### On WineCo — the question, corrected (lane B F2)

Revision 1 asked "why does WineCo's `overstock pallet` exclude `Case` when four siblings permit it?" That
rests on a false equivalence: WineCo's 12 `overstock pallet` locations are all **process lanes**
(`EmptyPallets`, `Gate_01`–`06`, `Shipped`, `Palletizing`, `Transfer`…), while Hydra's 47 mix lanes with
**racking** (`INVZ1…`, `1V4O1C1`). "Make WineCo match the siblings" would widen every gate and the Shipped
lane. The answerable question is narrower: **should a partial move mint a `Case` at `EmptyPallets` and
`Transfer`** — the only two locations in the 34?

### Enable recipe — corrected twice

One `los_sysprop` row per tenant: `syskey = TRANSFER_DESTINATION_CONSTRAINT_ENFORCED`, `sysvalue = true`,
**`workstation = 'DEFAULT'`** — this field is load-bearing and `client_id` is **ignored** by the lookup
(`SyspropRepository`, native query with `LIMIT 1`), so setting `client_id` per client will not scope it.

⚠ **The rollback lever described in revision 1 does not exist** (lane B, F1, High). That draft said a write
through the System Properties screen evicts the cache where a psql write does not. Both are cache-blind:
`SyspropRepository` is a `@RepositoryRestResource`, so the screen's `PUT /sysprop/{id}` goes through Spring
Data REST and never enters `SyspropService`, where the `@CacheEvict` lives. The asymmetry that does hold
runs the other way, and favours enabling:

- **OFF → ON is immediate.** `getSysvalue` is `@Cacheable(..., unless = "#result == null")`, so the absent
  row was never cached and the first read after the insert sees `true`.
- **ON → OFF is bounded by the ~2-minute TTL and cannot be forced** from outside the app, per replica
  (Caffeine unless the `redis` profile is active — infra-side, unverified here).

Plan rollback around a two-minute wait, not around an eviction that will not happen.

**What a refusal looks like to the operator:** HTTP **200** with the message in `errors[0].message`, and a
**bulk** move partially applies — `bulkTransferStock`'s controller is not `@Transactional` and the catch is
inside the loop, so earlier positions commit and the call still returns 200. The message names a container
type the operator never chose, which is cosmetic on Move Stock and would be confusing on RTS.

## Blind spots — stated, not glossed

1. **Lower bound, not exact** — see the corrected section above: rolled-back transactions emit a log line
   and leave no row. Measured at 2.4 % of create attempts on Hydra PRD.
2. **The substitute over-counts the gated population.** `MANUAL_SPLIT` mints also come from
   `MobileTransferOrderService` (three `createUnitload` calls), which the gate does not cover — 1 612 of
   WineCo's 27 921, none under a constrained type. A zero over a superset is still a zero over the subset.
   The transfer-lane split used an `ILIKE 'TransferLane%'` name prefix: a bucketing aid, not a claim about
   which code path wrote each row.
3. **Exactly 5 `CODE_MANUAL_SPLIT` mint sites in `src/main`** — 2 gated, 3 in `MobileTransferOrderService`.
   Verified by lane A against all 31 `createUnitload` call sites, including two multi-line ones a literal
   grep misses.
4. **Config is read as of today.** A 2022 event graded against 2026 constraints — the right basis for an
   enable-now decision, the wrong basis for a historical audit.
5. **Route attribution is not reproduced here.** The log's `route=` distinguishes the two mint sites; the
   DB rows do not carry it. Immaterial — either route refusing is a refusal.
6. ~~`location.name` uniqueness~~ — **resolved.** 0 duplicate names on all five tenants (Hydra PRD 267/267,
   WineCo UAT 2 890/2 890; `unitload_type` 7/7 on both). A property of today's rows, not a schema guarantee.
7. **Six databases is what the MCP registry exposes.** A v2 tenant outside that set was not measured.

## Proposed, NOT filed — per the ticket policy

SBDEV-3340 is `on prod`, so the carve-out applies: findings go to **new** tickets, not onto it. Ranked.

~~**P1 — pin the `pallet-carrier` gate call site.**~~ **WITHDRAWN** — the pin exists and was proved to
kill its mutant. See the struck section above.

**P1 (was P2) — `MobileTransferOrderService` mints containers with no `location_constraint` check (3 sites, T2).**
The identical uncovered shape SBDEV-3340 closed inside `transferStock`. Destinations are transfer lanes,
unconstrained on all five tenants, so zero live exposure — this is invariant-over-instance, and it is what
makes the shadow count mean what it says. ~1 hour behind the same sysprop.

**P2 (was P3) — shadow-mode gates have no owned readout (process, not code).** The mechanism exists (container
stdout via the orchestrator); the *access* is unwritten, so the next shadow gate inherits the same dead
instrument. Either document who reads these and how, or have future shadow gates write a row rather than a
log line. Not a ticket until someone owns it.

## Floor

- **DB query confirming the symptom:** six, one per database, each with a positive control; re-derived
  independently by lane A with differently-shaped SQL and exact agreement.
- **Mutation check:** one run, on the claim that mattered — the pallet-carrier gate call deleted at
  `origin/develop@f2ee75f1`, one test red, message attributable. It **disproved** a review finding rather
  than confirming one.
- **Failing test:** not applicable — no code changed, and none is needed. The gate's own conditionals were
  PIT-killed on the original ticket.
- **Independent review:** two lanes, both reported to file in this directory. One High and three Mediums
  raised against revision 1: three stand and are folded in above with attribution; **one (lane B F3) was
  false and is struck**, disproved by the mutation run. A review finding is a hypothesis until an
  instrument agrees with it.
- **Full suite vs baseline:** not applicable — no code changed.
