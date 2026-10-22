---
ticket: SBDEV-3736
lane: critic (independent adversarial review)
reviewed: sbdocs/3-Resources/reports/261013-returns-audit-linkage-field-map.md (+ lane-wms.md, lane-oms.md, db-wineco-prd.md)
code: wms2-api origin/develop 11468c4a · oms-laravel-api origin/develop 1369c109 (git show / git grep only)
db: wsl-wineco-prd (wh01_om1_v2), read-only, 2026-10-13
created: 2026-10-13
---

# SBDEV-3736 — critic review of the returns-audit linkage report

**VERDICT: REVISE.** Mode: started THOROUGH, escalated to ADVERSARIAL after F1–F3.

The headline holds: **no SBDEV-2778 field needs a schema change.** I could not break it. Field 1 holds,
because one return per parcel is enforced on both sides (OMS SCAN rejects a re-scan,
`QaReturnService.php:106-120`; the WMS rejects a duplicate `reference_id` with `ENTITY_ALREADY_EXITS`,
`AdviceRestController` create() plus the UNIQUE `uk_4d13b6sg589c6y88tkm98xl89`).

Three other things do not hold:
- The **re-tier to T2** is stated unconditionally. It is not unconditional.
- The **cross-system lookup on parcel_id** is presented as complete, but the OMS-side and WMS-side writes are
  not atomic. The OMS code itself documents this.
- The **reference join** the report points readers to blanks the field-8 destination for 86% of return ULs.
  It falls into the same relabel trap that §5.4 warns about.

The other issues are attribution and precision. Most of the PRD population was written by v1, field 2 does not
name a column, and two of the "small code changes" change a customer-visible report.

Findings: **High 3 · Medium 4 · Low 5** (12 total).

---

## High

