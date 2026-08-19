---
title: "SBDEV-2890 — transaction_detail() excludes every full-move unit-load pick: Detailed Transaction Report shows only BEGINNING/ENDING rows"
ticket: "SBDEV-2890"
ticket_url: "https://app.clickup.com/t/868kp3jpr"
type: "bugfix"
severity: "high"
priority: "high"
status: "implemented"
project: ["wms2-api"]
version: "v2"
requester: "nam.park@siteboss.net"
assignee: "Nam Park"
created: "2026-08-10"
updated: "2026-08-10"
revision: 1
db_verified: false
db_verified_note: >
  NOT verified against live data. The wms2-wineco-dev DB MCP was not connected in the
  authoring session, and the reported tenant (TESTTOTAL / NYWH, UAT) is a different target
  than that MCP reaches in any case. This is acceptable for THIS defect because the root
  cause is provable from source alone: the predicate `sr.amount != 0` is deterministically
  false for every row the writer emits with `setAmount(BigDecimal.ZERO)`. No data condition
  is being guessed at. The implementer MUST still run the two queries in §11 before
  starting — query 1 sizes the defect on the reported tenant, query 2 disposes of the
  ticket's separate "~18 SKUs" complaint.
related:
  - "[[SBDEV-2895-oms-transaction-report-completeness]]"
  - "[[SBDEV-2777-stock-history-client-id-blind-mis-aggregation]]"
tags:
  - plan
  - wms2
  - reporting
  - flyway
  - picking
---

# SBDEV-2890 — `transaction_detail()` excludes every full-move unit-load pick