### F1. The WMS and OMS writes are not atomic, so a WMS RETURN advice can exist with no matching managed OMS return. The report treats the parcel_id lookup as complete.
- **Report location:** §5.7 ("every WMS RETURN advice implies disposition = Restock"; "QA user and QA completion
  time are therefore a cross-system lookup on `parcel_id`, not a missing datum"), §7 verdict paragraph
  ("Every remaining field is either a WMS join or a cross-system lookup on `parcel_id`"), field rows 6, 9, 10, S6.
- **Evidence:**
  - `QaReturnService::updateReturnManagement` runs inside `DB::connection('tenant')->transaction` (`:339`). It
    marks the return managed (disposition, `manage_date`, `managed_by`) **before** it calls the WMS (`:386-387`).
    Any WMS failure throws and rolls all of that back (`:383` "A WMS failure rolls back the whole manage
    transaction").
  - The WMS side is not transactional with it. `create()` commits the advice, and auto-receive commits stock
    in its own tenant transaction (the F1b comment in `AdviceRestController`). OMS calls with
    `timeout = 30 s` and `retryAttempts = 3` (`WmsApiService.php:36-37`).
  - The OMS code names the resulting state explicitly at `QaReturnService.php:738-739`: *"ENTITY_ALREADY_EXITS,
    which means stock for this parcel was already advised — most likely by an earlier attempt that reached WMS
    before this transaction rolled back"*. It then throws and asks a human to reconcile (`:747-757`).
  - Result: the WMS has a FINISHED RETURN advice with received stock, while OMS `returns` has
    `managed = 0`, `disposition = NULL`, `manage_date = NULL`, `managed_by = NULL`. The operator can later
    manage it with a **non-Restock** disposition, because only Restock calls the WMS. In that case OMS
    actively contradicts the WMS.
  - S6 makes this worse: the `service_log` row for the failed attempt is rolled back as well (`logWmsRequest`
    writes through `ServiceLog` on the tenant connection, `WmsApiService.php:786-806`). So OMS keeps **no**
    trace that the WMS advice exists.
  - Partial mitigation: the WMS `IdempotencyFilter` replays a completed request when the bytes are identical.
    That covers an in-request retry after a completed first attempt. It does not cover a first attempt that is
    still running when the 30 s timeout fires, all three attempts timing out, or a user retry with different
    quantities.
- **Why it matters:** an audit's job is to find exactly this population: stock that was put back into
  inventory with no managed return behind it. The report's design (a WMS report joined to OMS `returns` on
  parcel_id) silently yields blank or contradicting OMS fields for these rows, and the report never measures
  how many there are.
- **Correction:**
  1. Add a §5 subsection and a §9 open question: "OMS↔WMS divergence: WMS RETURN advices whose OMS `returns`
     row is unmanaged or non-Restock".
  2. Run that count against the OMS tenant DB, which no lane has queried, before claiming the lookup is complete.
  3. Make the audit deliverable *flag* the mismatch (`advice exists AND (returns.managed = 0 OR disposition NOT
     advises_wms)`) instead of only joining.
  4. Raise S6 from "trail cleanliness" to "removes the only OMS evidence of a divergent advice".

  This stays a query or code concern. It does not need a schema change, so the headline survives.

### F2. "Re-tier T3 → T2" is presented as unconditional, but two of the three scoping decisions put it back at T3 under the router's own rules.
- **Report location:** §7 last paragraph, §8 recommendation ("re-tier SBDEV-3736 from T3 → T2 … one
  cross-system read contract"), §8 decisions 2 and 3, and the side-finding routing ("all sub-T3 → onto
  SBDEV-3736").
- **Evidence:** `wms-triage/SKILL.md:61` lists the T3 shapes: *"authorization · data integrity · **Flyway
  migration** · **multi-repo** · irreversible · root cause genuinely unknown"*.
  - Decision 3 (the `unitload_record(label)` index) is a Flyway migration. On WineCo PRD `unitload_record` has
    about 6.8 M rows and 1,410 MB (`pg_class`, measured today), and its only index is the pkey (confirmed via
    `pg_indexes`). Runtime Flyway runs at boot in every environment, so a plain `CREATE INDEX` takes a
    write-blocking lock on a hot audit table during startup. A `CONCURRENTLY` index cannot run inside
    Flyway's default transaction. That is T3 risk, not "index-only".
  - Decision 2, option 2 ("an OMS-side screen that calls a new WMS read endpoint") spans wms2-api,
    oms-laravel-api and siteboss-frontend, so it is multi-repo and therefore T3.
  - Routing S4–S6 (oms-laravel-api) onto SBDEV-3736, a WMS ticket, makes the ticket multi-repo by itself, even
    though each finding is individually sub-T3.
- **Correction:** rewrite §8 as a conditional:
  - **T2 only if** the deliverable is a WMS-only report or an ad-hoc query (options 1 or 3), **and** the label
    index is out of scope, **and** S4–S6 go to an OMS ticket instead of this one.
  - Otherwise the ticket stays T3. If the index is wanted, also say that ordernumber or created-bounded id-range
    access may make it unnecessary (see F3).

### F3. The reference join that the report points readers to blanks the put-away destination for 538/626 return ULs (86%), because of the same relabel trap that §5.4 describes.
- **Report location:** §10 ("`lane-wms.md` (incl. the reference join SQL, §4)"), §7 rows 7 and 8, and the
  §5.4 rule ("join unit loads by id via `goodsreceiptposition`").
- **Evidence:**
  - The lane-wms §4 SQL joins `unitload u ON u.id = grp.unitload_id` (correct). It then joins
    `unitload_record r WHERE r.label = u.labelid`.
  - `unitload_record` has no unitload id column, and its `label` keeps the **original** label. The
    `unitload.labelid` column is rewritten on SEND_TO_NIRWANA.
  - I re-measured this on PRD. For UL id 32090437 (`IBOL014721-000000`), the current `unitload.labelid` is
    `UL346197-X-32090437`. Its `unitload_record` rows 32090438 (CREATED) and 32090442 (TRANSFERRED →
    `PutAwayLane`, ordernumber `IBOL014721-000000`) carry `label = 'UL346197'`.
  - 538 of the 626 180-day return ULs carry `-X-` labels (re-run today: 626 total, 538 relabelled, 0
    dangling). `r.label = u.labelid` matches none of those 538.
  - The lane says it ran this query against UAT advice 35074049. Those ULs were still at `PutAwayLane` and had
    not been relabelled, so the fixture did not exercise the failure.
  - Field 7 has the same issue: `u.labelid` returns the *mutated* label, not the "created UL ID".
- **Correction:**
  - State that field 8 cannot follow the "join by id" rule, because `unitload_record` has no id column.
  - Prescribe `r.ordernumber = ap.number AND r.recordtype = 'TRANSFERRED'`. This is verified: 86/86 for the
    post-cutover cohort, scoped to `id > 33000000`. Alternatively use
    `r.label = regexp_replace(u.labelid, '-X-[0-9]+$', '')`.
  - Report the created UL label as that stripped form, or as `stockrecord.tounitload` of the STOCK_CREATED row.
  - Fix or annotate the lane-wms §4 SQL, and add a relabelled UL to the test fixture.

## Medium

### F4. 86% of the "PRD population" was written by v1 code, not wms2. The report presents it as evidence about the v2 write path.
- **Report location:** §4 Method, §5.2 ("626/626"), §5.3 ("1252 = 626 × 2"), §5.9 ("`anonymous` 540 rows
  (2026-04-17 → 2026-09-22)"), §7 confidence line ("high … PRD + UAT measured"), §11.
- **Evidence:**
  - WineCo went live on WMS v2 PRD on 2026-09-26. Rows before that date were migrated from the v1 DB. The
    timestamps show it: pre-cutover `created` values have ms precision, post-cutover values have µs.
  - Re-run today: 128 of the 150 advices and 540 of the 626 positions fall before 2026-09-22.
  - The `anonymous` vs `oms_integration` split (540 / 86) lines up exactly with the cutover. That is v1 vs v2,
    not the v2 "missing oms_integration user" fallback that lane-wms §4 row 9 implies.
  - §5.7 ("every WMS RETURN advice implies disposition = Restock") is derived from oms-laravel-api's
    `advises_wms` gate. The 2,689 historic RETURN advices (2020 →) came from the v1 OMS or qa-api path.
- **Mitigating evidence:** I re-measured the **v2 cohort alone** (`advice.created > 2026-09-26`): 22 advices,
  86 positions, 86/86 with exactly one GRP, 0 without a GRP, 0 damaged, 22/22 with `created = modified`,
  operator `oms_integration` only, and 86 TRANSFERRED `unitload_record` rows with `ordernumber`. The
  conclusions hold. The sample size for the code under test is n = 22, not 150.
- **Correction:**
  - Split every PRD count into v1-era and v2-era. State n = 22 advices for the v2 path.
  - Reword §5.9 to say `anonymous` is the v1 principal.
  - Scope the §5.7 "implies Restock" claim to oms-laravel-api-originated advices.

### F5. Field 2 ("Original order ID") is classed (a) without naming the column. The WMS has no OMS order id.
- **Report location:** §7 row 2 ("WMS: `customerorder.externalnumber = parcel_id` (150/150 on PRD)").
- **Evidence:**
  - The `customerorder` columns on PRD (`information_schema`) include no OMS order id.
  - The join yields `clientordernumber`, which is the merchant's order number. PRD samples: `'97564336432:807'`,
    `'4967-19482:4967'`, `'130669165'`, `'16340'`.
  - `customerorder` is set from `order.getClientOrderNumber()` / `getUniqueId()`
    (`OrderBatchCreationService.java:107,121`). The OMS `parcel.order_id` is never sent.
- **Correction:**
  - Name the column (`customerorder.clientordernumber`) and state that it is the client or merchant order
    number.
  - If the AC means the OMS order id, field 2 is **(b)** (OMS `parcel.order_id` via parcel_id) on every
    facility, not just cross-facility.
  - Add this to §8's decisions for Nam.

### F6. The two "small code changes" (§5.5 final bin, S3 damaged orderNumber) change the output of the customer-visible Transaction Report. The report does not mention this.
- **Report location:** §5.5, §5.6, §8 ("two small code changes … write `adviceposition.number` into the existing
  `stockrecord.ordernumber`"), S3 (T1).
- **Evidence:**
  - V2.2.25's resolver is `LEFT JOIN LATERAL (… FROM adviceposition rap JOIN advice ra … type='RETURN' …
    WHERE rap.number = sr.ordernumber …)` (`V2.2.25__transaction_detail_return_order_refs.sql:245-253`). It is
    keyed on `sr.ordernumber` only, **not** gated on `sr.activitycode`.
  - `sr.ordernumber` is also emitted as `transaction_number` (`:198`).
  - So once the DAMAGED (S3) or put-away TRANSFER rows carry `adviceposition.number`, those rows start showing
    an order number and transaction number in `transaction_detail()`. The behaviour is pinned by
    `TransactionDetailReturnOrderRefsIntegrationTest`.
  - The §5.5 change also has no obvious hook. Put-away happens later, in a generic flow, so the code would have
    to look up UL → `goodsreceiptposition` → adviceposition at put-away time. After stock merges into an
    existing bin, later moves cannot be attributed anyway.
- **Correction:**
  - List `transaction_detail()` as an affected consumer of S3 and §5.5.
  - Decide whether the new order_number on DAMAGED and TRANSFER rows is wanted.
  - Keep S3 at T1 but add "update the V2.2.25 IT". Mark §5.5 as T2 at minimum, because of the put-away hook and
    the report change.

### F7. "No 'finished at' anywhere" and S2's fix are only partially right. Dock completion does bump `modified`, and the bulk UPDATE has other callers.
- **Report location:** §5.8, S2.
- **Evidence:**
  - Confirmed: `markFinished` (`ReturnAdviceAutoReceiveService:954-958`) calls
    `AdvicepositionRepository:39` and `AdviceRepository:37` bulk JPQL, so the `@LastModifiedDate` on
    `AbstractBaseEntity:31` does not fire. PRD v2 cohort: 22/22 `created = modified`.
  - However, "no finished at anywhere" only covers the auto-receive path. A dock-finished advice is saved
    through the entity, and its `modified` *is* bumped (not measured, because no partial auto-receive exists on
    PRD). So the meaning of `advice.modified` depends on the path.
  - `updateAdviceToStateById` / `updateAdvicepositionToStateByAdviceId` are shared repository methods. Changing
    the UPDATE to stamp `modified` changes it for every caller.
- **Correction:**
  - Qualify §5.8 as "on the auto-receive path".
  - In S2, either list the callers of the two bulk queries or prefer setting `modified` explicitly in
    `markFinished` only. T1 stands.

## Low

### F8. 133 RETURN advices have no positions (2020-10-15 → 2023-07-11). The reference join's inner `JOIN adviceposition` drops them silently.
- **Location:** D1 (2822) vs D4. lane-wms §4 SQL.
- **Evidence:** PRD all-time: 2,689 RETURN advices with positions (10,173 positions) vs 2,822 total. 133 have
  zero positions, none of them in the last 180 days.
- **Correction:** use `LEFT JOIN adviceposition` in the audit query and note the historic empty advices.

### F9. The 1:1 position ↔ GRP ↔ UL shape holds only for auto-receive. The dock path can fan out and can send stock to a carrier instead of a location.
- **Location:** §5.2, §7 rows 7 and 8, §9 ("partial auto-receive").
- **Evidence:**
  - `ReceivingService.receiveGoods` loops `while (amountBottles > 0)`, creating one UL and one GRP per case
    (`:541-569`).
  - When `carrier != null`, it calls `transferUnitLoadToCarrier` instead of `transferUnitLoadToLocation`
    (`:572-576`), so the destination is a carrier UL and there is no TRANSFERRED-to-location row.
  - PRD all-time: 0 of 10,173 return positions have more than one GRP. The case is latent.
- **Correction:** in §9, say the audit query must allow N GRPs per position and a carrier destination, not just
  "mixed operators and timestamps".

### F10. The S1 fix carries timezone risk. The S1 evidence can also be strengthened.
- **Location:** S1, §5.8.
- **Evidence:**
  - `Goodsreceipt.receiptdate` is a `LocalDateTime` (`model/Goodsreceipt.java:18`) on a column that the UTC
    onboarding converted to `timestamptz` (`V1.2.01__utc_standard_tables.sql`, "goodsreceipt.receiptdate —
    business-specific LocalDateTime column").
  - On no-writer: `git grep -i receiptdate src/main` finds only the entity and the migration scripts.
  - PRD all-time: **0 of 20,346** `goodsreceipt` rows are populated, not just 0/150.
- **Correction:** cite 0/20,346. In S1, say the writer must stamp UTC consistently with the other
  `LocalDateTime` → `timestamptz` columns.

### F11. Field 10 compares OMS MySQL `timestamp` with WMS `timestamptz`, and `manage_date` is stamped before the WMS call.
- **Location:** §7 row 10, §5.8.
- **Evidence:**
  - `returns.manage_date timestamp NULL` (`tenant-baseline.sql:3438`) is session-timezone converted.
  - `manage_date = now()` is set at `:373`, before `sendReturnRestockAdvice`, inside the same transaction.
    It is NULL in the F1 divergence case.
- **Correction:** add a one-line timezone note to the cross-system join, plus the NULL case from F1.

### F12. Some completeness words lack the instrument they need.
- §5.9 / D5 says "Never a human". That is true for the 180-day population (re-run: 540 `anonymous`, 86
  `oms_integration`), but the report also says dock completions would be human. Keep the "on PRD,
  180 days" scope next to it.
- §5.7 says "Non-Restock returns create no WMS objects at all". That is true for oms-laravel-api's live path.
  It does not cover the v1-OMS history (F4), and it does not cover the F1 divergence, where a non-Restock OMS
  return *does* have a WMS advice.
- §5.1 says "one return per parcel". This is verified, and is enforced at OMS SCAN (`:106-120`) as well as by
  the DDL. Cite the code guard, not just the PK.

---

## Spot-checks that passed (code vs origin/develop)
1. `ParcelReturn` PK = `parcel_id`. `returns` DDL `PRIMARY KEY (parcel_id)` (`tenant-baseline.sql:3446`).
2. `AdviceRestController` `ADVICE_EXTERNALID_UNIQUE_INDEX = "uk_4d13b6sg589c6y88tkm98xl89"`; duplicate
   `findByExternalid` → `ENTITY_ALREADY_EXITS`.
3. `markFinished` bulk JPQL: `AdviceRepository:37` `UPDATE Advice a SET a.state = :state WHERE a.id = :id`,
   `AdvicepositionRepository:39`.
4. `ReceivingService:556` `createStockUnit(…, codeReceiving, adviceposition.getNumber(), inboundWorkStation, …)`
   and `:573` `transferUnitLoadToLocation(unitload, putaway.location(), false, codeReceiving,
   adviceposition.getNumber(), null)`.
5. `UnitloadService:192-193` `transferStockToUnitLoad(stockUnit, container, amount, WmsConstants.CODE_DAMAGED,
   null, comment, false, true)`, so the orderNumber is null.
6. `return_item` quantities are signed `tinyint` (`tenant-baseline.sql:3406-3408`). The `?? 1` fallbacks are at
   `QaReturnService:124` and `:353`.

## DB re-runs (wsl-wineco-prd, 2026-10-13)
- 180-day RETURN ULs via the FK: 626 total, **538** relabelled `-X-`, 0 dangling. Matches D7, D9, D10.
- Receiving operators: `anonymous` 540 (2026-04-17 → 2026-09-22), `oms_integration` 86 (2026-09-30 →
  2026-10-13). Matches D5.
- `unitload_record` indexes: pkey only. Matches D6.
- `goodsreceipt.receiptdate`: 0 / 20,346 all-time.
- v2 cohort only: 22 advices, 86/86 GRP, 22/22 `created = modified`, 86 TRANSFERRED rows with ordernumber.

## Side-findings tiering
- S1 T1: ok (add the timezone note, F10).
- S2 T1: ok, path-qualified (F7).
- S3 T1: ok, plus the V2.2.25 consumer change (F6).
- S4 T0: ok. Confirmed `'return_id' => $return->id`, and the table has no `id` column.
- S5 T1: ok.
- S6 T1–T2: tier ok, but the impact is understated (F1).
- S7 T3, propose only: ok.

Routing S4–S6 onto a WMS ticket makes that ticket multi-repo (F2).

## Open questions (unscored)
- How large is the F1 divergent population on the OMS DB? It needs an OMS tenant query, and no lane has OMS DB
  access.
- Does WineCo's live QA run on oms-laravel-api or still on the v1 OMS/qa-api? The ADVICE_IMPORT payloads are
  re-serialized DTOs and cannot tell the two senders apart. This decides whether the lane-oms analysis governs
  WineCo's post-cutover advices at all.
- `message_archived` on WineCo PRD is empty while `message` holds about 1.8 M rows. The 365-day cleanup that
  lane-wms describes does not appear to be running there. This is irrelevant to the verdict, but relevant if
  the raw payload is ever cited as audit evidence.

---

## Re-review (round 2) — 2026-10-13

Scope: this round reviews the revised report (§4 cohort split, §5.2–5.10, §7, §8, §9, §11) and the corrected join in
`lane-wms.md` §4. Code was read on origin/develop (same SHAs as round 1); database checks were re-run read-only on
`wsl-wineco-prd`.

**Verdict: REVISE (narrow).** Ten of the twelve round-1 findings are resolved. F3 is only partly resolved: the fix
fell into a second instance of the same trap (R2-1). F7 is only partly resolved: the revision copied a false claim
that came from **my own** round-1 text (R2-2, my error). The headline still holds: no schema change is needed.

### Round-1 findings — status

| # | Status | Note |
|---|---|---|
| F1 OMS↔WMS non-atomic | **RESOLVED** | §5.10 adds the source lines, a named OMS query and the mismatch flag. §5.7, §7 rows 6/9/10 and S6 are rescoped. One query nit is tracked as R2-6. |
| F2 conditional tier | **RESOLVED** | §8 now gives the T2/T3 conditions. Routing wording is tracked as R2-7. One stays-T3 trigger is inconsistent (R2-4). The index trigger is moot (R2-3). |
| F3 relabel trap in reference join | **PARTIAL** | The label trap is fixed (ordernumber key, stripped label). The new `recordtype = 'TRANSFERRED'` filter blanks 22% of all-time positions (R2-1). |
| F4 v1/v2 cohort | **RESOLVED** | §4, §5.2, §5.3, §5.8 and §5.9 now split the counts. §6 H1 says "v1-era data agrees", which is true only inside the 180-day window (see R2-1). |
| F5 field 2 column | **RESOLVED** | §7 row 2 names the column, plus decision 2. |
| F6 transaction_detail consumer | **RESOLVED** | §5.6 consumer-impact note, §5.5 "T2 at minimum", decision 4. |
| F7 finished-at path | **PARTIAL** | The path qualifier is right. The added sentence "A dock-finished advice is saved through the entity, so its `modified` *is* bumped" is **false** (R2-2). |
| F8 position-less advices | **RESOLVED** | `LEFT JOIN adviceposition`; §8 adds it to the IT fixture. |
| F9 dock fan-out / carrier | **RESOLVED** in prose | §5.2, §5.3, §9. The corrected SQL still assumes one UL per position (R2-5). |
| F10 receiptdate tz / 0/20,346 | **RESOLVED** | |
| F11 manage_date tz / NULL | **RESOLVED** | |
| F12 completeness words | **RESOLVED** | §5.1 adds the code guard; §5.7 and §5.9 are scoped. |

Totals: **RESOLVED 10 · PARTIAL 2 · OPEN 0**

### New findings

#### R2-1 (High). The corrected join's `recordtype = 'TRANSFERRED'` filter returns NULL destinations for 2,279 of 10,173 all-time return positions (22.4%)
- **Location:** `lane-wms.md` §4 LATERAL (`r.recordtype = 'TRANSFERRED'`); report §5.3 and §7 row 8 ("`unitload_record` TRANSFERRED joined on `ordernumber`"); §11 verification row.
- **Evidence:** the `unitload_record` shape for return receipts changed over time.
  - Roughly 2025-Q1 → 2026-Q1 (v1 era): the put-away destination was written as a **second `CREATED` row** carrying `ordernumber` and `tolocation = 'PutAwayLane'`. There is no TRANSFERRED row in that era.
    - 2025-Q1: 1,145 CREATED rows (455 with ordernumber) vs 235 TRANSFERRED.
    - 2025-Q2 → Q4: CREATED only.
  - Positions with a TRANSFERRED row, by year:
    - 2020–2024: complete.
    - 2025: 235 / 2,337.
    - 2026: 932 / 1,109.
    - The 180-day window happens to start after the shape reverted, so 626/626.
  - Spot check on `IBOL012303` (2025): the corrected join gives NULL on all 5 positions. Keying on `activitycode = 'RETURN'` instead gives `CREATED:PutAwayLane` on all 5.
  - This is the same fixture trap as F3. Both verification advices (`IBOL014975`, `IBOL015569`) are from the TRANSFERRED era.
- **Fix:**
  - Drop the recordtype filter and key on `r.ordernumber = ap.number AND r.activitycode = 'RETURN'`.
  - Measured all-time with that key: 10,173 / 10,173 positions covered, exactly 1 row each, 0 positions with more than one location. The shapes seen are `CREATED | TRANSFERRED`.
  - Add a 2025-shape row to the IT fixture and to the §11 control.
  - Correct §5.3's "TRANSFERRED" wording and §6 H1's "v1-era data agrees".

#### R2-2 (Medium). §5.8's "a dock-finished advice … its `modified` is bumped" is false. A RETURN advice has no finish path other than `markFinished`.
- **Location:** report §5.8 (second sentence) and the "finished on the dock" clause. The claim originated in my round-1 F7 text, so this is my error, not the author's.
- **Evidence:** the only writers of advice FINISHED on origin/develop are:
  - `AdviceService:318` `close()`, which is guarded by `if (!advice.getType().equals(REGULAR)) throw … "Close inbound BOL not allowed for type"` at `:314-315`.
  - `:267` / `:432`, which are TRANSFER / HUB_AND_SPOKE accept paths with their own type guards.
  - `ReturnAdviceAutoReceiveService:956-957` (`markFinished`).
  - `ReceivingService` only ever sets `OPEN` (`:224`, `:257`, `:309`).
- **Consequence:** a partially auto-received RETURN advice stays **OPEN permanently**, even after the dock receives every remaining position. Nothing finishes it, and `close()` refuses it. For field 11, "completion" must be derived from the positions (every position fully received → `max(grp.created)`), never from `advice.state`.
- **Fix:**
  - Delete the sentence.
  - State that RETURN advices reach FINISHED only via `markFinished`.
  - Add the OPEN-forever case to §9.
  - Check the SBDEV-2778 / 2236 plans for whether this is intended. If it is not, it is a sub-T3 side finding for 3736.

#### R2-3 (Medium). §5.3's performance claims are wrong in both directions, and the `unitload_record` index is unnecessary
- **Location:** §5.3 ("population-wide joins time out at 30 s; a per-advice lookup bounded by `created >= advice.created` returns instantly"); §8's T3 trigger and decision text for the index.
- **Evidence:**
  - `EXPLAIN` of the per-advice lookup with the `created` bound shows `Parallel Seq Scan on unitload_record` with `r.created >= a.created` as a hash-join **Join Filter**. There is no index on `created`, so the bound prunes nothing; the per-advice query just pays one full scan.
  - A **set-based** population join completed inside the 30 s MCP timeout:
    - 180 days: 626 / 626 filled.
    - All-time: 10,173 positions.
    - Shape: `LEFT JOIN (SELECT DISTINCT ON (ordernumber) ordernumber, tolocation FROM unitload_record WHERE ordernumber LIKE 'IBOL%' AND activitycode='RETURN' ORDER BY ordernumber, id)`.
  - What times out is the LATERAL-per-row shape, not the population.
- **Fix:**
  - Rewrite the reference SQL set-based.
  - Drop the "`created` bound makes it instant" claim.
  - Mark the index "not needed — measured". That removes one of the three T3 triggers in §8, which strengthens the T2 path.

#### R2-4 (Low). §8 lists "the §5.5 final-bin change" as a stays-T3 trigger, while §5.5 and §7 row 8 say "T2 at minimum / T2+"
None of the router's T3 shapes applies (`wms-triage/SKILL.md:61`): there is no migration and only one repo. The change does alter a customer-visible report, which is a contract change, so it is T2. Make the three places agree. Call it T3 only if a migration or authz element is found.

#### R2-5 (Low). The corrected LATERAL picks one destination per *position* (`ordernumber` only, `LIMIT 1`)
With dock fan-out (N ULs per position, F9), every UL row gets the first UL's destination. Add `AND r.label = regexp_replace(u.labelid, '-X-[0-9]+$', '')`, or add the label to the set-based join key. This is latent: 0 multi-GRP positions on PRD.

#### R2-6 (Low). The §5.10 OMS query misses `managed = 1 AND disposition IS NULL`
`r.disposition NOT IN (…)` evaluates to NULL when disposition is NULL, so those rows are excluded. A managed return can have a NULL disposition (`'disposition' => $disposition ?? $return->disposition`, `QaReturnService.php:366-372`). Use `(r.managed = 0 OR r.disposition IS NULL OR NOT EXISTS (SELECT 1 FROM return_mgmt_lut l WHERE l.return_mgmt_lut_id = r.disposition AND l.advises_wms = 1))`.

#### R2-7 (Low). The S4–S6 routing is defensible, but its citation is wrong
The report says "the policy's own tiering pushes them to a separate OMS ticket".
- Basis that supports it: `wms-triage/SKILL.md:296`. Adding OMS-repo scope to a WMS ticket is a *multi-repo addition*, which is a T3 addition, so it is "proposed, never filed".
- Text that cuts the other way: `:314`, "This carve-out [on-dev] is the only thing that turns a sub-T3 finding into a new ticket … do not invent other reasons to split".

Cite `:296` as the basis and acknowledge `:314`, so Nam sees the tension and decides. The routing itself, proposed and not filed, is compliant.

### Round-2 counts
- Round-1 findings: **RESOLVED 10 · PARTIAL 2 (F3, F7) · OPEN 0**.
- New: **High 1 (R2-1) · Medium 2 (R2-2, R2-3) · Low 4 (R2-4 … R2-7)**.
- The headline verdict (no schema change) and the conditional T2 tier stand. R2-3 makes T2 more likely by removing the index trigger.

### DB checks run this round (wsl-wineco-prd)
- `unitload_record` positions keyed on `ordernumber` + `activitycode='RETURN'`, any recordtype: 10,173 / 10,173, 0 multi, 0 multi-location.
- TRANSFERRED-only coverage by year: 2025 is 235 / 2,337; 2026 is 932 / 1,109.
- `IBOL012303`: corrected join NULL ×5; any-recordtype key `CREATED:PutAwayLane` ×5.
- `EXPLAIN` of the created-bounded per-advice lookup: Parallel Seq Scan, `created` used as a Join Filter.
- Set-based population join: 626 / 626 filled, within the timeout.