**Ticket:** [SBDEV-2890](https://app.clickup.com/t/868kp3jpr)
**Project:** wms2-api | **Version:** v2 | **Type:** bugfix
**Priority:** high (ticket flagged urgent)
**Status:** reviewed
**Date:** 2026-08-10

**Paired v1 plan:** `sbdocs/1-Projects/wms1/plan/SBDEV-2890-transaction-detail-ul-picks-excluded.md` — v1/wms-api carries the identical live defect. This v2 plan is gated first; the v1 gate is pending.

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep across **all** v2 migration SQL, not from memory. `grep -cE "!= *0" ` over `src/main/resources/db/migration/` returns **36** hits (18 in `V2.2.00` + 18 in `V2.2.08`), confined to those two files.

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| 1 | `V2.2.08__fix_transaction_detail_null_amounts.sql:242` | `PICKING AND (STOCK_CREATED OR STOCK_TRANSFERRED) and sr.amount != 0` — the WHERE allow-list arm | **YES — this is the defect** | **YES** |
| 2 | `V2.2.00__base_v2_schema.sql:302` | Identical predicate text in the original `CREATE FUNCTION transaction_detail` | Yes, but superseded at runtime by V2.2.08 | **No** — Flyway immutability; editing a shipped migration is forbidden |
| 3 | `V2.2.08:120,122,124,128-142,147,155,157,164,166,168` (17 hits) | `CASE WHEN tr.putaway != 0 …` — the `transaction_name` label picker in the outer query over derived table `tr` | **No** — operates on already-coalesced *output* columns; chooses a row's label, has zero row-visibility effect | No |
| 4 | `V2.2.00:180-228` (16 hits) | Same label-picker family inside the superseded function | No | No |
| 5 | `v1 V1.1.08__wms_functions.sql:210` | The same defective predicate, live in v1 production | **YES** | **Yes — in the paired v1 plan**, not this one |

### Negative results — scoped to what was actually swept

Two sweeps were run. **State their scope precisely, because neither covers the real bug class** (see the sibling defect below):

- **Sweep 1 — `!= 0` guards.** `stock_history` (`V2.2.07:29`, `V2.2.00:39`), `transaction_summary` (`V2.2.00:460`), the lock report (`V2.2.02`) and the replenishment monitor view (`V2.2.01`) contain **zero** `!= 0` occurrences. No other function carries a guard of this literal form.
- **Sweep 2 — wrong-column reads.** Every `STOCK_TRANSFERRED` occurrence correctly reads `amountstock` (`V2.2.08:193-194` PUTAWAY, `:210-211` PICKING, `:271` PACKAGING_CLUB; `V2.2.00:253,270,331,496-497,510,516-517`).

**The fix itself is one line.** But do **not** read the above as "nothing else is wrong" — both sweeps searched for the *symptom shape*, not the *bug class*.

### ⚠ The actual bug class, and a second instance of it

The real defect class is: **a value CASE that classifies an `activitycode`/`type` pair which the function's own WHERE allow-list never admits** → an unreachable arm → Detail/Summary divergence. Picking is one instance. There is at least one more:

| | Value CASE says | Allow-list admits | Summary counts it? |
|---|---|---|---|
| `received` | `STOCK_REMOVED` + `STOCK_ALTERED` → `sr.amount` (`V2.2.08:190`) | **Not admitted.** `:231-234` has `STOCK_REMOVED`+`STOCK_REMOVED` and `STOCK_ALTERED`+`STOCK_ALTERED` only; no other arm at `:235-244` admits the pair | **Yes** (`V2.2.00:490`) |

Identical shape to the picking bug. **v1 carries it too** (`V1.1.08:158` vs `:199-202`).

**Latent, not live:** `git grep "CODE_STOCK_REMOVED\|CODE_STOCK_ALTERED"` over `src/main/java` returns nothing — these appear to be dead legacy activity codes, so no current writer produces the pair. **Out of scope for this urgent fix; recommend its own ticket.** It is recorded here because the moment a writer starts emitting that pair, the same silent-omission bug appears with no test to catch it.

**AC-9 (§8.3) exists to close the class permanently** rather than playing whack-a-mole with individual instances.

### Java callers — no Java change required

The function signature and `RETURNS TABLE` column list are unchanged, so both existing projections keep working untouched.

| File:line | Role |
|---|---|
| `ClientRepository.java:63` | `@Query(nativeQuery = true)` on `transaction_detail` |
| `StockrecordRepository.java:24` | `@Query(nativeQuery = true)` on `transaction_detail` |
| `ClientRepository.java:53`, `StockrecordRepository.java:34` | `transaction_summary` siblings (untouched) |
| `TransactionReportRestController.java:84` | Comment reference only |

---

## 1. Problem Statement

OMS V2 → Reports → Transaction Report → **Detailed**, run in UAT for client **TESTTOTAL**, warehouse **NYWH**, window **2026-05-01 → 2026-08-10**, returns essentially only `BEGINNING` and `ENDING` inventory rows. Known picking activity in the window does not appear. Users cannot reconcile beginning balance → movement → ending balance, which is the report's entire purpose.

### Precise symptom statement — read this before writing any code

The ticket says transaction detail is "missing or significantly incomplete". The verified behaviour is narrower and more specific:

> **Only full-move (unit-load) picks are invisible. Partial-move picks render correctly today.**

This precision matters. A fix validated against a partial-pick fixture will appear to work while changing nothing, and a plan that claims "no picks appear" will be contradicted the moment someone finds a pick row in the report and concludes the analysis was wrong. See §2.3 for the full path table.

The reported tenant is unit-load heavy, which is why the practical effect approaches "no picking rows at all" for that data set.

### Two complaints in one ticket — only the first is a code defect

| Ticket complaint | Verdict |
|---|---|
| Transaction-detail rows missing | **Confirmed code defect.** Root cause below. Fixed by this plan. |
| Only ~18 SKUs returned | **Refuted as a code defect.** See §10.2. It is a data-population question, and no query change in any repo will surface those SKUs. |

---

## 2. Root Cause Analysis

### 2.1 The defect — a guard that binds to the wrong scope

`transaction_detail()` admits picking rows through this arm of its WHERE allow-list, at **`V2.2.08__fix_transaction_detail_null_amounts.sql:242`**:

```sql
(sr.activitycode = ''PICKING'' AND (sr.type = ''STOCK_CREATED'' OR sr.type = ''STOCK_TRANSFERRED'') and sr.amount != 0) OR
```

The `and sr.amount != 0` binds to the **whole parenthesised type group** — it gates `STOCK_CREATED` and `STOCK_TRANSFERRED` alike.

But the same function **values** those two types from **different columns**, at `V2.2.08:208-210`:

```sql
WHEN sr.activitycode = ''PICKING'' AND sr.type = ''STOCK_CREATED''     THEN sr.amount
WHEN sr.activitycode = ''PICKING'' AND sr.type = ''STOCK_TRANSFERRED'' THEN sr.amountstock
```

So the function already knows that a `STOCK_TRANSFERRED` picking row carries its quantity in `amountstock`, not `amount` — and then filters those very rows on `amount`.

### 2.2 The writer proves the guard is always false

`StockrecordService.recordTransferStockUnit` (`StockrecordService.java:265`) hard-codes `amount` to zero and puts the real picked quantity in `amountstock`:

```java
rec.setAmount(BigDecimal.ZERO);              // :272
rec.setAmountstock(stockunit.getAmount());   // :273  <- the actual picked quantity
...
rec.setType(WmsConstants.StockRecordType.STOCK_TRANSFERRED);   // :293
rec.setActivitycode(activityCode);                             // :294  <- CODE_PICKING
```

Therefore, for **every** full-move UL pick, the predicate evaluates:

```
sr.amount != 0   →   0 != 0   →   false
```

The row never enters the result set. The `THEN sr.amountstock` arm at `:210` is **unreachable dead code** — it can only be reached by a row that the WHERE clause has already rejected.

This is deterministic, not intermittent: 100% of full-move UL picks, on every tenant, for every window.

### 2.3 Every PICKING-writing path (verified — this is the enumeration that corrects the symptom statement)

Entry: `PickingorderBusinessService.java:552` `confirmPick` → `transferStockToUnitLoad(stockUnit, puUnitLoad, amountPicked, CODE_PICKING, …)` → `StockunitBusinessService.java:188`.

| # | Path | Writer | type | amount | amountstock | Visible now? | After fix |
|---|---|---|---|---|---|---|---|
| 1 | **Full move** — `StockunitBusinessService:345` (`destinationStockUnit == null`) → `:360` | `StockrecordService:265` | `STOCK_TRANSFERRED` | **0** | picked qty | **NO — the bug** | **YES** |
| 2 | Placeholder SU creation — `SUBS:336-342` → `createStockUnit` body `:148-172` | `StockunitBusinessService:148-172` | `STOCK_CREATED` | **0** | 0 | No (correct) | **No — stays suppressed** |
| 3 | **Partial move / merge** — `SUBS:369` else-branch → `:377` | `recordCreation:61` | `STOCK_CREATED` | picked qty | dest SU total | **YES — works today** | Yes (unchanged) |
| 4 | Partial move, source side — `SUBS:376` | `recordRemoval:212` | `STOCK_REMOVED` | −qty | — | No — type not in allow-list | No (unchanged) |
| 5 | Reservation release — `PickingorderBusinessService:542` | `recordChangeReservedAmount:158` | `STOCK_RESERVED_CHANGED` | 0 | SU amt | No — type not in allow-list | No (unchanged) |

**Only row 1 changes.** Rows 2–5 are deliberately unaffected, and two of them (2 and 3) are pinned by acceptance criteria so a future change cannot silently move them.

### 2.4 No double-count risk from the other `recordTransferStockUnit` caller

`StockunitBusinessService:425` (`sendToNirvana`) also calls `recordTransferStockUnit`, which could in principle emit a second `STOCK_TRANSFERRED` row for the same stock unit. It cannot produce a duplicate depletion row, for two independent reasons:

1. **Every caller passes a non-PICKING activity code** — `CODE_SEND_TO_NIRVANA`, `CODE_DELETE_FIX_ASSIGNMENT`, `CODE_MANUAL_REMOVAL`, `CODE_CYCLE_COUNT`, `CODE_FINISHED_PACKAGING_MOVE_TOTE`, `CODE_CANCELLED_ORDER_FROM_WEBSERVICE` (call sites: `FixLocationAssignmentService:267`, `GoodsReceiptPositionService:171`, `CustomerorderService:576,743`, `UnitloadService:383`, `MobileCycleCountService:229,444`, `MobileMoveUnitloadService:456`). None matches the `PICKING` arm.
2. **The stock unit is zeroed first** at `:408-409`, so `StockrecordService:266` early-returns without writing a row at all.

Additionally `PickingorderBusinessService:559` uses `CODE_PICKING_CARRIER_EMPTY`, which is not in the allow-list.

### 2.5 Corroborating divergence — Summary counts what Detailed cannot show

`transaction_summary()` (`V2.2.00:460`, **never replaced** — V2.2.07 replaced `stock_history`, V2.2.08 replaced `transaction_detail`, neither touched it) computes `depleted_picked` at `:508-513`:

```sql
coalesce(sum(                                                              -- :508
  CASE WHEN sr.activitycode = ''PICKING'' AND sr.type = ''STOCK_CREATED''     THEN sr.amount        -- :509
       WHEN sr.activitycode = ''PICKING'' AND sr.type = ''STOCK_TRANSFERRED'' THEN sr.amountstock   -- :510
  ELSE 0 END), 0) AS depleted_picked                                       -- :511-513
```

**No `amount != 0` guard anywhere in it.** The `STOCK_TRANSFERRED → amountstock` arm is **live in Summary and dead in Detailed**.

A UL pick therefore counts in the Summary report but produces no line in the Detailed report. This is exactly why the ticket's acceptance criterion *"beginning + transaction activity reconciles to ending quantity"* fails today — and it is provable in a test fixture without any UAT data. It is the basis for **AC-5**, the core acceptance criterion of this plan.

---

## 3. The Regression Chain

This defect is a **re-break of the closed ticket SBDEV-1319 ("Detailed Transaction Report — Picks from UL Not Appearing")**, inherited into v2 from v1.

| Commit | Date | Author | Effect |
|---|---|---|---|
| — | — | — | v1 `V1.0.03__wms_functions.sql:315` — predicate was `(PICKING AND sr.type = ''STOCK_CREATED'')` only. UL picks never included. **The original SBDEV-1319 bug.** |
| `f1b79c1` | 2025-04-23 | Leonardo Castro | v1 `V1.1.04__wms_functions.sql:210` — added `STOCK_TRANSFERRED` to the predicate, **no amount guard**, plus the `amountstock` value arm at `:417-418`. **This is the SBDEV-1319 fix.** |
| `4a0a26e` | 2026-04-15 | Leonardo Castro | v1 `V1.26.28__wms_functions.sql` (362 insertions) re-created `transaction_detail` **with `and sr.amount != 0` appended**. **This is the regression** — it re-broke SBDEV-1319. |
| `26cc07c` | 2026-05-05 | Nam Park | Renamed `V1.26.28` → `V1.1.08`. Consequence: plain `git log` on the file shows only the rename — **use `git log --follow`** to see this history. |
| — | — | — | v2 `V2.2.00__base_v2_schema.sql:302` inherited the **already-broken** V1.1.08 body when the v2 base schema was generated. |

### V2.2.08 is not to blame — do not attribute it there

It is tempting to pin this on `V2.2.08__fix_transaction_detail_null_amounts.sql` because that is where the line lives today. That is wrong. V2.2.08's own header enumerates exactly six changed lines — `86, 87, 192, 223, 304, 370` — and states *"no row-visibility or classification change"*. The picking predicate is not among them; V2.2.08 carried it forward verbatim from V2.2.00.

The correct framing is: **v2 inherited a v1 regression.** V2.2.08 is an innocent bystander that happens to hold the current copy of the line.

### Why the existing test suite did not catch it

`ClientRepositoryIntegrationTest:295-335` contains a nested `GetTransactionDetailSmokeTest`, added by the very commit that ported the guard. It is smoke-only — it asserts the function executes and returns a shape, not that any particular row appears. **This is the test that should have caught the bug and did not.** §8 addresses that gap directly.

> **It is also worse than smoke-only: it is `@Disabled` on `develop`** (SBDEV-2217, landlord-datasource harness issue), so it **cannot go red at all**. Confirmed during implementation — the whole `ClientRepositoryIntegrationTest` class errors with 15 context-load failures on an unresolvable `app.cron.cleanup-rest-idempotency` placeholder and an H2 reserved-word DDL error on `tenant_discovery.key`, both pre-existing and unrelated to this change. So §8.4's "must stay green" row for that class is **not** a meaningful gate today; the real coverage is the new `TransactionDetailUlPickIntegrationTest`. Do not read a green `ClientRepositoryIntegrationTest` as evidence of anything until SBDEV-2217 is fixed.

---

## 4. Architecture Overview

```
Mobile pick confirm
   │
   ▼
PickingorderBusinessService.confirmPick                      :552
   │  transferStockToUnitLoad(su, puUnitLoad, qty, CODE_PICKING, …)
   ▼
StockunitBusinessService.transferStockToUnitLoad             :188
   │
   ├── destinationStockUnit == null  ──► FULL MOVE           :345
   │        └─► recordTransferStockUnit(…)                   :360
   │               └─► StockrecordService                    :265
   │                      amount        = 0                  :272   ◄── the zero that kills it
   │                      amountstock   = picked qty         :273
   │                      type          = STOCK_TRANSFERRED  :293
   │
   └── else ─────────────────────────►  PARTIAL MOVE         :369
            ├─► recordRemoval  (STOCK_REMOVED, source)       :376
            └─► recordCreation (STOCK_CREATED, amount = qty) :377   ◄── renders fine today

                              ▼  stockrecord table
   ┌──────────────────────────────────────────────────────────────────┐
   │ transaction_detail()        V2.2.08                              │
   │   WHERE … PICKING AND (CREATED OR TRANSFERRED) AND amount != 0   │ :242  ◄── 0 != 0 → row dropped
   │   VALUE  … TRANSFERRED THEN amountstock                          │ :210  ◄── unreachable
   ├──────────────────────────────────────────────────────────────────┤
   │ transaction_summary()       V2.2.00                              │
   │   depleted_picked … TRANSFERRED THEN amountstock                 │ :510  ◄── live, no guard
   └──────────────────────────────────────────────────────────────────┘
                              ▼
   ClientRepository:63 / StockrecordRepository:24  (nativeQuery)
                              ▼
   OMS TransactionReportService  → passes transaction_type verbatim :1471
```

### Key files

| File | Lines | Role |
|---|---|---|
| `src/main/resources/db/migration/V2.2.08__fix_transaction_detail_null_amounts.sql` | `242` | **The defect.** Picking WHERE arm. |
| ″ | `208-210` | Value CASE — correct, currently unreachable for `STOCK_TRANSFERRED` |
| ″ | `230` | Windowing on `sr.modified` |
| ″ | `33-35` | Header warning: no inline comments inside the `EXECUTE` string |
| `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql` | `460`, `508-513` | Live `transaction_summary`, unguarded — basis for AC-5 |
| ″ | `541` | Windowing on `sr.created` (divergence, out of scope) |
| `src/main/java/net/aim_ai/wms/service/StockrecordService.java` | `265-303` | `recordTransferStockUnit` — writes `amount=0` / `amountstock=qty` |
| ″ | `266` | Early-return when amount ≤ 0 — proves no phantom rows |
| `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` | `336-342`, `345-360`, `369-377` | Placeholder / full-move / partial-move branches |
| `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | `542`, `552`, `559` | Pick confirm entry + reservation release |

---

## 5. Fix Design

### Fix A — scope the amount guard to the type it actually describes

**New migration: `V2.2.12__fix_transaction_detail_ul_picks.sql`.**

> **Migration number — `V2.2.12`. Do not derive this from `origin/develop` alone.**
>
> Two numbers were burned getting here. The ticket's original analysis proposed `V2.2.10` — taken on `develop` by the replenish sysprop seed. This plan then proposed `V2.2.11` — **claimed by in-flight work on SBDEV-2732**, and therefore *invisible* to a listing of `origin/develop`, where `V2.2.10` is still the highest.
>
> **"Highest version on `origin/develop`" is not the same as "next free number."** A migration sitting on an unmerged branch collides at deploy time with a Flyway checksum/ordering failure — long after this plan was reviewed and by then expensive to unpick. Before writing the file, check **all three**:
> 1. `git ls-tree origin/develop src/main/resources/db/migration/` — merged migrations
> 2. `git log --all --diff-filter=A -- 'src/main/resources/db/migration/V2.2.*'` — migrations added on **any** branch
> 3. Open SBDEV tickets at `in development` / `pr submitted` that mention a migration — the case that bit this plan, and the one neither git command catches until the branch is pushed
>
> If the number moves again, update **this plan and `resolve_one` in the verify script together** — they are matched, and a mismatch makes S1 silently unresolvable rather than loudly wrong.

**Before** (`V2.2.08:242`):

```sql
       (sr.activitycode = ''PICKING'' AND (sr.type = ''STOCK_CREATED'' OR sr.type = ''STOCK_TRANSFERRED'') and sr.amount != 0) OR
```

**After:**

```sql
       (sr.activitycode = ''PICKING'' AND ((sr.type = ''STOCK_CREATED'' AND coalesce(sr.amount, 0) != 0)
                                        OR (sr.type = ''STOCK_TRANSFERRED'' AND coalesce(sr.amountstock, 0) != 0))) OR
```

Each type is now gated on the column that actually carries its quantity — the same column the value CASE at `:208-210` already uses.

### 5.0 Column semantics — `amount` has no invariant, `amountstock` does

Before judging the alternatives, be clear about what the two columns actually mean. Full writer census of `StockrecordService` (v2 line numbers; v1 identical, offset ~6):

| Writer | `amount` set to | Kind |
|---|---|---|
| `recordCreation:61` | `amount` param (`:69`) | **delta** |
| `recordChange:112` | `amount` param (`:120`) | **delta** |
| `recordChangeReservedAmount:158` | `BigDecimal.ZERO` (`:162`) | **zero** |
| `recordRemoval:212` | `amount` param (`:216`) | **delta** |
| `recordTransferStockUnit:265` | `BigDecimal.ZERO` (`:272`) | **zero** |
| `recordRelocation:~325` | `stockunit.getAmount()` (`:332`) | **level** ⚠ |
| `recordCounting:~400` | *(not set — `amountstock` only, `:409`)* | — |

**All seven set `amountstock = stockUnit.getAmount()`.**

So: **`amountstock` has a coherent invariant — the stock unit's level after the operation. `amount` has none** — it is a delta in three writers, zero in two, and a *level* in one (`recordRelocation:332`).

Two consequences worth stating:

1. **This reframes the defect.** It is not "a SQL bug against a stable schema"; it is a report filtering on a column that carries no consistent meaning. The fix is still correct and minimal, but the underlying fragility is a schema without an invariant — which is why this bug class keeps recurring (§3, §0).
2. **`recordRelocation:332` is the genuine smell**, not `recordTransferStockUnit`. Putting a level in a delta column is the one writer that actually violates the dominant convention. It is **not** touched by this plan and no report term currently depends on it, but it is the thing to fix if anyone ever normalises this schema. **Recommend recording it against the follow-up in §10.3.**

### 5.1 Why this fix and not the alternatives

| Alternative | Why rejected |
|---|---|
| **Delete the `!= 0` guard entirely** | Reverts SBDEV-2801's intent. The guard exists to suppress the zero-amount placeholder row (path 2 in §2.3), which would otherwise render as a meaningless all-zero "Picked" line on every UL pick. Deleting it trades one wrong report for another. |
| **Change the writer to put the quantity in `amount`** | **The writer is not wrong** — see §5.0. `amount = 0` on a full move is semantically *correct* under the delta convention: a full move does not change the stock unit's quantity, only which unitload holds it. Changing it would touch a hot write path (picking, cycle count, nirvana, move-unitload), change the meaning of a persisted column, and invalidate every historical row. |
| **Fix the placeholder writer instead (see §10.3)** | Correct in the long run, but it does not repair the millions of already-written rows, so the report stays wrong for all historical windows. Also a genuinely riskier change. Recorded as a follow-up. |
| **Filter in Java after the query** | Pushes report semantics out of the function that owns them, duplicates the classification logic already in the CASE, and leaves `transaction_summary` inconsistent. |

### 5.2 Properties of this fix — each verified, each worth stating

1. **The placeholder row stays suppressed.** Path 2 writes `STOCK_CREATED` with `amount = 0`; it fails the first arm (`0 != 0`). Its `amountstock` is also 0, so it would fail the second arm too even if the arms were swapped. **SBDEV-2801's phantom-row intent is fully preserved** — this is AC-2.
2. **`coalesce` is a proven no-op here, not a semantic change.** Under three-valued logic `NULL != 0` yields `NULL`, which `WHERE` treats as not-true → row excluded. `coalesce(NULL, 0) != 0` yields `false` → row excluded. **Identical outcomes.** It is retained only for consistency with V2.2.08's NULL-hardening style. This must be stated in the migration header so a future reader does not misread it as a behaviour change.
3. **No phantom rows are possible.** `StockrecordService:266` early-returns when the stock unit amount is ≤ 0, so **every** persisted `STOCK_TRANSFERRED` picking row has `amountstock > 0`. The new arm therefore cannot admit a zero-quantity row.
4. **`CREATE OR REPLACE`, no `DROP`.** The signature and `RETURNS TABLE` column list are unchanged, so the function's OID, ownership and ACLs are preserved and there is no window in which the function does not exist for concurrent callers. This is the established pattern, stated in both precedents: `V2.2.07:12` and `V2.2.08:24-25` (*"…same pattern as V2.2.07. Idempotent."*).

5. **One row shape changes visibility in the *other* direction — and that is an improvement, not a regression.** The change is not purely additive, and this is the only case where it isn't:

   | `PICKING` / `STOCK_TRANSFERRED` row | Old predicate | New predicate |
   |---|---|---|
   | `amount = 0`, `amountstock > 0` (**the normal UL pick**) | excluded — **the bug** | **admitted** |
   | `amount ≠ 0`, `amountstock = 0` | admitted | **excluded** |
   | `amount ≠ 0`, `amountstock ≠ 0` | admitted | admitted (unchanged) |

   The second row is the one to reason about. The current writer cannot produce it — `recordTransferStockUnit` always sets `amountstock = stockUnit.getAmount()` and `StockrecordService` early-returns when that is ≤ 0 — so it can only exist as legacy or v1-carried data. And if it does exist, the value CASE reads `amountstock` for `STOCK_TRANSFERRED` (`V2.2.08:210`), so it previously rendered as an **all-zero "Picked" line** — precisely the phantom row the original guard was written to suppress. Excluding it is therefore consistent with SBDEV-2801's intent, not a loss of data.

   **Parenthesisation verified:** the new arm is 6-open/6-close balanced and still terminates `) OR`, preserving its position in the surrounding allow-list OR-chain. Negative amounts behave exactly as before (`!= 0` admitted them then and now).

### 5.3 Two mechanical hazards — these are how this fix gets shipped broken

**Hazard 1 — copying the wrong ancestor body.** `V2.2.12` must be derived by copying the **`V2.2.08`** function body and changing one line. Copying from `V2.2.00` instead would silently revert SBDEV-2801's six NULL-coalesces (V2.2.08 lines `86, 87, 192, 223, 304, 370`) and **reintroduce a production HTTP 500** on any window containing a NULL-amount row. This is the single highest-risk step in the plan; §7 Step 3 mandates a diff proving exactly one changed hunk.

**Hazard 2 — annotating the changed line.** Line 242 sits **inside the single-quoted `EXECUTE` string** opened at `V2.2.08:38`. V2.2.08's header warns about this verbatim at `:33-35`:

> `-- Those lines sit INSIDE the single-quoted EXECUTE string, so do NOT annotate them with`
> `-- inline markers: a comment would be stored in the function body and change`
> `-- pg_get_functiondef output.`

An inline `--` marker would become part of the stored function body and change `pg_get_functiondef` output, breaking any recurrence gate that diffs it. **The changed line carries no inline comment.** Describe the change in the file header with line references instead, exactly as `V2.2.08:26-32` does.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `src/main/resources/db/migration/V2.2.12__fix_transaction_detail_ul_picks.sql` | **New** | `CREATE OR REPLACE FUNCTION public.transaction_detail(...)` — V2.2.08 body with the picking WHERE arm rescoped per type. Header documents the one changed line, the coalesce no-op, and the ancestor it was copied from. |
| `src/test/java/net/aim_ai/wms/integration/TransactionDetailUlPickIntegrationTest.java` | **New** | Testcontainers + Flyway regression test covering **AC-1 … AC-6, AC-8**. **Name must end `IntegrationTest`** — see §8.1. Every test carries `SBDEV-2890` + its AC id (§8.3). |
| `src/test/java/net/aim_ai/wms/integration/TransactionDetailAllowListStructuralIntegrationTest.java` | **New** | **AC-9** — parses `pg_get_functiondef` from the Testcontainers DB and asserts allow-list ⊖ value-CASE is empty modulo the accepted-exclusion set. Separate file because it is a whole-function structural property, not a row-level fixture. |
| `src/test/java/net/aim_ai/wms/unit/service/StockunitBusinessServiceFullMoveInvariantUnitTest.java` | **New** | **AC-10** — the full-move branch is entered only when `amount == sourceStockunit.getAmount()`. Plain unit test (Mockito), no container. |
| `sbdocs/9-System/scripts/verify-SBDEV-2890-transaction-detail-ul-picks-excluded.sh` | **New** | Machine-checkable acceptance. |
| `sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md` | Edit | Add rows for `transaction_detail` / `transaction_summary` (§10.5). |
| `sbdocs/3-Resources/design/wms2-stockunit-design.md` | Edit | Record the `amount = 0` / `amountstock = qty` convention at `:283`; full-move vs partial-move split at `:441` (§10.5). |

**No Java production code changes.** Signature unchanged → both `nativeQuery` projections unaffected.

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Prerequisite | Status | Notes |
|---|---|---|
| **DB state** | Required before starting | Run both §11 queries. Query 1 sizes the defect on the reported tenant; query 2 disposes of the "~18 SKUs" complaint. `db_verified: false` on this plan — see frontmatter. |
| **Branch base** | **Blocking** | Both local checkouts are **stale**: v2 local is on `bugfix/SBDEV-2729-system-sku-receiving-null-label-token`; v1 local `develop` is behind by 2 migrations. `git fetch origin` and branch from `origin/develop` — do **not** branch from the local checkout. |
| **Branch name** | Corrected during implementation | `bugfix/SBDEV-2890-transaction-detail-ul-picks` off `origin/develop`. This plan originally said `feature/…`; the repo's observable convention for bug fixes is `bugfix/…` (`bugfix/SBDEV-2821`, `bugfix/SBDEV-2863`, `bugfix/SBDEV-2731` on develop). Do not "correct" it back. Commit convention is likewise `type(scope): description [SBDEV-####]`. |
| **Migration number** | **Re-confirm at implementation — 3-way check** | `V2.2.12`. `V2.2.11` was lost to in-flight SBDEV-2732 work that is invisible on `origin/develop`. Run all three checks in §5 Fix A before writing the file; a merged-only check is not sufficient. |
| **Feature flags / sysprops** | N/A | None. The fix is unconditional. |
| **Config / env changes** | N/A | None. |
| **Data migration / backfill** | N/A | `CREATE OR REPLACE` only; no data is rewritten. Historical rows become visible retroactively because the function is evaluated at query time. |
| **Deploy-order dependency** | Yes | Migration must reach **every tenant DB**. Tenants at differing migration levels will report differently until all are migrated — see §9. |
| **External systems** | None | OMS requires no change; it passes rows through verbatim (§10.1). |
| **Access** | Testcontainers-capable Docker; tenant DB read access for §11 | |
| **Monitoring** | None added | See §12 row 8 for rationale. |

### 7.2 Steps

1. **Capture the FAIL baseline.** `bash sbdocs/9-System/scripts/verify-SBDEV-2890-transaction-detail-ul-picks-excluded.sh`. It **must** report failures now. A script that passes before the fix is a broken script — fix the script, not the code.
2. **Run the §11 queries** and paste the results into §11. If query 1 returns zero for TESTTOTAL, stop and reconcile before proceeding — the defect is still real (it is provable from source), but the reported tenant would not be demonstrating it, which changes the manual verification story.
3. **Create `V2.2.12__fix_transaction_detail_ul_picks.sql`** by copying the **V2.2.08** file verbatim, then changing **only** line 242 to the Fix A "After" form, and rewriting the header to describe this change. Then prove it:
   ```bash
   diff <(sed -n '/^CREATE OR REPLACE/,$p' V2.2.08__fix_transaction_detail_null_amounts.sql) \
        <(sed -n '/^CREATE OR REPLACE/,$p' V2.2.12__fix_transaction_detail_ul_picks.sql)
   ```
   **Exactly one hunk may differ.** Any other difference means the wrong ancestor was copied (Hazard 1) — start over.
4. **Confirm no inline comment** was added inside the `EXECUTE` string (Hazard 2). The header carries the explanation; the body stays byte-clean apart from the one predicate.
5. **Write `TransactionDetailUlPickIntegrationTest.java`** per §8. Confirm it is **RED** on AC-1 and AC-5 before the migration is applied, and that AC-2/AC-3 are already green (they guard existing correct behaviour).
6. **Run the fix.** `mvn verify -Dit.test=TransactionDetailUlPickIntegrationTest` → green.
7. **Run the regression set:** `TransactionDetailNullAmountIntegrationTest` (SBDEV-2801), `StockHistoryClientIsolationIntegrationTest` (SBDEV-2777), `ClientRepositoryIntegrationTest`, `StartupFlywayMigratorIntegrationTest`, `TransactionReportRestControllerUnitTest`. Then full `mvn verify`.
8. **Re-run the verify script** → `Result: N pass, 0 fail, 0 skip`. Paste that exact line in the completion report.
9. **Manual verification** per §8.4 against UAT.
10. **Update §13 Implementation Status** with commit SHAs, test names, suite results, and the verify-script line.

---

## 8. Testing Plan

### 8.1 ⚠ The test-naming trap — read before creating any file

**The two repos use opposite conventions, and each `<includes>` block *overrides* the Failsafe default rather than appending to it, so there is zero overlap.**

| | v1/wms-api | v2/wms2-api *(this plan)* |
|---|---|---|
| Surefire **excludes** | `pom.xml:541` `**/*IT.java` | `pom.xml:450-451` `**/*IntegrationTest.java`, `**/*E2ETest.java` |
| Failsafe **includes** | `pom.xml:644` `**/*IT.java` | `pom.xml:567-568` `**/*IntegrationTest.java`, `**/*E2ETest.java` |
| Surefire **includes** | *(none declared — Maven defaults apply)* | *(none declared — Maven defaults apply)* |
| Test **must** be named | `…IT.java` | **`…IntegrationTest.java`** |
| A `…IT.java` file | runs (Failsafe) | **never runs** — matches neither Surefire's defaults nor Failsafe's includes |
| A `…IntegrationTest.java` file | **runs under Surefire, in the wrong phase** | runs (Failsafe) |

v2's `pom.xml:565` even comments *"(default pattern is `*IT.java`)"* while omitting that pattern from the includes.

**The two directions fail differently — this is not symmetric, and the difference matters:**

- **In v2 (this plan):** naming the test `TransactionDetailUlPickIT.java` produces a file that **genuinely never executes**. Silent no-op; a green build proves nothing. This is the real trap here.
- **In v1:** naming it `…IntegrationTest.java` does **not** silently vanish. v1's Surefire declares only `<excludes>**/*IT.java</excludes>` and **no `<includes>`**, so Maven's defaults (`**/*Test.java`) still match it — the test **runs under Surefire**, outside Failsafe's pre/post-integration-test lifecycle, and will most likely error on container lifecycle rather than pass. Noisy failure, not silence.

Either way the naming rule stands: **`…IntegrationTest.java` in v2, `…IT.java` in v1.** **Both repos require `mvn verify`, not `mvn test`** — and in v2, `mvn test -Dtest=…` would run nothing and report success, which is why §15's script uses `-Dit.test`.

### 8.2 Harness — copy `TransactionDetailNullAmountIntegrationTest`, do not "simplify" it

`src/test/java/net/aim_ai/wms/integration/TransactionDetailNullAmountIntegrationTest.java` (SBDEV-2801) is the model:

- **Not `@SpringBootTest`** — bare class declaration at `:49`, only `@DisplayName` at `:48`.
- **Not `AppPostgresDBSetupExtension`.** Its Javadoc at `:37-42` explains why, verbatim: *"Harness choice is load-bearing — do not 'simplify' it. Deliberately NOT @SpringBootTest and NOT built on AppPostgresDBSetupExtension: that harness scans only `classpath:db/v1-to-v2-onboarding/schema` and can never see `db/migration`, where this fix lives."*
- Raw Testcontainers `PostgreSQLContainer<>("postgres:16")` at `:75-77` (matching production), `@BeforeAll` `:83`, `Flyway.configure()` `:91`, `.locations("classpath:db/migration")` `:93`, plain JDBC fixtures, AssertJ assertions.

**Fixture requirement — `created == modified`.** `transaction_detail` windows on `sr.modified` (`V2.2.08:230`) while `transaction_summary` windows on `sr.created` (`V2.2.00:541`). Seed rows with the two equal, or **AC-5 will be flaky and can false-fail** on a correct fix. See §10.4.

### 8.3 Integration tests — `TransactionDetailUlPickIntegrationTest`

Fixture: one client, one SKU, all rows `created == modified` inside the window.

| AC | Seeded row | Assertion | Before fix | After fix |
|---|---|---|---|---|
| **AC-1** | `PICKING` / `STOCK_TRANSFERRED`, `amount=0`, `amountstock=12` | Row returned; `depleted_picked = 12`; `transaction_name = 'Picked'` | **RED** (zero rows) | GREEN |
| **AC-2** | `PICKING` / `STOCK_CREATED`, `amount=0`, `amountstock=0` | **No** row returned | GREEN | GREEN — guards the phantom-row regression |
| **AC-3** | `PICKING` / `STOCK_CREATED`, `amount=5`, `amountstock=20` | Row returned; `depleted_picked = 5` | GREEN | GREEN — the partial-move path |
| **AC-4** | `PICKING` / `STOCK_TRANSFERRED`, `amount=NULL`, `amountstock=NULL` | No row; and no numeric output column of any returned row is NULL | GREEN | GREEN — preserves SBDEV-2801 |
| **AC-5** | Mixed fixture incl. a UL pick, all rows `created == modified` | **`depleted_picked` term only:** `SUM(transaction_detail.depleted_picked) == transaction_summary.depleted_picked` for the same client + window | **RED** (detail undercounts by every UL pick) | GREEN |
| **AC-8** | Mixed non-picking fixture | `STOCK_RELOCATED` still excluded; PUTAWAY (→ `transfer`) and DAMAGED totals unchanged. **REPLENISHMENT / PACKAGING_CLUB: see note** | GREEN | GREEN |

> **AC-8 coverage is partly by proof rather than by fixture — stated so nobody assumes otherwise.** `PUTAWAY` (via the `transfer` output column) and `DAMAGED` are seeded and asserted. The other two are not, for structural reasons rather than oversight:
> - **REPLENISHMENT** is classified in the inner derived table but **not projected as an output column** of `RETURNS TABLE`, so there is nothing to assert a value against. (Same reason the first draft of this test failed querying a `putaway` column that does not exist in the output — PUTAWAY surfaces as `transfer`.)
> - **PACKAGING_CLUB** is handled by a **separate UNION branch** (`V2.2.08:283`) with its own WHERE and its own columns; the main branch hardcodes `depleted_club` to 0. The fix does not touch that branch.
>
> For both, coverage rests on the **one-hunk diff** against V2.2.08 — which proves those arms byte-unchanged, and is stronger evidence than a fixture could give. Recorded rather than silently dropped.
| **AC-9** | *(structural — no fixture)* | **Every `activitycode`/`type` pair appearing in any value CASE is admitted by the WHERE allow-list.** Parse both, assert the set difference is empty | **GREEN** — see correction below | GREEN — regression guard, not a gate |
| **AC-10** | *(Java-level)* | The full-move branch is taken **only** when `amount == sourceStockunit.getAmount()` | GREEN | GREEN — pins the invariant AC-1 silently depends on |

> **Test-annotation convention — required, and the verify script enforces it.** Every test encoding a criterion above must carry **both** the string `SBDEV-2890` **and** its AC id (`AC-1` … `AC-10`) in a `@DisplayName` or comment. AC ids are only unique *within* a ticket — `AC-9`/`AC-10` already appear in 11 unrelated test files in this repo (the schedulejob metrics suites number their criteria the same way), so a bare AC id is not a usable anchor. §15's script therefore searches only files that name `SBDEV-2890`. A test that omits the ticket string will not be seen, and its criterion will report FAIL.

#### AC-5 — scope it precisely, and do not generalise it

AC-5 is the strongest criterion in this plan **and the easiest to over-read.** It is scoped to **`depleted_picked` only**, and that scoping is deliberate:

- The two functions use **fundamentally different row-admission models**. `transaction_summary` has **no activitycode WHERE clause at all** — it is `LEFT JOIN stockrecord … AND sr.created BETWEEN $2 AND $3` (`V2.2.00:539-541`) with only `WHERE cl_nr = $1` (`:546`), and does all selection inside `CASE … ELSE 0` arms (admit-all-then-classify). `transaction_detail` uses an explicit allow-list (`V2.2.08:231-244`) (allow-list-then-classify).
- **The picking term still reconciles** because after the fix both sides value from the same columns (`V2.2.08:208-210` vs `V2.2.00:509-510`), and rows summary admits but detail excludes contribute exactly 0 to summary's sum (a zero value, or NULL, which `sum()` skips).
- **Other terms are not comparable by construction.** `depleted_club` / `shipped`: detail handles `PACKAGING_CLUB` in a separate UNION branch (`:283`) and hardcodes both to 0 in the main branch (`:162,:163`), while summary sources `shipped` from `billoflading_position` (`:535-537`) plus a `customerorder_position` UNION (`:580-583`) — different sources entirely. Detail has `packaging_qa` (`:215`) and `replenishment` (`:218`) columns that summary lacks; summary has `putaway` / `beginning_inventory` / `ending_inventory` that detail lacks.

**Do not widen AC-5 into a general "the two reports reconcile" assertion.** That property is false by construction, and someone will otherwise burn days discovering the two reports were never designed to agree. The terms that *were* checked and are clean: `adjustments` (`:196-200` vs `:236-240` vs `:499-502`), `damaged` (`:203`/`:241`/`:505`), `returned` (`:221`/`:232`/`:493`), `transfer`/`putaway` (`:193`/`:235`/`:496`).

**Production caveat:** even scoped to picking, AC-5 passes in CI under the `created == modified` fixture while production reconciliation can still diverge — see §10.4.

No reconciliation assertion of any kind exists in either repo today: `grep -rn "transaction_summary" src/test/java/ | grep -i detail` returns one hit, `ClientRepositoryIntegrationTest.java:324`, and it is a *comment*.

#### AC-9 — close the bug class, not just this instance

The picking bug and the `received` bug (§0) share one shape: a value CASE classifying a pair the allow-list never admits. AC-9 asserts the set difference directly, so any future arm added to one without the other fails immediately. It is the single assertion that would have caught **both** defects.

**Specification — implement exactly this.** "Parse both and assert the set difference is empty" is ambiguous enough to yield two different tests, only one of which is RED pre-fix. So the four open decisions are settled here:

1. **Source of truth: `pg_get_functiondef('public.transaction_detail'::regproc)`, queried from the Testcontainers database after Flyway runs.** Not the `.sql` file. The deployed function is what actually runs, and reading it from the DB sidesteps the `''`-escaping differences between the migration text and the stored body.
2. **Which text to parse:** the single-quoted `EXECUTE` string. Within it, treat as a **value CASE** any `CASE`/`WHEN` arm whose predicate references `sr.activitycode`, and as the **allow-list** the `WHERE` clause of the main (non-`UNION`) branch. **Explicitly excluded:** the `transaction_name` label picker (`V2.2.08:120-168`), whose arms test `tr.<column> != 0` on the derived table and never reference `sr.activitycode` — that rule is what keeps the 17 label-picker arms out, and it falls out of the `sr.activitycode` test rather than needing a hand-maintained list.
3. **Scope to the main branch only.** The `PACKAGING_CLUB` UNION branch (`:283`) and the `BEGINNING`/`ENDING` branches each carry their own WHERE and their own columns; comparing across them is meaningless. Assert per-branch, and for this AC only the main branch is in scope.
4. **Wildcard rule.** An allow-list arm with **no type qualifier** admits *all* types for that activitycode. Verified instances: `V2.2.08:231` `(sr.activitycode = ''RECEIVING'')` and `:243` `sr.activitycode = ''PACKAGING''`. Without this rule every `RECEIVING` pair reads as unadmitted and the test is noise — and `RECEIVING`/`RETURN` are exactly the arms the sibling defect turns on.

**Accepted exclusions** — a literal set in the test, each entry requiring a comment and a plan reference. Currently exactly one:

```java
// SBDEV-2890 AC-9 — accepted exclusions. Adding an entry REQUIRES a plan reference.
Set.of(Pair.of("STOCK_REMOVED", "STOCK_ALTERED"))  // `received` CASE V2.2.08:190; latent, no live writer emits this pair (plan §0)
```

Anything outside that set fails. An accepted exclusion must be a conscious, reviewed entry — never a silent pass.

**⚠ Correction — AC-9 is a regression guard, not a red-then-green gate.** An earlier revision of this plan claimed AC-9 would be RED pre-fix because "the picking pair is unadmitted". **That is wrong, and the TDD gate proved it: AC-9 passes on the unfixed build.** The picking pair is *syntactically present* in the pre-fix allow-list (`V2.2.08:242` names both `STOCK_CREATED` and `STOCK_TRANSFERRED`); the defect is that `and sr.amount != 0` makes the `STOCK_TRANSFERRED` arm **unreachable at runtime**, which no static set-difference can detect. Runtime reachability is what AC-1 and AC-5 prove.

AC-9 therefore belongs with AC-2 / AC-3 / AC-8: **green before and after**, valuable because it fails the moment someone adds an arm to one side without the other. Keep it — just do not count it as evidence the fix works.

**Expected states:** GREEN pre-fix and post-fix, with `received`'s `STOCK_REMOVED`+`STOCK_ALTERED` covered by the exclusion set.

#### AC-10 — pin the invariant AC-1 depends on

AC-1 asserts `depleted_picked = 12` for a UL pick. That is only correct because `amountstock` equals the **picked** quantity — which holds only because `StockunitBusinessService:336` diverts to placeholder-creation whenever `sourceStockunit.getAmount().compareTo(amount) > 0 || fixLocationAssignment != null`, leaving the full-move branch at `:345` to fire **only** when `amount == sourceStockunit.getAmount()`.

Neither the SQL nor any AC-1…AC-10 fixture encodes that coupling — all of them seed rows via raw JDBC. **If anyone relaxes `:336`, `transaction_detail` silently over-reports picked quantity and every test stays green.** AC-10 makes the write-path invariant explicit in both repos.

### 8.4 Regression tests

| AC | Test | Assertion |
|---|---|---|
| **AC-6** | `TransactionDetailNullAmountIntegrationTest` | All existing assertions still pass — proves V2.2.12 did not revert SBDEV-2801 (Hazard 1) |
| **AC-7** | `StartupFlywayMigratorIntegrationTest:137,145` | Already asserts `pg_proc` contains `transaction_detail` on fresh **and** legacy DBs — **exercises V2.2.12 for free**. Additionally assert exactly one `transaction_detail` in `pg_proc` and a signature byte-identical to V2.2.08's (catches an accidental overload). |
| — | `StockHistoryClientIsolationIntegrationTest:494,535,552` | V2.2.07 untouched |
| — | `ClientRepositoryIntegrationTest:295-335` | The smoke test that missed this bug; must stay green |
| — | `TransactionReportRestControllerUnitTest:445,942` | Mapper-only; unaffected |

### 8.5 Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| 1 | **The exact UAT repro** | UAT | OMS V2 → Reports → Transaction Report → TESTTOTAL / NYWH → `2026-05-01`–`2026-08-10` → Detailed → Generate | UL picking rows now appear between BEGINNING and ENDING; each shows `Picked` with a non-zero quantity | |
| 2 | **Reconciliation spot-check** | UAT | Pick one SKU with known UL picks; sum beginning + all movement rows | Equals the ENDING quantity for that SKU | |
| 3 | **Detail ↔ Summary agreement** | UAT | Run Summary and Detailed for the same client + window | `depleted_picked` totals now agree (they do not today) | |
| 4 | **Partial-pick unchanged** | UAT | Find a SKU picked partially (not a full UL move); compare rows before/after | Identical — no duplicate and no changed quantity | |
| 5 | **No phantom zero rows** | UAT | Scan the Detailed output for `Picked` rows with quantity 0 | None present | |
| 6 | **SQL before/after on a snapshot** | Restored UAT snapshot | Run `transaction_detail(...)` and `transaction_summary(...)` for the same client+window pre- and post-migration | `sum(depleted_picked)` matches **after** and did **not** match before | |
| 7 | **NULL-amount window** | UAT / snapshot | Report over a window containing a NULL-amount row | HTTP 200, zeros rendered — no 500 (SBDEV-2801 intact) | |
| 8 | **Begin/end already account for the pick** (§10.8 residual 1) | UAT / snapshot | For an affected SKU, compare `ending_inventory − beginning_inventory` against the pick quantity | Difference already reflects the pick, independent of `net_change`. **If it does not, stop — a second WMS-side `net_change`-formula fix is needed and that is a scope change** | |
| 9 | **Read the `Depleted Picked` column specifically** (§10.8) | UAT | On a newly-visible UL pick row, read the `Depleted Picked` column — **not** `Net Change` | Non-zero, equals the picked quantity. `Net Change` is legitimately 0 on a pick row — do not report that as a bug | |
| 10 | **Confirm the reporting surface** (§10.8 residual 2) | UAT | Establish which UI produced the ticket's screenshot — `omsv2-UI` has no wired Detailed Transaction Report component today | The repro is re-run on whatever surface the reporter actually used (legacy UI, direct API, or CSV/PDF export) | |
| 11 | **⚠ POST-DEPLOY, MANDATORY — every tenant actually received V2.2.12** (§9) | Each tenant DB, after deploy | `SELECT max(version) FROM flyway_schema_history;` per tenant. Also check boot logs for `42501 must be owner of` | Every tenant reports **≥ V2.2.12**. A tenant stuck below it did **not** get the fix and the boot did not fail — repair ownership with `db/reassign-tenant-ownership.sh`, then re-boot. **Without this check a stalled tenant looks identical to a fixed one** | |
| 12 | **Result-set growth sanity** (§9) | Each tenant DB, before merge | `SELECT count(*) FROM stockrecord WHERE activitycode='PICKING' AND type='STOCK_TRANSFERRED' AND modified > now() - interval '30 days';` | Compare against currently-visible row counts. These rows were **100% absent**, so the report grows by exactly this population. The endpoint has no pagination (`TransactionReportRestController:201`, `StockrecordRepository:24` returns a bare `List`), so a large figure on a UL-heavy tenant is the one risk no test covers | |

### 8.6 Unit tests

**One, for AC-10.** The *fix* is entirely in-database, so no unit test covers the SQL change itself — coverage for that is integration-level by necessity, since PL/pgSQL `RETURN QUERY EXECUTE` cannot run on H2 (§12 row 6).

But AC-10 is a **Java** invariant, not a SQL one, and it needs a Java home:

- `StockunitBusinessServiceFullMoveInvariantUnitTest` — assert the full-move branch (`:345`) is entered only when `amount == sourceStockunit.getAmount()`, i.e. that `:336`'s divert condition (`compareTo(amount) > 0 || fixLocationAssignment != null`) still routes every partial move away from it.
- Plain Mockito unit test; no container needed. **v2 has no `mockStatic` restriction, but the v1 port does — v1 is on Mockito 3.3.3** (v1 `CLAUDE.md`), so the v1 version must drive the branch through real objects rather than static mocking. Feasible here because the condition reads only from the passed `Stockunit` and the `fixLocationAssignment` lookup.

This is the only Java test in the plan. Everything else is integration-level.

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **V2.2.12 copied from V2.2.00 instead of V2.2.08** | Silently reverts SBDEV-2801 → production HTTP 500 on NULL-amount windows | §7.2 Step 3 mandates a one-hunk diff; AC-6 re-runs the SBDEV-2801 suite; verify script asserts the six coalesces survive |
| **Inline comment added inside the `EXECUTE` string** | Changes `pg_get_functiondef` output, breaks recurrence gates that diff it | §5.3 Hazard 2; verify script asserts no `--` on the changed predicate line |
| **Test named `…IT.java` in v2** | Test never executes; green build proves nothing | §8.1 table; verify script asserts the filename suffix and that Failsafe picked it up |
| **Migration number collision** | Flyway checksum/ordering failure at startup, surfacing at deploy rather than review | **Already happened twice on this plan** (`V2.2.10` merged, `V2.2.11` in-flight on SBDEV-2732). `V2.2.12` free at authoring. Mitigation is the 3-way check in §5 Fix A — merged + any-branch + open tickets — not just `ls` of `origin/develop` |
| **Partial tenant rollout** | Tenants report differently until all are migrated | Deploy-order prerequisite (§7.1); communicate to support before release |
| **⚠ A tenant whose `public` objects are owned by another role silently never receives this fix** | `CREATE OR REPLACE FUNCTION` raises `42501 must be owner of…`, Flyway stops at the first failure, and **tenant migration failures do not abort the boot** — so that tenant freezes at its current version, keeps the bug, and the team believes the fix shipped | **This is not hypothetical: `wh01_hydra_v2` stalled at `V2.2.06` on prd for exactly this reason when `V2.2.07` replaced `stock_history`, and CLAUDE.md warns `V2.2.08` "replaces `transaction_detail` and would fail next otherwise". V2.2.12 replaces the same function and inherits the exposure.** Never fix by editing the migration (it has already applied elsewhere — `flyway validate` would break). Repair ownership once with `db/reassign-tenant-ownership.sh` as superuser, then it applies on the next boot. **Post-deploy check is mandatory — see §8.5 scenario 11** |
| **Report returns more rows than before** | Larger result sets, longer render for UL-heavy tenants | Expected and correct — the report was *under*-returning. Not a regression. Spot-check render time on the largest tenant |
| **AC-5 false-fails on `created != modified` rows** | Wasted debugging, or worse, a "fix" to the wrong thing | §8.2 mandates `created == modified` in the fixture; divergence documented in §10.4 |
| **Someone "fixes" the ~18-SKU complaint in query code** | Wasted effort chasing a non-defect; risk of breaking a correct query | §10.2 refutes it with file-level evidence and gives the disposing query |
| **Smoke-only coverage recurs** | The same bug class returns unnoticed a third time | AC-5 is a true reconciliation assertion, not a smoke test — the first of its kind in either repo |

---

## 10. Open Questions / Resolved Decisions

### 10.1 Resolved — OMS is not implicated; its defects are split to SBDEV-2895

OMS was **affirmatively cleared** as a cause, verified in `v2/oms-laravel-api` on `develop`:

- `TransactionReportService.php:1471` — the Transaction column is the WMS `transaction_type` passed through **verbatim**.
- `:2461-2507` — the only content filter is the archived-SKU filter, opt-in via `include_archived_skus`, defaulting to include (a no-op by default).
- `:2532-2569` — the main loop's only early exits are memory/record limits. **No filtering by activity code, transaction type, quantity or status anywhere.**
- `:2569-2621` — every surviving row is persisted.

The rows were already absent when OMS received them.

Four **independent** OMS completeness defects were found during that verification and split into **[SBDEV-2895](https://app.clickup.com/t/868kp5grd)**: export truncation at 10k rows reported as the total; Mongo batch-insert failures swallowed while the report reports `COMPLETED`; six aggregation helpers reading a singular collection name while writes go to the plural one (already documented at `docs/reporting.md:94`); and a legitimately-empty result recorded as `FAILED`, which then auto-regenerates on every view. **None caused this ticket's symptom.**

> **Nuance worth carrying:** SBDEV-2895's swallowed-insert defect means OMS *can* still lose rows — by a different mechanism than the one this plan fixes. If rows are still missing after V2.2.12 ships, check SBDEV-2895 before reopening this ticket.

### 10.2 Resolved — the "~18 SKUs" complaint is **refuted**, not deferred

The ticket hypothesises the report "only starts from current `stock_view` rows / SKUs with non-zero current inventory". **It does not.**

- `stock_view` is `FROM itemdata i LEFT JOIN stockunit su` (`V2.2.00:4685`) — **itemdata-anchored**, one row per SKU regardless of stock. Zero-stock SKUs are **already** included.
- `transaction_summary()` likewise drives from `client ⋈ itemdata` (`:522-545`).

Therefore **~18 SKUs = the number of `itemdata` rows TESTTOTAL has in that WMS database.** SKUs "known to exist" but missing are missing from `itemdata` for that `client_id` — a product-sync / onboarding data question. **No query change in either repo will surface them.** Query 2 in §11 disposes of this in one line.

Stated plainly here so that nobody spends a day chasing a phantom query bug, or worse, "fixes" a correct query.

### 10.3 Deferred — latent defect in `createStockUnit`, deliberately not fixed here

`StockunitBusinessService.createStockUnit`'s `recordZeroAmount` parameter (`:129`) is **never read**. The precise mechanism matters, because it points at a different fix than "add a flag check":

- `createStockUnit:129` accepts the flag; `:131-132` validates only negative amounts; `:134` delegates to `createStockUnitCore` **without passing the flag on**.
- `createStockUnitCore:148-172` **hand-rolls a `Stockrecord` inline** and saves unconditionally at `:172`.
- Meanwhile `StockrecordService.recordCreation:61-64` has a **real** guard: `if (!allowZeroAmount && ZERO.compareTo(amount) >= 0) return;`

**So there are two write paths for `STOCK_CREATED` — one guarded, one not — and the placeholder path takes the unguarded one by bypassing `StockrecordService` entirely.** That duplication is the actual root cause of the phantom rows, and **the fix is to route `createStockUnitCore` through `recordCreation`**, not to add a flag check to the inline copy.

**This is why the SQL guard was needed in the first place.** Fixing it properly would remove placeholder rows at source and make the `STOCK_CREATED AND amount != 0` arm redundant. Out of scope here: it does not repair already-written history, and this ticket is urgent. **Recommend its own ticket**, and fold in `recordRelocation:332`'s level-in-a-delta-column issue (§5.0) as related schema-hygiene work.

### 10.4 Deferred — `sr.created` vs `sr.modified` windowing divergence

`transaction_detail` windows on `sr.modified` (`V2.2.08:230`; also `:182, :257, :284, :287`); `transaction_summary` windows on `sr.created` (`V2.2.00:541`). This is a real divergence that can place the same row in different windows for the two reports.

**Out of scope:** changing it shifts row visibility for every tenant and does not belong in an urgent fix.

> **This is a product gap, not merely a test-fixture concern — say it plainly.** Seeding `created == modified` is the right call for the test (you cannot test one defect through another), but it means **AC-5 passes in CI while production Detail↔Summary reconciliation can still diverge after this fix ships**, for any row whose `modified` differs from `created`. **V2.2.12 does not close that gap.** If a user reports a residual reconciliation mismatch after this ships, this is the first thing to check — not a regression of the fix.

**Follow-up ticket should start with a number, not a hypothesis.** Query 3 in §11 measures the exposure; run it now so the follow-up is scoped on arrival.

### 10.5 Doc drift found during analysis

- `sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md` has **no entry** for `transaction_detail`, `transaction_summary` or the transaction report (only `:124` Stock Unit Record). The CLAUDE.md "grep the function-to-docs map first" step therefore returns nothing for this ticket. **Add rows.**
- `sbdocs/3-Resources/design/wms2-stockunit-design.md` maps `STOCK_TRANSFERRED → recordTransferStockUnit` at `:283`, pick-confirm at `:441`, merge branch at `:94`. Nothing is made **stale** by this SQL-only fix, but **no doc anywhere records that `recordTransferStockUnit` sets `amount = 0` and carries the quantity in `amountstock`** — that omission is precisely what made this bug easy to reintroduce. **Add it to `:283`, plus the full-move / partial-move split at `:441`.**
- No transaction-report design doc exists at all. Worth creating.
- ~~**`v2/wms2-api/CLAUDE.md:113` is wrong**~~ — **RETRACTED during implementation. The doc is correct on `origin/develop`.** It already reads *"The app **runs Flyway on every boot** (`StartupFlywayMigrator`, ApplicationRunner before readiness)"*, consistent with `StartupFlywayMigrator.java:42,128`. No edit needed.

  **Why the false finding, and the lesson:** the authoring session read `CLAUDE.md` while the local checkout sat on the stale `bugfix/SBDEV-2729-…` branch, where line 113 still carried the old *"the running app does not invoke Flyway"* text. **Reading any doc from a stale working tree manufactures phantom drift findings** — the doc looks wrong, but the branch is. Every doc-drift claim must be read from `origin/develop` (or the intended base), exactly as §7.1 already requires for code. The substantive reasoning was unaffected: §12.1 row 7 treats multi-replica Flyway contention as real *because* the app migrates at startup, which is what `develop` documents.

### 10.6 Resolved — SBDEV-1232 stays separate

SBDEV-1232 (`stock_history()` back-computation; picking is not one of its roll-back terms) is a different defect in a different function. Untouched here.

### 10.7 Deferred — `CREATE OR REPLACE` forward-copying is the pattern that creates Hazard 1

Every report-function fix (V2.2.00 → V2.2.07 → V2.2.08 → V2.2.12) copies the entire ~390-line body forward to change a handful of lines. **The plan's single biggest risk — Hazard 1, "copied the wrong ancestor and silently reverted the prior fix" — is manufactured by that pattern**, not by this change.

A Flyway **repeatable** migration (`R__transaction_detail.sql`) re-applies whenever its checksum changes, which is exactly the right semantics for a pure `CREATE OR REPLACE FUNCTION`, and reduces Hazard 1 to zero by making one file the single source of truth.

Worth noting: **v2's `CLAUDE.md` contains no `R__` prohibition** — only the convention at `:134` to "add the next V2.2.x". (The v1 `CLAUDE.md:122` *does* forbid `R__`, but that guidance is stale on other points too — see the v1 plan §5.) And v2 genuinely runs Flyway at startup (`StartupFlywayMigrator.java:42` `TENANT_LOCATION = "classpath:db/migration"`, invoked at `:128`), so repeatables would be picked up.

**Not done here** — this ticket is urgent and changing migration strategy mid-fix would enlarge the blast radius well past one line. **Recommend a separate plan** proposing report functions move to `R__` repeatables in v2.

### 10.8 RESOLVED — OMS performs no arithmetic; the fix does deliver the missing line item

This was raised as potentially blocking: the newly-visible rows come back with `depleted_picked = qty` but **`net_change = 0`**, because `transaction_detail` computes `net_change` from `received | returned | adjustments` **only** (`V2.2.08:164-170`) and hardcodes `total`, `depleted_club`, `shipped` to 0 in that branch (`:150, :162, :163`). Picking contributes nothing to `net_change` by construction. If OMS drove its reconciliation off `net_change`, the rows would become visible without the report reconciling.

**It does not. Verified in `oms-laravel-api` on `develop`:**

- `TransactionReportService.php:1458-1487` — every key is `$transaction['metadata'][X] ?? default`, one WMS field per key, **no computation**. Nine independent columns: `total`, `received`, `returned`, `adjustments`, `transferred`, `damaged`, `depleted_picked`, `depleted_club`, `net_change`.
- `TransactionReportController.php:1095-1120` — CSV/Excel headers are those same nine as **separate named columns**. There is **no aggregate "Quantity" field**. Values at `:1149-1157` are one-field-per-column passthroughs.
- `grep -n "reconcil\|discrepan\|isBalanced\|balance_check"` across `app/Services/Reporting/` and `app/Http/Controllers/Api/Reporting/` → **zero hits.** Nothing in OMS computes or checks that BEGINNING + movements = ENDING.
- Summary path is the same: `:3009-3037` passes WMS's own `beginning_inventory` / `ending_inventory` (`:3022`, `:3031`) and `net_change` (`:3032`) through verbatim — OMS never derives begin/end by summing anything.

**Consequence:** "reconciliation" in this report means the user reading per-row columns, not a derived total. Making UL pick rows visible puts a genuine non-zero value in that row's own `Depleted Picked` column — which directly fixes the confirmed complaint. **`net_change = 0` on a pick row is correct WMS semantics, not an OMS rendering defect.**

**Two residual items — checklist, not blockers:**

1. **Confirm begin/end already account for the pick.** `beginning_inventory` / `ending_inventory` are WMS-native on-hand snapshots, not derived from `net_change`, so they most likely already reflect the pick's real effect. That arithmetic lives entirely in WMS and could not be proven from OMS source. **Add to §8.5:** for an affected SKU, verify `ending_inventory − beginning_inventory` already accounts for the pick independently of `net_change`. If it does not, a second WMS-side `net_change`-formula fix is needed to satisfy the ticket's literal wording — **that would be a scope change, so check it before writing the migration.**
2. **Confirm which UI the reporter actually used.** `v2/omsv2-UI` has **no wired Detailed Transaction Report component** — `src/components/Reporting/data/reportsData.ts:59-66` is a catalog card with no component, no columns and no API call, and that repo's `CLAUDE.md` states it currently uses mock data with no API integrations. So the UAT screenshot did not come from the current `omsv2-UI` source. It came from another branch/build, the legacy UI, a direct API call, or the PDF/CSV export. Worth pinning down before closing, since it determines where to re-run the §8.5 repro.

### 10.9 Open — none other blocking

Apart from §10.8, no open question blocks implementation. The remaining unverified element is live-data confirmation, addressed by §11 and recorded as `db_verified: false`.

---

## 11. Verification queries — run these BEFORE starting

`db_verified: false`. Run both against the **NYWH tenant DB** and paste results here.

```sql
-- 1. Expect NON-ZERO. These are the picks currently invisible in the Detailed report.
SELECT count(*) FROM stockrecord sr
  JOIN client c ON sr.client_id = c.id
 WHERE c.cl_nr = 'TESTTOTAL'
   AND sr.activitycode = 'PICKING'
   AND sr.type = 'STOCK_TRANSFERRED'
   AND sr.modified BETWEEN '2026-05-01 00:00:00' AND '2026-08-10 23:59:59';
-- Result: ____________

-- 2. Confirms the "~18 SKUs" is an itemdata-population fact, not a query bug (§10.2).
SELECT count(*) FROM itemdata i
  JOIN client c ON i.client_id = c.id
 WHERE c.cl_nr = 'TESTTOTAL';
-- Result: ____________   (expect ≈ 18)

-- 3. Sizes the created/modified windowing divergence (§10.4) so the follow-up ticket
--    starts with a number. Not a gate on this fix — a measurement to carry forward.
SELECT count(*) FILTER (WHERE sr.modified IS DISTINCT FROM sr.created) AS diverging,
       count(*)                                                        AS total
  FROM stockrecord sr
  JOIN client c ON sr.client_id = c.id
 WHERE c.cl_nr = 'TESTTOTAL'
   AND sr.modified BETWEEN '2026-05-01 00:00:00' AND '2026-08-10 23:59:59';
-- Result: ____________
```

**Interpretation.** Query 1 non-zero ⇒ defect confirmed live and sized. Query 1 zero ⇒ the defect is still real (it is provable from source) but the reported tenant is not demonstrating it — reconcile before proceeding. Query 2 ≈ 18 ⇒ §10.2 confirmed; the missing SKUs are a data question, close that half of the ticket accordingly.

---

## 12. v2-only constraint checklist

| # | Constraint | Verdict | Evidence / rationale |
|---|---|---|---|
| 1 | OSIV disabled | **N/A** | No new repository call or lazy association. Change is in-DB behind existing `nativeQuery` projections. |
| 2 | `tenantTransactionManager` | **N/A** | No new `@Transactional` method. Existing read paths unchanged. |
| 3 | `@Transactional(readOnly=true)` | **N/A** | No new service method. |
| 4 | Caffeine cache invalidation | **N/A** | No cached entity is written. Report output is not cached. |
| 5 | Jakarta namespace | **N/A** | No Java change. |
| 6 | H2-compatible test SQL | **N/A — deliberately** | H2 is on the classpath (`pom.xml:344-345`) but is **unusable here**: PL/pgSQL `RETURN QUERY EXECUTE` cannot run on H2. The harness pins real `postgres:16`. **Do not attempt H2 compatibility.** |
| 7 | `BaseControllerTest` for controller changes | **N/A** | No controller change — and `BaseControllerTest` **does not exist in this repo** (`find` returns nothing). Do not invent a requirement to extend it. |
| 8 | Micrometer metrics | **N/A** | Report generation is user-initiated and low-frequency; no existing metric covers it and adding one is not justified by this fix. |

## 12.1 Horizontal scalability validation

| # | Concern | Verdict | Evidence / rationale |
|---|---|---|---|
| 1 | In-JVM state | **N/A** | No Caffeine / map / static / ThreadLocal added. |
| 2 | Connection pool math | **N/A** | No change to per-request connection count. |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` added. |
| 4 | Long transactions | **N/A** | No transaction boundary changed. Report query is unchanged in shape. |
| 5 | Request affinity | **N/A** | Stateless request/response. |
| 6 | Retry / idempotency | **N/A** | No write path touched. |
| 7 | **Flyway concurrency on multi-instance startup** | **Yes — no new mitigation needed** | Replicas starting together contend on `flyway_schema_history`; PostgreSQL's advisory lock serialises them, and `CREATE OR REPLACE` is idempotent. Identical profile to V2.2.07 and V2.2.08, both of which shipped clean. |
| 8 | Distributed lock correctness | **N/A** | No lock acquired. |
| 9 | Cache invalidation across replicas | **N/A** | Nothing cached. |
| 10 | **External notifications / result-set size** | **Yes — note only** | No notifications. But the report was **under**-returning and will now return more rows. Not a regression; watch render time on the largest UL-heavy tenant. **Operationally: V2.2.12 must reach every tenant DB** — tenants at differing migration levels report differently until all are migrated. |

---

## 13. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | **no — `db_verified: false`.** DB MCP not connected in the authoring session. Acceptable here because the root cause is provable from source: the predicate is deterministically false for every row the writer emits with `setAmount(ZERO)`; no data condition is guessed. §11 gives the two queries the implementer must run first, with interpretation for both outcomes. |
| 1 | All callsites enumerated | ✓ §0 — 36 `!= 0` hits swept across all v2 migrations; every row visited or excluded with rationale |
| 2 | Adjacent bugs | ✓ §0 — **a sibling instance of the same bug class was found** (`received` / `STOCK_REMOVED`+`STOCK_ALTERED`, latent, documented and excluded with rationale). Two sweeps recorded with their true scope; AC-9 added to close the class. Plus §10.3 (duplicated `STOCK_CREATED` write paths) and §5.0 (`recordRelocation:332` level-in-a-delta-column) |
| 3 | Backward compatibility | ✓ §5.2.4 — signature and `RETURNS TABLE` unchanged; `CREATE OR REPLACE` preserves OID/ACLs; no Java, API or payload change (§6) |
| 4 | Concurrency | ✓ §12.1 row 7 — Flyway multi-replica startup serialised by advisory lock; no application-level concurrency touched |
| 5 | Multi-tenant | ✓ §7.1 + §12.1 row 10 — per-tenant migration rollout is an explicit prerequisite; function is client-scoped by its `cl_nr` parameter |
| 6 | Error handling | ✓ No new throw path. AC-4 + AC-6 prove the SBDEV-2801 NULL→500 protection survives |
| 7 | Observability | no — no new failure mode introduced; report generation is user-initiated and low-frequency. §12 row 8 |
| 8 | Rollback / migration | ✓ §5.3 Hazard 1, §7.2 Step 3. Rollback = re-apply the V2.2.08 body as a new migration; no data written, so rollback is pure DDL |
| 9 | Test coverage | ✓ §8.3 AC-1…AC-10 integration (AC-9 structural, AC-10 write-path invariant), §8.4 regression, §8.5 manual. §8.6 records why unit tests are N/A |
| 11 | **Does the fix close the ticket?** | ✓ **§10.8 — resolved.** OMS performs no arithmetic; it renders nine independent passthrough columns, so the fix puts a real quantity in the row's own `Depleted Picked` column. `net_change = 0` is correct WMS semantics, not a defect. Two residual checklist items remain (begin/end snapshot check; which UI produced the screenshot) — neither blocks implementation |
| 10 | Cross-version (v1↔v2) | ✓ **v1 carries the identical live defect.** Paired plan authored at `sbdocs/1-Projects/wms1/plan/SBDEV-2890-transaction-detail-ul-picks-excluded.md`. v2 gated first; v1 gate pending — see §14 |

---

## 14. Cross-version pairing (v1 ↔ v2)

v1/wms-api is **also broken, in production**, by the same one-line defect.

| | v1/wms-api | v2/wms2-api *(this plan)* |
|---|---|---|
| Broken predicate | `V1.1.08__wms_functions.sql:210` | `V2.2.08:242` |
| Value CASE arms | `V1.1.08:176-178` | `V2.2.08:208-210` |
| Live `transaction_summary` (unguarded) | `V1.1.04:367`, arms `:417-418` | `V2.2.00:460`, arms `:509-510` |
| Writer | `StockrecordService:259` → `:267`, `:268`, `:288` | `StockrecordService:265` → `:272`, `:273`, `:293` |
| Branch structure | `:227`/`:235` placeholder, `:238`→`:253` full move, `:273`/`:274` partial, `:330` nirvana | `:336-342`, `:345`→`:360`, `:369`/`:376`/`:377`, `:425` |
| New migration | **`V1.26.32`** | **`V2.2.12`** |
| Timestamp type | `timestamp **without** time zone` | `timestamp **with** time zone` |
| Gate test name | `TransactionDetailUlPickIT.java` | `TransactionDetailUlPickIntegrationTest.java` |
| Existing harness to copy | **None** — v1 has no `transaction_detail` test at all | `TransactionDetailNullAmountIntegrationTest` |

**Sequencing:** v2 is gated first (the ticket is v2/UAT). The v1 gate is **pending** and must be run separately, in the v1 repo, with the `…IT.java` suffix. One TDD-gate run cannot own both repos — see §8.1.

---

## 15. Acceptance

**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2890-transaction-detail-ul-picks-excluded.sh`

Run it **before** any change (must FAIL) and **after** (must report `Result: N pass, 0 fail, 0 skip`). Paste that exact line in the completion report.

**Recorded baseline — the script was validated against four trees, not just the current one:**

| Tree | Result | Meaning |
|---|---|---|
| Current `origin/develop`, before the TDD gate | `1 pass, 31 fail, 0 skip` | The single pass is a legitimate absence assertion (no wrong-suffix test file exists) |
| **After the TDD gate, before the fix** | **`12 pass, 20 fail, 0 skip`** | T1–T11 and M2 now pass (tests exist and the SBDEV-2801 regression suite is green); every S/A/V/H check and M1 still fail, as they must until V2.2.12 lands |
| **After the fix (V2.2.12)** | **`32 pass, 0 fail, 0 skip`** | Acceptance met. Reproduced independently by the conformance lane, not just self-reported |
| Correct fix + header documenting the change | `20 pass, 12 fail` — **zero** S/A/V/H failures | A correct migration passes every structural check. The 12 remaining are test-file checks, expected until the TDD gate writes them |
| **Unfixed body carrying V2.2.08's header** | `11 pass, 21 fail` — **H1–H5 all FAIL** | The Hazard-1 gate genuinely discriminates |

That third row is the one that matters. An earlier revision of this script passed **all four** Hazard-1 checks on a V2.2.00-derived body, because `V2.2.08`'s header quotes the six coalesce expressions as comment text and the checks scanned the raw file. The script now strips comments before matching. **A `Result:` line from a script that has not been validated against a deliberately-wrong fixture does not mean what it appears to mean** — if this script is ever modified, re-run all three trees.

The script proves **code shape only**. Full acceptance additionally requires:
- `mvn verify` green in `v2/wms2-api`, including AC-1…AC-10 and the §8.4 regression set;
- the §8.5 manual plan executed against UAT, scenarios 1–3 at minimum;
- the §11 queries run and their results recorded.

A green script with the manual plan unrun is **not** acceptance.

---

## 16. Implementation Status

**Implemented and PR-submitted 2026-08-10. Not merged, not deployed.**

**PR:** https://github.com/SiteBossInc/wms2-api/pull/137 → `develop`
**Branch:** `bugfix/SBDEV-2890-transaction-detail-ul-picks` (note: `bugfix/`, not `feature/` — repo convention, §7.1)
**Commits:**
- `bb173640` — `fix(reports): include full-move unit-load picks in transaction_detail [SBDEV-2890]`
- `8fdc72a8` — `docs(db): reserve V2.2.11 and record the version-picking rule [SBDEV-2890]`

### Done

- [x] Verify-script FAIL baseline captured — `1 pass, 31 fail` (pre-gate) → `12 pass, 20 fail` (post-gate) → **`32 pass, 0 fail, 0 skip`** (post-fix)
- [x] `V2.2.12` created; **one-hunk diff** against V2.2.08 proven (control: same diff vs V2.2.00 is 1480 lines)
- [x] AC-1 + AC-5 confirmed RED pre-fix — `expected: 12 but was: 0`, `expected: 17.0000 but was: 5.0000` — reproduced **independently** by the conformance lane
- [x] All ACs green post-fix: 10 integration + 2 unit
- [x] Full unit suite `4735 run, 2 failures` — identical to pre-change baseline (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`, both pre-existing and causally excluded)
- [x] Conformance verifier: **PASS**
- [x] Code review: no BLOCKER; 2 HIGH + 6 MEDIUM fixed, 7 LOW addressed/recorded
- [x] Docs updated per §10.5 (function-to-docs map, stockunit design doc) + `db/migration/README.md`

### Tests added

| Class | Tests | Criteria |
|---|---|---|
| `TransactionDetailUlPickIntegrationTest` | 8 | AC-1…AC-6, AC-8, AC-11, AC-12 |
| `TransactionDetailAllowListStructuralIntegrationTest` | 2 | AC-7, AC-9 |
| `StockunitBusinessServiceFullMoveInvariantUnitTest` | 2 | AC-10 |

### NOT done — carried into the PR, not silently dropped

- [ ] **§11 queries** — `db_verified: false`, never run
- [ ] **§8.5 manual plan** — unrun. **Scenario 8 could still make this a two-fix job**; scenarios 11 (per-tenant Flyway check) and 12 (result-set growth) are deploy prerequisites
- [ ] **v1 paired plan** — gate pending, separate repo, separate run
- [ ] Merge / deploy / archive — not this plan's to do

### Landmines found during implementation that the plan did not predict

1. **Migration numbering** — `V2.2.11` was claimed by in-flight SBDEV-2732 work and is *invisible* on `origin/develop`. "Highest merged version" ≠ "next free". Cost two numbers; now a 3-way check in §5 and in `db/migration/README.md`.
2. **Reading docs from a stale branch manufactures phantom drift.** The plan's original CLAUDE.md finding was retracted for exactly this — §10.5.
3. **AC-9 was mis-specified as RED.** It is a regression guard; a static set-difference cannot see runtime unreachability. §8.3.
4. **`mvn verify` without `-Dtest=…` drags in the full unit suite**, so the 2 pre-existing failures sink it and look like a regression. Produced one false failure here; both verify scripts now isolate Failsafe.
5. **`hasPickLine`-style value assertions cannot observe *admission*.** A row admitted in error renders with a zero value and a non-`Picked` label, so three "stays excluded" assertions were unfalsifiable until switched to `movementRowCount`.
6. **`@InjectMocks` skips field injection** once constructor injection succeeds — the `@PersistenceContext` `EntityManager` stays null. Needs `ReflectionTestUtils`.
7. **`GetTransactionDetailSmokeTest` is `@Disabled`** (SBDEV-2217), so §8.4's "must stay green" row for `ClientRepositoryIntegrationTest` is not a real gate today. §3.
