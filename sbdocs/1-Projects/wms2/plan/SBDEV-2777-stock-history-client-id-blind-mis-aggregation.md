---
title: "SBDEV-2777 — stock_history() is client_id-blind: stock/transaction reports mis-attribute across clients sharing a SKU"
ticket: "SBDEV-2777"
ticket_url: "https://app.clickup.com/t/868kj0xw6"
type: "bugfix"
severity: "high"
priority: "high"
status: "reviewed"
project: ["wms2-api"]
version: "v2"
requester: "nam.park@siteboss.net"
assignee: "Nam Park"
created: "2026-07-30"
updated: "2026-07-30"
revision: 4
db_verified: true
db_verified_note: >
  Verified live 2026-07-30 against wms2-wineco-dev (dev_wh01_om1), wms1-wineco
  (wh01_om1) and all four UAT tenants, read-only.
  FIX A: reproducible by query — SKU PNRO23 is stocked by clients 146701 and 512500;
  the shipped stock_history returns 8,322 received for BOTH, where the true per-client
  figures are 1,074 and 7,248. The corrected aggregation was run inline (no DDL) and
  returns exactly 1,074 / 7,248.
  FIX B: numerically measured across all five tenants in revision 2 (it was NOT measured
  in revision 1 — see §10 D1-R). 2,894 SKUs / -194,757 adjustments swing on the largest
  tenant. Fix B is ~54x Fix A's blast radius, which is why r2 unbundles them.
  Also verified fleet-wide: report-function ownership == tenant app role on all 5
  (so CREATE OR REPLACE will not fail on ownership), and stock_view rows with NULL
  client_id == 0 on all 5. Queries + results inline in §1.
related:
  - "[[260420-v2-port-plpgsql-functions-to-java]]"
  - "[[wms2-apply-pending-tenant-flyway]]"
  - "[[260730-wms2-sysprop-current-value-census]]"
tags:
  - plan
  - reviewed
  - wms2
  - bugfix
  - reporting
  - plpgsql
  - multi-tenant
---

# SBDEV-2777 — `stock_history()` is client_id-blind

**Ticket:** [SBDEV-2777](https://app.clickup.com/t/868kj0xw6)
**Project:** wms2-api | **Version:** v2 | **Type:** bugfix
**Priority:** high | **Severity:** high
**Status:** reviewed — 2 ralplan rounds applied (Architect ×2, Critic ×1; the round-2 Critic
was stood down when the requester stopped the loop). All findings from both rounds are applied
in r3. **Not** an approval that r3 itself was re-reviewed — r3 is strictly a subtraction from
r2, and the behavioural gate is the TDD step, not another document pass.
**Date:** 2026-07-30

> **Scope decisions** (§10 records them in full): **ONE migration — `V2.2.07`, Fix A + Fix B**
> (D1-R reversed again in r3 — unbundling bought nothing operationally; see D1-R2);
> **unconditional**, no sysprop gate; `V2.2.00` base dump left alone; **v2 only**.
> **No onboarding mirrors** — r2 added them, r3 removes them as dead files (§0 row 4).

> **Review status — rounds 1 and 2 complete; loop stopped by the requester (2026-07-30).**
> Round 2's Architect returned ITERATE with 2 blockers, **both defects that r2 itself
> introduced**. Rather than iterate a fourth time, the requester chose to take the reviewers'
> cut recommendations and move the remaining effort to the TDD gate. **r3 is that cut-down and
> is smaller than r2 in every dimension** — 1 SQL file (was 4), ~26 verify checks (was ~50),
> 10 integration tests (was 14). §16 records what each round changed.
>
> _(historical — round 1)_ Architect + Critic both ran.
> Critic verdict: **ITERATE**, 6 blockers. This revision applies all of them. What the
> review changed is recorded in §16; the short version is that r1's *diagnosis* survived
> intact and r1's *gates* did not — three of r1's acceptance oracles could not have
> detected a wrong implementation, and one (§8.2's integration test) could never have
> executed at all. Requester decision D1 was re-opened and reversed on measured evidence.

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep over `v2/wms2-api/src/main/{java,resources}` plus `pg_proc` /
`pg_depend` on `dev_wh01_om1`, not from memory.

| # | Site | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `db/migration/V2.2.07__fix_stock_history_client_id_aggregation.sql` (NEW) | `CREATE OR REPLACE` — **Fix A + Fix B**, one migration | **yes** | **yes** |
| 2 | live `public.stock_history` on all 5 tenants | client_id-blind `GROUP BY` + join | **yes** | **yes** — via #1 |
| 3 | `db/migration/V2.2.00__base_v2_schema.sql:39` | carries the same blind body | yes | **no** — decision D3 §10; `provision-fresh-v2-db.sh` applies `db/migration` in order, so a fresh DB lands correct. Editing a generated dump would desync it from its documented refresh procedure |
| 4 | `db/v1-to-v2-onboarding/schema/V1.2.05__utc_update_functions.sql:47` | origin of the blind body | yes | **no** — r1 excluded it, r2 wrongly overturned that, **r3 restores the exclusion**. See the callout below |
| 5 | `db/v1-to-v2-onboarding/schema/V1.0.03__wms_functions.sql:13` | original blind body | yes | **no** — same rationale as #4 |
| 6 | `public.transaction_detail` (live) | calls `stock_history($3)`/`($4)` for BEGINNING/ENDING rows | consequence, not cause | **no** change — corrected transitively; **yes** for verification (§9) |
| 7 | `public.transaction_summary` (live) | calls `stock_history($2)`/`($3)` for beginning/ending inventory | consequence, not cause | **no** change — corrected transitively; **yes** for verification (§9) |
| 8 | `repo/jpa/StockViewRepository.java:62` | `stockHistoryAfterAsOfDate` native query | caller | **no** change — signature unmoved; **yes** for smoke test |
| 9 | `repo/jpa/StockrecordRepository.java:24` | `transactionDetailByClientNumberAndSkuBetweenDates` | caller | **no** change; smoke test |
| 10 | `repo/jpa/StockrecordRepository.java:34` | `transactionSummaryByClientNumberBetweenDates` | caller | **no** change; smoke test |
| 11 | `repo/jpa/ClientRepository.java:53` | `getTransactionSummary` (`@RestResource`) | caller | **no** change; smoke test |
| 12 | `repo/jpa/ClientRepository.java:63` | `getTransactionDetail` (`@RestResource`) | caller | **no** change; smoke test |
| 13 | `all_shipped` subquery inside `stock_history` | `GROUP BY bp.itemdata_id`, join `sv.item_id = all_shipped.bpid` | **no** | **no** — already client-safe: `itemdata_id` is the itemdata PK, which is unique per client. Only the `item_nr`-keyed join is defective |
| 14 | `service/StockrecordService.java:329` | comment referencing the two report functions | no | **no** — comment only |

> ### Row 4 — r2 got this wrong; r3 reverts it. Read this before proposing mirrors again.
>
> **r2 overturned r1's exclusion and added mirrors `V2.1.18`/`V2.1.19`. That was wrong on
> three independent counts, each fatal** (round-2 Architect, verified from source):
>
> 1. **Nothing would execute them.** The onboarding chain is **not** Flyway-version-sorted in
>    production — `db/v1-to-v2-onboarding/README.md:44` says it is "applied **manually via
>    psql**". The executor is `onboarding-tz-variants/scripts/04-schema-bridge.sh:21-36`, a
>    **hard-coded list** running `V2.1.01 … V2.1.16`. A `V2.1.18` is never invoked.
> 2. **The `V2.1.17` precedent r2 leaned on is itself a dead file.** `grep -rn "V2.1.17"`
>    across the onboarding toolkit returns **zero hits**. r2 verified it was byte-identical to
>    `V2.2.02` and inferred an established convention — but byte-identical and *executed* are
>    different claims, and only the first was checked.
> 3. **Even if wired in, the phase order is backwards.** `04-schema-bridge.sh:3` is Phase C;
>    `07-utc-migrate.sh:27-28` runs `V1.2.05` in Phase F, logged "LAST". C precedes F, so the
>    mirror would be reverted by the very script it was meant to defend against.
>
> **The hazard is real but already covered — no new file needed.** After Phase F the runbook
> (`wms2-apply-pending-tenant-flyway.md` §6.1–6.2) has the operator probe the watermark, run
> `backfill-flyway-history.sh --up-to 2.2.00`, then `flyway migrate` — which applies
> `V2.2.01 … V2.2.07` from `db/migration`, **after** `V1.2.05`. An onboarded tenant gets the
> fix with zero mirrors.
>
> **Patching `V1.2.05` directly was also considered and rejected.** It breaks no checksum
> (tenant history is rooted in `db/migration`; `V1.2.05` is psql-applied, never Flyway-tracked),
> but it would rewrite the record of what five production-lineage databases actually received —
> violating **P3's purpose** if not its letter.
>
> ⚠️ **If mirrors are ever revisited, note the trap:** a mirror combined with a function-body
> watermark probe is dangerous. A true probe leads the operator to backfill `--up-to 2.2.07`,
> and `backfill-flyway-history.sh:18` inserts SUCCESS rows **without executing the scripts** —
> marked applied, body never fixed, silently. Function-body probes and function-body mirrors
> must not coexist. The correct intervention, if ever wanted, is editing `04-schema-bridge.sh`
> **and** moving it post-Phase-F — a toolkit change and its own ticket, not a file drop.

**No Java change is required by this plan.** The function's parameter list and
`RETURNS TABLE` columns are unchanged, and all five call sites (#8–#12) select explicit
column lists. Rows #8–#12 exist in this table so §8 covers them as smoke targets, not
as edits.

---

## 1. Problem Statement

Stock and transaction reports report the **wrong quantities for any SKU that more than
one client stocks**. Each client's row shows the sum across *all* clients holding that
SKU, not that client's own movements.

There is no error, no exception, and no log line — the reports render normally with
inflated numbers. It surfaces only when someone reconciles a report against physical
stock or against OMS.

### 1.1 Reproduction (live, read-only, 2026-07-30, `dev_wh01_om1`)

`PNRO23` is stocked by two clients. What the shipped function returns versus the truth:

```sql
-- what stock_history's client_id-blind subquery computes (one value, reused for every client)
SELECT sr.itemdata,
       sum(CASE WHEN sr.activitycode='RECEIVING'
                  OR (sr.activitycode='STOCK_ALTERED' AND sr.type='STOCK_ALTERED')
                  OR (sr.activitycode='STOCK_REMOVED' AND sr.type='STOCK_REMOVED')
                THEN sr.amount ELSE 0 END) AS received_blind
  FROM stockrecord sr WHERE sr.itemdata='PNRO23' GROUP BY sr.itemdata;
--  PNRO23 | 8322.0000
```

| client_id | true `received` | what `stock_history` returns | error |
|---|---|---|---|
| 146701 | 1,074 | **8,322** | **+7,248 (7.7×)** |
| 512500 | 7,248 | **8,322** | +1,074 |

### 1.2 Blast radius — all 5 active v2 tenants

Every v2 tenant carries the blind body (it is the repo baseline). Reports are *actively*
wrong wherever a SKU is shared. Count of `stockrecord` SKUs with `>1` distinct `client_id`:

```sql
SELECT count(*) FROM (SELECT itemdata FROM stockrecord
   GROUP BY itemdata HAVING count(DISTINCT client_id) > 1) x;
```

| Tenant | Clients | **Fix A** SKUs (shared-SKU mis-attribution) | **Fix B** SKUs | Fix B rows | Fix B `adjustments` swing |
|---|---|---|---|---|---|
| `wsl/wh01_om1_v2` (WineCo UAT) | 156 | **135** | **2,894** | 15,939 | **−194,757** |
| `dev/dev_wh01_om1` (WineCo dev) | 141 | 43 | **2,316** | 12,116 | −130,445 |
| `c1wh/wh01_shipitez_v2` | 153 | 13 | 48 | 1,055 | −18,757 |
| `nywh/wh01_hydra_v2` | 138 | 7 | 27 | 645 | −11,126 |
| `nywh/wh02_shipitez_v2` | 122 | **0** | **0** | 0 | 0 — inert for both |

```sql
-- Fix B extent (r2; NOT measured in r1)
SELECT count(DISTINCT itemdata), count(*), coalesce(sum(amount),0) FROM stockrecord
 WHERE (activitycode='STOCK_REMOVED'  AND type='STOCK_ALTERED')
    OR (activitycode='MANUAL_REMOVAL' AND type='STOCK_ALTERED');
```

> **Fix B is ~54× Fix A** and was never measured in r1 — the whole reason r2 unbundles
> them (§10 D1-R). `adjustments` is *subtracted* in `historical_stock`, so a negative
> swing **raises** reported historical stock. Fix B also moves numbers regardless of
> client count or SKU sharing, which is what invalidated three of r1's "unchanged"
> oracles.
>
> `nywh/wh02_shipitez_v2` is zero for **both** fixes, so it remains a valid
> inertness control (§8.4) — a point r1 got right for the wrong reason and the review,
> measuring only dev, expected to lose.

### 1.3 Fix pre-validated

The corrected aggregation was run **inline as a plain SELECT** (no DDL, nothing created
or dropped) against `dev_wh01_om1` and returns the correct per-client figures:

```
 client_id | item_nr | received  | adjustments
-----------+---------+-----------+-------------
    146701 | PNRO23  | 1074.0000 |    -37.0000
    512500 | PNRO23  | 7248.0000 |     -6.0000
```

`stock_view` already exposes `client_id` (`information_schema.columns`: `row_id, item_nr,
item_id, item_name, client_id, cl_nr, cl_name, total_stock, damaged, on_hold, not_found,
transfer`), so the corrected join has a column to bind to. No view change needed.

---

## 2. Root Cause Analysis

### Bug 1: `received_recordset` aggregates and joins without `client_id`

`public.stock_history(timestamptz)` — body reproduced from `pg_get_functiondef` on
`dev_wh01_om1`, 2026-07-30. The defect is in the `received_recordset` LEFT JOIN:

```sql
         LEFT JOIN (SELECT
                      sr.itemdata                  AS itemdata,
                      coalesce(sum(...)) AS received,
                      coalesce(sum(...)) AS returned,
                      sum(...)           AS adjustments
                    FROM stockrecord sr
                    WHERE sr.created > $1
                    GROUP BY sr.itemdata) AS received_recordset      -- <-- no client_id
           ON received_recordset.itemdata = sv.item_nr               -- <-- no client_id
```

`stockrecord.itemdata` holds the **SKU string** (`itemdata.item_nr`), not the itemdata
PK — and `item_nr` is only unique *within* a client. So:

1. The subquery collapses every client's movements for a SKU into **one row**.
2. The join matches that single row to **every** `stock_view` row for the SKU — one per
   client.
3. Each client therefore receives the all-clients total for `received`, `returned`, and
   `adjustments`, and `historical_stock` is derived from those:
   `total_stock_today - received - returned + shipped - adjustments`.

The sibling `all_shipped` subquery is **not** affected — it groups by
`bp.itemdata_id` and joins `sv.item_id = all_shipped.bpid`, both of which are the
itemdata PK and thus already client-unique. That asymmetry is why only part of the row
is wrong, which makes the bug easy to miss on inspection.

**Why it is not a v1→v2 porting miss.** The four missing clauses appear in **no
migration script in either repo at any version**, and `git log -S 'GROUP BY sr.itemdata,
sr.client_id' --all` returns **nothing in either repo's history**. They were applied
out-of-band directly to WineCo's v1 database. v2 faithfully reproduces the committed
lineage: `V1.0.03__wms_functions.sql:13` → `V1.2.05__utc_update_functions.sql:47`
(which DROP+CREATEs all three report functions from hard-coded bodies). Comparing the
`stock_history` block in those two files shows they are identical apart from the
`timestamp` → `timestamptz` signature — the UTC conversion changed the signature and
nothing else.

**So this has always been broken in the repo.** WineCo's v1 DB is the only place the fix
has ever existed, and it exists there untracked.

### Bug 2: `stock_history` disagrees with its own sibling functions on activity codes

`stock_history` omits two activitycode/type pairs that the *other two* report functions
in the same database **do** count:

| Pair | `stock_history` | `transaction_detail` | `transaction_summary` |
|---|---|---|---|
| `STOCK_REMOVED` + `STOCK_ALTERED` (→ `received`) | **absent** | present (2×) | present (1×) |
| `MANUAL_REMOVAL` + `STOCK_ALTERED` (→ `adjustments`) | **absent** | present (3×) | present (1×) |

Confirmed by grepping the live bodies on `dev_wh01_om1`. Because `transaction_detail`
and `transaction_summary` both call `stock_history` for their BEGINNING/ENDING rows, a
single report can show an opening balance computed under one rule and period movements
computed under another. The v1 WineCo DB has these pairs in all three functions.

This is a **separate** defect from Bug 1 — it changes different numbers, on different
SKUs, and would still be wrong on a single-client tenant. The requester elected to ship
both in one migration (§10 D1).

---

## 3. The Regression Chain

Not a regression — there is no commit that introduced this. The blind body is the
original, present since `V1.0.03__wms_functions.sql` (the earliest committed function
definition) and carried forward unchanged through:

| Script | Role | `client_id` in `stock_history`? |
|---|---|---|
| `v1-to-v2-onboarding/schema/V1.0.03__wms_functions.sql:13` | original definition | no |
| `v1-to-v2-onboarding/schema/V1.2.05__utc_update_functions.sql:47` | UTC rewrite, hard-coded body | no |
| `migration/V2.2.00__base_v2_schema.sql:39` | base dump export | no |
| live v1 `wms1-wineco` | **hand-edited, untracked** | **yes** |
| live v2, all 5 tenants | from the lineage above | no |

**Standing hazard worth its own follow-up.** `V1.2.05` does `DROP FUNCTION` +
`CREATE OR REPLACE` from hard-coded bodies for all three report functions. Any client
that hand-edited one loses the edit at migration time, silently — no error, no warning.
The existing pre-Phase-F check only *counts* `public` functions (to catch extra ones like
ShipItEZ's `stock_history2`); it cannot see a modified body. Future migrations should
diff `md5(pg_get_functiondef(oid))` for the three functions against the committed
scripts, not just count them.

---

## 4. Architecture Overview

```
HTTP (Spring Data REST /search endpoints — no service layer)
  │
  ├─ ClientRepository.getTransactionSummary ─────┐
  ├─ StockrecordRepository.transactionSummary… ──┤
  │                                              └─→ transaction_summary(client, from, to)
  │                                                     ├─ stock_history($2)  ← beginning_inventory
  │                                                     └─ stock_history($3)  ← ending_inventory
  ├─ ClientRepository.getTransactionDetail ──────┐
  ├─ StockrecordRepository.transactionDetail… ───┤
  │                                              └─→ transaction_detail(client, sku, from, to)
  │                                                     ├─ stock_history($3)  ← BEGINNING row
  │                                                     └─ stock_history($4)  ← ENDING row
  └─ StockViewRepository.stockHistoryAfterAsOfDate ─────→ stock_history(as_of_date)   ◀── DEFECT HERE
                                                              │
                                    stock_view (has client_id) ┤
                                    stockrecord ───────────────┘
                                      └ joined on item_nr ONLY  ✗
```

The three functions call each other through `RETURN QUERY EXECUTE '<string>'` —
**dynamic SQL**. Consequences that shape the fix:

- `pg_depend` records **no** dependency (`SELECT … FROM pg_depend … WHERE proname='stock_history'`
  → 0 rows), so `CREATE OR REPLACE FUNCTION stock_history` cannot cascade-break the
  siblings and needs no `CASCADE`.
- The siblings resolve `stock_history` at **execution** time, so they inherit the fix
  the moment the function is replaced — no need to touch or redeploy them.
- No view depends on it either, so there is nothing to recreate.

### Key files

| File | Lines | Role |
|---|---|---|
| `db/migration/V2.2.05__seed_outbox_sysprop_toggles.sql` | — | current migration head; the fix is the next version after this |
| `db/migration/V2.2.00__base_v2_schema.sql` | 39 | base dump; carries the blind body (out of scope, §0 #3) |
| `db/v1-to-v2-onboarding/schema/V1.2.05__utc_update_functions.sql` | 42–47 | UTC rewrite that fixed the signature and preserved the bug |
| `repo/jpa/StockViewRepository.java` | 62 | `stockHistoryAfterAsOfDate` — direct caller |
| `repo/jpa/StockrecordRepository.java` | 24, 34 | the two report queries |
| `repo/jpa/ClientRepository.java` | 53, 63 | `@RestResource`-exposed report queries |
| `repo/projection/StockHistoryView.java` | 1–14 | projection interface — unchanged, proves the return shape must not move |
| `sbdocs/2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md` | §4.1, §5 | how the migration reaches each tenant |

---

## 5. Fix Design

**One** forward migration (D1-R2): `V2.2.07`, a full `CREATE OR REPLACE` carrying **Fix A and
Fix B together**. No mirrors. **No Java changes.** The function keeps its exact signature
(`stock_history(timestamptz)`) and its exact `RETURNS TABLE` column list, so every caller
and the `StockHistoryView` projection are unaffected.

### Fix A — join and group `received_recordset` on `client_id` (Bug 1)

Three coordinated edits inside the `received_recordset` subquery. All three are required;
any one alone is either a no-op or a syntax error.

**Before** (live on all 5 tenants):
```sql
         LEFT JOIN (SELECT
                      sr.itemdata                  AS itemdata,
                      ...
                    FROM stockrecord sr
                    WHERE sr.created > $1
                    GROUP BY sr.itemdata) AS received_recordset
           ON received_recordset.itemdata = sv.item_nr
```

**After:**
```sql
         LEFT JOIN (SELECT
                      sr.itemdata                  AS itemdata,
                      sr.client_id                 AS client_id,
                      ...
                    FROM stockrecord sr
                    WHERE sr.created > $1
                    GROUP BY sr.itemdata, sr.client_id) AS received_recordset
           ON received_recordset.itemdata = sv.item_nr
              AND received_recordset.client_id = sv.client_id
```

**Why this join is provably correct, not merely reasonable** (r2, from the Architect pass):

```sql
-- V2.2.00__base_v2_schema.sql:3580
ALTER TABLE ONLY public.itemdata
    ADD CONSTRAINT uk3l3dgof3l6mc1dl7s3lmida65 UNIQUE (client_id, item_nr);
```

`(client_id, item_nr)` is a **DB-enforced unique key**, so joining
`received_recordset(itemdata, client_id) = sv(item_nr, client_id)` is *equivalent to*
joining on the itemdata PK. That upgrades this from "the best available given
`stockrecord` has no FK" to "the unique-key-equivalent join" — and independently kills
the `itemdata_id`-FK alternative on correctness grounds (it would be normalization work,
not a correctness improvement).

**No row-drop hazard.** `stockrecord.client_id` and `itemdata.client_id` are both
`bigint NOT NULL`, and `stock_view` rows with NULL `client_id` measure **0 on all five
tenants**.

> **r4 correction — this paragraph previously said `itemdata.client_id` has *no* FK to
> `client(id)` (citing ADR-001 manual FKs). That is false.** `V2.2.00__base_v2_schema.sql:5434`
> defines `fkkqrb02j7ve4vbkys5dylqnl6x FOREIGN KEY (client_id) REFERENCES public.client(id)`, and
> the constraint is present live on `wms2-wineco-dev`. The error was in the safe direction — the
> FK makes `sv.client_id IS NULL` **structurally impossible**, not merely measured-zero, so the
> hazard is smaller than r1–r3 claimed, not larger. It is corrected because a maintainer who
> believes orphans are possible might add a defensive `coalesce(sv.client_id, …)` to the join and
> silently reintroduce the blindness. The §7.1 pre-flight is retained as cheap defence in depth.

With a nullable `client_id` this fix would have converted "wrongly inflated" into
"silently zero".

**In-schema precedent.** Both siblings **already** carry exactly this predicate —
`AND sr.client_id = i.client_id` at `V2.2.00:342` and `:540`. `stock_history` is the only
client-blind `stockrecord`-by-SKU-string join in the entire schema.

**Why this and not the alternatives:**

- *Join on `itemdata_id` instead of `item_nr` + `client_id`?* `stockrecord` has no
  `itemdata_id` FK — it stores the SKU **string** in `itemdata` (ADR-001: no JPA
  associations, manual FKs only). Adding a real FK is a schema change across a large
  table and a separate project; `client_id` is already on `stockrecord` and already on
  `stock_view`, so this fix is a pure query correction with no schema impact.
- *Port the function to Java?* Plan
  [`260420-v2-port-plpgsql-functions-to-java`](./260420-v2-port-plpgsql-functions-to-java.md)
  proposes exactly that and is `status: reviewed` but unimplemented. Waiting for it
  leaves five tenants on wrong numbers indefinitely. This fix is deliberately confined to
  the SQL so it does not conflict — when the port lands it must carry the `client_id`
  predicate, which §10 D5 records as a hand-off note.
- *Fix `stock_view` instead?* `stock_view` is already correct — it is per (item, client).
  The defect is entirely in how `stock_history` joins to it.

### Fix B — count the two missing activitycode pairs (Bug 2)

Brings `stock_history` in line with `transaction_detail` and `transaction_summary`.

**Before → After**, `received` sum:
```sql
   coalesce(sum(CASE WHEN (sr.activitycode = ''RECEIVING'')
                          OR (sr.activitycode = ''STOCK_ALTERED'' AND sr.type = ''STOCK_ALTERED'')
                          OR (sr.activitycode = ''STOCK_REMOVED'' AND sr.type = ''STOCK_REMOVED'')
+                         OR (sr.activitycode = ''STOCK_REMOVED'' AND sr.type = ''STOCK_ALTERED'')
                     THEN sr.amount ELSE 0 END), 0) AS received,
```

**Before → After**, `adjustments` sum:
```sql
   sum(CASE WHEN (sr.activitycode = ''CYCLE_COUNT'' AND sr.type = ''STOCK_ALTERED'')
                 OR (sr.activitycode = ''MANAGE_INVENTORY'' AND
                     (sr.type = ''STOCK_ALTERED'' OR sr.type = ''STOCK_REMOVED''))
                 OR (sr.activitycode = ''MANUAL_REMOVAL'' AND sr.type = ''STOCK_REMOVED'')
+                OR (sr.activitycode = ''MANUAL_REMOVAL'' AND sr.type = ''STOCK_ALTERED'')
            THEN sr.amount ELSE 0 END) AS adjustments
```

Note the doubled quotes — the body is a single-quoted string passed to
`EXECUTE`, so every literal is `''…''`. Getting this wrong is the single most likely
implementation error; the §14 verify script's negative checks are written to catch it.

> **Append each Fix-B pair LAST in its own `CASE`**, exactly as shown. The verify script's
> `b_received_pair` / `b_adjust_pair` checks anchor the new pair to its `AS received` /
> `AS adjustments` alias within a bounded window; inserting it earlier in the `CASE` (e.g.
> straight after `RECEIVING`) pushes past that window and **false-FAILs a correct fix**. The
> window is what makes a swap between the two sums detectable, so it cannot simply be removed.

### ⚠️ Landmine — do NOT add `client_id` to the outer projection

The body is `SELECT *, (…) AS historical_stock FROM ( … ) myanswer`, and `RETURN QUERY`
binds to `RETURNS TABLE` **positionally** through that `SELECT *`. Fix A is safe precisely
because it adds `client_id` only *inside the `received_recordset` join input*, never to
`myanswer`'s 7-column projection.

An implementer who reasonably thinks "I should expose client_id" and adds
`sv.client_id AS client_id` to the `myanswer` list gets a **runtime** failure on every
report — `structure of query does not match function result type` — not a build failure,
and all of r1's 21 verify checks still passed. The verify script now asserts the inner
projection is unchanged, and §8.2 asserts the column count behaviourally.

### Fix C — the migration files

One file: `db/migration/V2.2.07__fix_stock_history_client_id_aggregation.sql`, the complete
`CREATE OR REPLACE FUNCTION public.stock_history(timestamptz)` with Fix A and Fix B applied and
everything else byte-for-byte as shipped.

> **r3 collapsed this from two migrations back to one.** r2 split them so the two corrections
> could be measured separately — but the sanctioned runbook cannot stop between them:
> `apply-pending-tenant-flyway.sh:419` runs a bare `flyway … migrate` with **no `-target`**
> (zero occurrences in the script), so one `--apply` applies everything pending. The separate
> deltas D1-R was reversed to obtain were never operationally deliverable. Attribution is
> instead **analytical** — the two affected SKU sets are enumerable by SQL before the apply
> (§8.3 check #3), which works regardless of how many files ship. See §10 D1-R2.

**Source the body from `pg_get_functiondef`, not from a migration script.** `V1.2.05:48-56`
writes `RETURNS TABLE` multi-line using `stock_view.item_id%TYPE`; copying from there
produces a valid function that fails verify check `C5`, which asserts the resolved
one-line form. Take the body from
`SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname='stock_history'` and apply only
the line-level edits.

**Keep the doubled-quote (`''…''`) style.** A dollar-quoted (`EXECUTE $q$…$q$`) rewrite
would be functionally correct but fails verify checks `B1`–`B3`. That is a deliberate
constraint, not an oversight — it keeps the diff reviewable against the shipped body.

- `CREATE OR REPLACE` only — **no** `DROP FUNCTION`. The signature is unchanged, so
  replace-in-place works, keeps the OID, and avoids any window where the siblings would
  fail to resolve it. It also **preserves ownership and ACLs**, which matters here:
  `provision-fresh-v2-db.sh:262-265` carries explicit `ALTER FUNCTION … OWNER TO`
  reconciliation because function ownership is load-bearing in the v2t privilege model.
- **Postgres enforces the signature for you.** `CREATE OR REPLACE FUNCTION` refuses to
  change the return type or the names/types of OUT params (`RETURNS TABLE` columns are OUT
  params) and refuses to rename input params — so a disturbed signature **hard-errors at
  apply time (42P13)** rather than silently breaking callers. Consequence: the input
  parameter must stay named `as_of_date`.
- Idempotent and safely re-runnable: replacing a function with an identical body is a
  no-op.
- **`V2.2.06` is taken — do not reclaim it.** This plan was renumbered from
  `V2.2.06` to **`V2.2.07`** on 2026-07-30 (r2 briefly reserved `V2.2.08` as well, for a
  second migration r3 has since collapsed away). `V2.2.06` is now
  `V2.2.06__seed_outbox_stuck_aggregate_metric_sysprop.sql` (SBDEV-2785, PR
  [#110](https://github.com/SiteBossInc/wms2-api/pull/110) — **merged into `develop`
  2026-07-30**, merge commit `ed4ed25`), applied on DEV and pending on UAT.
- **`V2.2.07` is now firm.** PR #110 merged, so `V2.2.06` is permanently taken
  on `develop`. Re-check only for migrations landing *after* 2026-07-30.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `…/db/migration/V2.2.07__fix_stock_history_client_id_aggregation.sql` | **NEW** | full function, Fix A + Fix B |
| `…/src/test/java/net/aim_ai/wms/integration/StockHistoryClientIsolationIntegrationTest.java` | **NEW** | self-contained Testcontainers test (§8.2). Name **must** end `IntegrationTest` — see §8.2 |
| `sbdocs/9-System/scripts/verify-SBDEV-2777-…sh` | **UPDATE** | acceptance script, **28** checks for the single migration (r4: measured, was estimated at ~26) |
| `sbdocs/2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md` | **UPDATE** | §6.1 watermark probe row for `V2.2.07` |
| `…/db/migration/V2.2.00__base_v2_schema.sql` | none | D3 — a future re-export absorbs the fix per `db/migration/README.md`; the delta is then redundant but harmless. Noted so nobody deletes it as duplicate |

> **r3 removed three files r2 had listed here:** the second migration (`V2.2.08`) and both
> onboarding mirrors (`V2.1.18`/`V2.1.19`). See §5 and §0 row 4.

No production Java file changes. No schema changes. No config or sysprop changes.

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Concern | Required? | Detail |
|---|---|---|
| ~~Migration head divergence~~ | **RESOLVED 2026-07-30** | Was BLOCKING: `release` carried the original `V2.2.05__seed_outbox_reject_on_error_sysprop.sql` while the working tree carried it renamed + amended, and DEV's history recorded the amended version (`−382893208`) against UAT's original (`2141461053`). **Now fixed** — the amendment was reverted, DEV's `2.2.05` row re-aligned to the original, and the seed re-landed as its own `V2.2.06__seed_outbox_stuck_aggregate_metric_sysprop.sql` (PR [#110](https://github.com/SiteBossInc/wms2-api/pull/110), **merged** `ed4ed25`). All five tenants are now identical through `2.2.05`; DEV is at `2.2.06`, UAT reports it as cleanly pending with zero drift. PR #110 **merged 2026-07-30** (`ed4ed25`), so `V2.2.07`/`V2.2.08` are firm |
| DB state | **yes** | All 5 tenants must be at the current head before applying. Verify with `apply-pending-tenant-flyway.sh --env {dev,uat} --status`. UAT is at `2.2.05` and DEV at `2.2.06` as of 2026-07-30, so **UAT needs `V2.2.06` first** — this migration must not be the vehicle that skips it. *(r4: this read "needs `V2.2.05`", which contradicted its own preceding clause; step 9 always had it right)* |
| Feature flags | no | Unconditional by decision D2 (§10) |
| Sysprops | no | None read or written |
| Config / env | no | — |
| Deploy order | **yes** | Migration is **independent of the JAR** — no Java change, so it can be applied before or after any deploy. It must reach `release` before UAT tenants can receive it via the normal runbook flow |
| Data migration | no | The function is computed at query time; no stored data is wrong, so **no backfill exists or is needed**. Reports simply return correct numbers from the next call onward |
| External systems | **note** | Report numbers visible to clients will change for affected SKUs. Not a technical dependency, but see D4 (§10) on notifying affected clients |
| Access | **yes** | Tunnels + `PGPASSWORD_LANDLORD`; DEV landlord is `dev_landlord@25060`, UAT is `landlord@25062` (runbook §4.1) |
| **Function ownership** | **pre-flight** | `CREATE OR REPLACE FUNCTION` requires the connecting role to **own** the function, and the runbook connects as the tenant app role. **Measured 2026-07-30: owner == app role on all 5 tenants**, so this is clean today — keep the probe because a future tenant whose Phase F ran as an operator would fail mid-migration and leave a failed history row.<br>`SELECT p.proname, pg_get_userbyid(p.proowner), current_user FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('stock_history','transaction_detail','transaction_summary');` |
| **Orphan / NULL client_id** | **pre-flight** | `stock_view` reaches client via `LEFT JOIN`, so a client-less `itemdata` would surface as `sv.client_id IS NULL`, where the new predicate is never true and that row's figures COALESCE to 0. **r4: an FK on `itemdata.client_id` makes this structurally impossible** (see §5) — retained as cheap defence in depth. **Measured 2026-07-30: 0 on all 5 tenants.**<br>`SELECT count(*) FROM stock_view WHERE client_id IS NULL;` and `SELECT count(*) FROM itemdata i LEFT JOIN client c ON c.id=i.client_id WHERE c.id IS NULL;` |
| **Orphan `(itemdata, client_id)` stockrecord pairs** | **pre-flight (r4, from code review)** | A `stockrecord` whose `(itemdata, client_id)` pair matches **no** `itemdata` row contributes to some *other* client's `received` pre-fix and to **nobody** post-fix — correct semantics, but it means the cross-client total can legitimately *decrease* with no reconciliation trail, which looks like data loss during the §8.3 diff. `stockrecord.client_id` has no FK, so this is possible. **Measured 0 on `wms2-wineco-dev`.** Probe per tenant so a dirty tenant is caught *before* apply:<br>`SELECT count(*) FROM stockrecord sr LEFT JOIN itemdata i ON i.item_nr = sr.itemdata AND i.client_id = sr.client_id WHERE i.id IS NULL;` |
| Monitoring | no | No new failure mode; the fix removes wrong output rather than adding a code path |

### 7.2 Steps

Each step is independently committable / revertable.

1. **Capture the pre-fix baseline.** Run the §9 verify script and record `Result: 0 pass,
   N fail` — the FAIL baseline. Then, per tenant, snapshot the affected-SKU figures to a
   file (§8.3 gives the query). **Do this before touching anything**; without it there is
   no way to show reviewers what moved.
2. **Write `V2.2.07`** — body copied verbatim from
   `SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname='stock_history'`, then only the
   five line edits (three for Fix A, two for Fix B, each Fix-B pair **appended last** in its
   own `CASE` — see §5). Do not source the body from a migration script: `V1.2.05:48-56` writes
   `RETURNS TABLE` multi-line with `%TYPE`, which produces a valid function that fails verify
   check `C5`.
3. **Add the integration test** (§8.2 — name it `…IntegrationTest`, self-contained
   container, `.locations("classpath:db/migration")`) and confirm it **fails** against the
   unfixed function first. Confirm it fails *for the right reason* — under r1's design it
   would have failed because the harness could not see `db/migration` at all, which is not
   a TDD signal.
4. **Apply to DEV** via the runbook:
   `apply-pending-tenant-flyway.sh --env dev --repo <wms2-api> --apply`.
   Expect `dev_wh01_om1 @ 2.2.06 → 2.2.07`.
5. **Verify on DEV.** `PNRO23` must return 1,074 for client 146701 and 7,248 for client
   512500. Re-run the verify script: `Result: N pass, 0 fail, 0 skip`. Diff the §8.3
   capture against step 1's baseline — for `V2.2.07`, rows must change for exactly the
   §1.2 Fix-A SKUs and nothing else.
5b. **EXPLAIN gate (hard).** `EXPLAIN (ANALYZE, BUFFERS)` before/after on the largest
   tenant, with a **realistic** `as_of_date` — §8.3's epoch value forces a full
   `stockrecord` scan and is a correctness probe, not a timing sample. **Acceptance
   criterion: the aggregate node type is unchanged.** The concrete regression is a
   `HashAggregate → Sort + GroupAggregate` flip if the wider grouping key pushes the hash
   table past `work_mem`. Stakes are doubled: `stock_history` is invoked **twice** per
   `transaction_detail` and twice per `transaction_summary` call. Paste both plans into §15.
6. **Smoke the three reports** through the HTTP endpoints (§8.4), confirming
   `transaction_detail` BEGINNING/ENDING and `transaction_summary`
   beginning/ending inventory moved consistently with `stock_history`.
7. **Open the PR** into `develop`. Include the before/after `PNRO23` table and the
   per-tenant delta counts in the description.
8. **Merge and let DEV redeploy** (Portainer webhook; no JAR dependency, so ordering is
   free here).
9. **UAT** — only after `V2.2.05`, `V2.2.06` and this migration are all on `release`:
   `--env uat --apply`, then repeat steps 5–6 against each of the four UAT tenants.
   `wsl/wh01_om1_v2` has the largest delta (135 SKUs) and deserves the closest look.
10. **Add the runbook §6.1 watermark probe row** for `V2.2.07`. The runbook
    states in bold that this table "is the one part of the procedure that does not update
    itself". Every existing probe is a `los_sysprop` existence check and these migrations
    seed no sysprop, so the probe must be function-body shaped:
    `SELECT pg_get_functiondef(oid) LIKE '%sr.client_id%' FROM pg_proc WHERE proname='stock_history';`
    (and a Fix-B variant). This doubles as the durable recurrence assertion in §11 row 7.
11. **(Optional, unrelated drift) `db/v1-to-v2-onboarding/README.md:24`** still says
    `schema/` runs "through `V2.1.16`", while `V2.1.17__lock_report_exclude_shipped.sql` is
    on disk. **This plan adds no onboarding file** (§0 row 4), so this is pre-existing drift,
    not something r3 creates. Fix it in passing or spin it out — it is *not* an acceptance
    criterion. *(r4: r2's wording "this plan adds two more" survived the r3 mirror removal.)*
12. **Update this document** — §15 Implementation Status with commit SHAs, the `mvn`
    result, the final verify line, both EXPLAIN plans, and the per-tenant deltas, split by
    the §8.3 check-3 attribution buckets (`A-only` / `B-only` / `both`) rather than by
    migration — there is only one migration. Flip `status: reviewed` → `implemented`.
    *(r4: this said "each migration separately" and "`status: draft`"; neither matched r3.)*

---

## 8. Testing Plan

### 8.1 Unit

Nothing meaningful to unit-test: the fix is entirely inside a PL/pgSQL body that runs
dynamic SQL, and no Java logic changes. **Deliberately no unit test** — a mock-based test
would assert only that the repository method was called, which is already true today and
would pass against the broken function. Recorded here rather than silently skipped.

### 8.2 Integration (Testcontainers PostgreSQL — the real gate)

`StockHistoryClientIsolationIntegrationTest` — new. H2 cannot run this: the body uses
PL/pgSQL, `EXECUTE`, and `timestamptz`, so it **must** be a Testcontainers test.

> ### ⚠️ r2 — two structural traps that would have made this test meaningless
>
> **1. The name must end `IntegrationTest`, not `IT`.** Surefire excludes only
> `**/*IntegrationTest.java` and `**/*E2ETest.java` (`pom.xml:448-451`), and `*IT.java`
> matches none of Surefire's default includes. Failsafe's explicit `<includes>`
> (`pom.xml:564-568`) are those same two patterns, which **override** its own `*IT.java`
> default — the adjacent comment claiming "default pattern is `*IT.java`" is wrong about
> the effect. Verified: 27 `*IT.java` files exist, `target/surefire-reports/` contains
> **0** matching entries, and `target/failsafe-reports/` **does not exist**. Every
> `*IT.java` in this repo is a phantom test. r1 named this test `…IT` and would have
> shipped a green gate that never executed. *(Those 27 orphaned files deserve their own
> ticket — see §10 D9.)*
>
> **2. The default harness cannot see `db/migration`.** `src/test/resources/flyway.conf:11`
> and `AppPostgresDBSetupExtension.java:24` both scan **only**
> `db/v1-to-v2-onboarding/schema`. A test built on the standard harness would run against
> the *blind* body from `V1.2.05:47` and fail permanently — failing before *and* after the
> fix, for a reason unrelated to it. That is a false TDD signal, and r1's "@Disabled if
> SBDEV-2217 is still broken" escape hatch would have hidden it forever.
>
> **Use the self-contained pattern instead**, precedent
> `integration/schema/ReplenishmentMonitorViewSchemaIT.java:45-66`: start your own
> `PostgreSQLContainer`, **no** `@SpringBootTest`, no Spring context, raw JDBC, and run
> Flyway with `.locations("classpath:db/migration")`. Because it boots no Spring context
> and touches no landlord datasource, **it is immune to the SBDEV-2217 harness blocker** —
> so this test can run in CI today. Adopt that class's *structure*, not its name.
> *(Note its `:37` comment references `V2.2.02__replenishment_monitor_view…`; the real file
> is `V2.2.01__…` — pre-existing stale comment, don't copy it.)*
>
> r2 claimed here that onboarding mirrors would additionally let the **default** harness see
> the fix. That was wrong twice over and is removed in r3: the mirrors execute nowhere (§0
> row 4), and `ReplenishmentMonitorViewSchemaIT.java:28-31` documents that SBDEV-2217 *is* the
> onboarding chain's inability to run from empty — so adding scripts to that chain buys
> nothing. The self-contained pattern above is the whole answer.

| Test method | Asserts |
|---|---|
| `stockHistoryAttributesReceivedPerClient` | Two clients, same `item_nr`, different `stockrecord` amounts → each client's row shows **its own** `received`. Fails on the unfixed function (both rows show the sum) |
| `stockHistoryAttributesAdjustmentsPerClient` | Same shape for `adjustments` |
| `stockHistoryCountsBothFixBPairs` | A `STOCK_REMOVED`/`STOCK_ALTERED` row is included in `received` (Fix B) |
| `stockHistoryReturnedPerClient` | **`returned` per client.** §2 states Fix A corrupts `received`, `returned` *and* `adjustments`; r1 tested only two of the three, shipping a third of Fix A unverified |
| `stockHistoryPreservesRowsWithNoStockrecords` | **LEFT JOIN preservation.** A `stock_view` row with zero post-cutoff `stockrecord` rows must still appear. Converting `LEFT JOIN`→`JOIN` is an easy slip when adding a second ON predicate, silently drops rows from the Warehouse Stock report, and passes every code-shape check |
| `stockHistoryReturnsOneRowPerItemClient` | **Fan-out guard.** Exactly one row per (item, client). Catches "GROUP BY fixed but join left blind", which multiplies rows rather than mis-summing them |
| `stockHistoryReturnsExactlyEightColumns` | **Behavioural guard for the `myanswer` positional-binding landmine** (§5) — complements the regex check |
| `stockHistoryExcludesRecordsBeforeAsOfDate` | Guards accidental loss or weakening of `WHERE sr.created > $1` (e.g. `>=`), which would change every number for every client on every tenant |
| `transactionSummaryBeginningInventoryIsPerClient` | The fix propagates into `transaction_summary` |
| `transactionDetailBeginningRowIsPerClient` | The fix propagates into `transaction_detail` |
| `stockHistoryBodyRetainsClientIdPredicate` | **r4 — durable recurrence gate (§11 row 7 / D6).** Asserts the body *resolved by Postgres after the whole `db/migration` chain has run* still carries both Fix-A clauses. A later migration that DROP+CREATEs `stock_history` from a stale body — precisely what `V1.2.05` did to WineCo's hand-fix, silently — fails here. Verify checks `A1`–`A3` cannot catch it: they only read `V2.2.07`'s own text |

> **r4 — fixture correction (found by running the gate, not by reading it).** As first written,
> the Fix-B rows sat on the *same* `(CLIENT_A, SHARED_SKU)` cell the Fix-A assertions measure, so
> under D1-R2's re-bundling the suite contradicted itself — `received` asserted as both 100 and
> 107, `adjustments` as both 5 and 8 — and two tests could never pass together. Fix B now lives on
> its own two-client SKU (`SBDEV2777-FIXB`), giving **one independent oracle per fix**. That is
> exactly what unbundling the migrations was meant to buy and operationally could not (§10 D1-R2);
> obtaining it in the fixture costs nothing. The propagation expectations moved `−125` → `−115`
> accordingly, since `SHARED_SKU` no longer carries Fix-B rows.

> ### r3 — cut from 14 methods to 10
>
> Removed, with reasons:
> - **`stockHistorySingleClientUnchanged`** — *cannot fail on a correct Fix A.* §5's own
>   `NOT NULL` + `UNIQUE (client_id, item_nr)` proof establishes that single-client values
>   cannot move, and §8.2 admitted as much while keeping it anyway. The mis-implementations it
>   was retained for are already covered by `PreservesRowsWithNoStockrecords` (inner-join
>   conversion) and `ReturnsOneRowPerItemClient` (fan-out).
> - **`stockHistoryConservesTotalAcrossClients`** — restates `AttributesReceivedPerClient` plus
>   the fan-out guard. **Kept as a per-tenant SQL check in §8.3 instead**, where it runs against
>   live data and is genuinely the strongest available oracle.
> - **`stockHistoryHistoricalStockDerivesFromPerClientFigures`** — arithmetic over columns the
>   other assertions already pin; the formula itself is guarded by the verify script.
> - **`stockHistoryCountsManualRemovalStockAltered`** — merged into
>   `stockHistoryCountsStockRemovedStockAltered`, which now asserts both Fix-B pairs land in
>   their respective sums. One fixture, two assertions.
>
> **Share one `@BeforeAll` fixture across all ten.** `stock_view` needs 2 `client` + 2
> `itemdata` (respecting `UNIQUE (client_id, item_nr)`) + `stockrecord` rows honouring its
> NOT NULLs (`V2.2.00:2166-2190`); `stockunit`/`unitload` are optional because the view
> LEFT JOINs them, which is what makes `PreservesRowsWithNoStockrecords` cheap. Budget ~40
> lines of hand-rolled JDBC — the plan previously budgeted none.

> **SBDEV-2217 does not block this test** once the pattern above is used — the blocker is
> in the Spring-context harness, and this test boots no Spring context. There is therefore
> **no `@Disabled` escape hatch in r2**: the test must run and pass. If it genuinely cannot
> be made to run, that is a finding to surface in the PR, not a caveat to ship around.

### 8.3 Regression / DB-level verification (per tenant)

Run before and after on each tenant; the deltas are the evidence:

> **r2 — r1's check #1 here was a phantom gate and has been replaced.** It aggregated
> `stockrecord` against itself with a bare `sum(sr.amount)`, never called `stock_history`,
> and used none of the activitycode CASEs — so it returned the *same* number before and
> after the fix, and its stated expectation ("post-fix these must agree") can never hold
> for a shared SKU. r1 designated it the *primary* gate for when the ITs are disabled.
> That violated the plan's own P5. The replacement below actually calls the function.

> **r4 — this block was renumbered and made runnable.** It previously ran `1, 2b, 3, 2, 3`
> (two duplicate numbers), the conservation invariant was prose with no SQL, and the
> attribution query selected `FROM changed_rows`, a relation nothing defined. Checks 1 and 2
> below now create the two capture tables the later checks join to, so the block executes
> top-to-bottom as written.

```sql
-- ============================================================================
-- CHECK 1 (run BEFORE the migration) — capture the function's own output.
--   USE EPOCH (:as_of = '1970-01-01'::timestamptz). stock_history filters
--   WHERE sr.created > $1 while the §1.2 census applies no created filter, so under a
--   recent as_of most census SKUs have no in-window rows and the expectations below fail
--   by construction. Epoch is the only value under which the §1.2 numbers are the right
--   yardstick. A realistic as_of belongs ONLY in §7.2 step 5b's EXPLAIN timing sample.
-- ============================================================================
CREATE TABLE sbdev2777_before AS
SELECT sh.item_id, sv.item_nr, sv.client_id,
       sh.received, sh.returned, sh.adjustments, sh.historical_stock
  FROM stock_history('1970-01-01'::timestamptz) sh
  JOIN stock_view sv ON sv.item_id = sh.item_id;

-- ============================================================================
-- CHECK 2 (run AFTER the migration) — same capture, then the diff every later check uses.
-- ============================================================================
CREATE TABLE sbdev2777_after AS
SELECT sh.item_id, sv.item_nr, sv.client_id,
       sh.received, sh.returned, sh.adjustments, sh.historical_stock
  FROM stock_history('1970-01-01'::timestamptz) sh
  JOIN stock_view sv ON sv.item_id = sh.item_id;

CREATE VIEW sbdev2777_changed AS
SELECT b.item_id, b.item_nr, b.client_id,
       b.received     AS received_before,     a.received     AS received_after,
       b.returned     AS returned_before,     a.returned     AS returned_after,
       b.adjustments  AS adjustments_before,  a.adjustments  AS adjustments_after
  FROM sbdev2777_before b
  FULL JOIN sbdev2777_after a USING (item_id)
 WHERE (b.received, b.returned, b.adjustments)
       IS DISTINCT FROM (a.received, a.returned, a.adjustments)
    OR b.item_id IS NULL OR a.item_id IS NULL;   -- FULL JOIN also catches row add/drop

-- Row counts must be equal before and after. A difference means fan-out or row-drop —
-- the LEFT JOIN→JOIN slip, which no code-shape check can see.
SELECT (SELECT count(*) FROM sbdev2777_before) AS before_rows,
       (SELECT count(*) FROM sbdev2777_after)  AS after_rows;   -- must be equal

-- ============================================================================
-- CHECK 3 — ATTRIBUTION. Classify every changed row now that both fixes ship together.
--   Fix A moves a row iff its SKU has >1 distinct client_id.
--   Fix B moves a row iff its SKU carries (STOCK_REMOVED,STOCK_ALTERED)
--                                      or (MANUAL_REMOVAL,STOCK_ALTERED).
--   The sets OVERLAP, so classify and expect an EMPTY "neither" bucket. This is the
--   analytical replacement for the separate-apply attribution D1-R wanted (§10 D1-R2).
-- ============================================================================
WITH fix_a AS (SELECT itemdata FROM stockrecord GROUP BY itemdata HAVING count(DISTINCT client_id)>1),
     fix_b AS (SELECT DISTINCT itemdata FROM stockrecord
                WHERE (activitycode='STOCK_REMOVED'  AND type='STOCK_ALTERED')
                   OR (activitycode='MANUAL_REMOVAL' AND type='STOCK_ALTERED'))
SELECT CASE WHEN a.itemdata IS NOT NULL AND b.itemdata IS NOT NULL THEN 'both'
            WHEN a.itemdata IS NOT NULL THEN 'A-only'
            WHEN b.itemdata IS NOT NULL THEN 'B-only'
            ELSE 'NEITHER — investigate' END AS bucket, count(*)
  FROM sbdev2777_changed cr
  LEFT JOIN fix_a a ON a.itemdata = cr.item_nr
  LEFT JOIN fix_b b ON b.itemdata = cr.item_nr
 GROUP BY 1;
-- Expected: the changed set is a SUBSET of (Fix-A ∪ Fix-B) — "⊆", NOT "exactly", because a
-- census SKU with zero in-window stockrecords legitimately does not move. What must be
-- ZERO is the 'NEITHER' bucket.

-- ============================================================================
-- CHECK 4 — CONSERVATION INVARIANT. The strongest single Fix-A oracle: for each shared SKU,
--   the sum of per-client `received` AFTER must equal the single blind value captured
--   BEFORE. Proves Fix A *redistributed* rather than recomputed, and independently detects
--   fan-out and row-drop.
--   MUST exclude the Fix-B SKUs: Fix B legitimately changes the total, so conservation
--   holds only where Fix B is inert. Omitting this exclusion false-FAILs on ~2,894 SKUs.
-- ============================================================================
WITH fix_b AS (SELECT DISTINCT itemdata FROM stockrecord
                WHERE (activitycode='STOCK_REMOVED'  AND type='STOCK_ALTERED')
                   OR (activitycode='MANUAL_REMOVAL' AND type='STOCK_ALTERED'))
SELECT b.item_nr, max(b.received) AS blind_before, sum(a.received) AS sum_per_client_after
  FROM sbdev2777_before b
  JOIN sbdev2777_after  a USING (item_id)
 WHERE b.item_nr NOT IN (SELECT itemdata FROM fix_b)
 GROUP BY b.item_nr
HAVING max(b.received) IS DISTINCT FROM sum(a.received);
-- Expected: 0 rows.

-- ============================================================================
-- CHECK 5 — spot-check a known shared SKU end to end (DEV: 'PNRO23' → 1,074 / 7,248).
-- ============================================================================
SELECT sv.client_id, sh.item_nr, sh.received, sh.adjustments, sh.historical_stock
  FROM stock_history('1970-01-01'::timestamptz) sh
  JOIN stock_view sv ON sv.item_id = sh.item_id
 WHERE sh.item_nr = '<shared sku>';

-- ============================================================================
-- CHECK 6 — single-client SKUs with no Fix-B rows must be untouched.
-- ============================================================================
SELECT count(*) FROM sbdev2777_changed cr
 WHERE cr.item_nr IN (SELECT itemdata FROM stockrecord
                       GROUP BY itemdata HAVING count(DISTINCT client_id) = 1)
   AND cr.item_nr NOT IN (SELECT DISTINCT itemdata FROM stockrecord
                           WHERE (activitycode='STOCK_REMOVED'  AND type='STOCK_ALTERED')
                              OR (activitycode='MANUAL_REMOVAL' AND type='STOCK_ALTERED'));
-- Expected: 0.

-- Clean up when the evidence has been recorded:
-- DROP VIEW sbdev2777_changed; DROP TABLE sbdev2777_before, sbdev2777_after;
```

Also confirm the body actually landed and the signature did not move:

```sql
SELECT pg_get_function_identity_arguments(oid),
       md5(pg_get_functiondef(oid)),
       pg_get_functiondef(oid) LIKE '%sr.client_id%' AS has_client_id
  FROM pg_proc WHERE proname = 'stock_history';
```

### 8.4 Manual test plan

| Scenario | Environment | Steps | Expected result | Pass/Fail |
|---|---|---|---|---|
| Stock-history report for a shared SKU | DEV `dev_wh01_om1` | `GET /v3/stockView/search/…` (or the Warehouse Stock report screen) for a client holding `PNRO23` | Shows 1,074 for client 146701 — not 8,322 | |
| Transaction Summary for an affected client | DEV | Report screen → Transaction Summary → client 146701, range covering the movements | `beginning_inventory` / `ending_inventory` reflect that client only; `net_change` consistent | |
| Transaction Detail BEGINNING/ENDING rows | DEV | Report screen → Transaction Detail → client 146701, SKU `PNRO23` | BEGINNING and ENDING `total` are per-client | |
| Single-client SKU regression | DEV | A single-client SKU **with no Fix-B activitycode rows**, all three reports | Numbers **identical** to the pre-fix baseline. *(r1 omitted the Fix-B qualifier, which under bundling would have made this fail legitimately and look flaky)* | |
| Zero-overlap tenant | UAT `nywh/wh02_shipitez_v2` | Transaction Summary for any client, after **both** migrations | **No change whatsoever.** Verified valid in r2: this tenant measures **0 for Fix A and 0 for Fix B**, so it remains a true inertness control | |
| Fix-B magnitude sanity | UAT `wsl/wh01_om1_v2` | After `V2.2.07`, re-check the §8.3 capture and the §8.3 check-3 attribution buckets | ~2,894 SKUs move; `adjustments` swings ≈ −194,757, which **raises** `historical_stock`. A change of a different order of magnitude means something else moved | |
| Largest-delta tenant | UAT `wsl/wh01_om1_v2` | Spot-check 3 of the 135 affected SKUs | Each shows per-client figures | |

### 8.5 Post-implementation gate

Not complete until all four hold: (0) verify script `Result: N pass, 0 fail, **0 skip**`
pasted in the report — a skipped behavioural gate is a FAIL in r2, not a pass; (1) tests exist for every change — or the SBDEV-2217 blocker is stated
explicitly; (2) `mvn test` then `mvn verify` run, all green — and **confirm the new test actually
appears in `target/failsafe-reports/`** — specifically
`TEST-net.aim_ai.wms.integration.StockHistoryClientIsolationIntegrationTest.xml`.
**Not `surefire-reports`.** Surefire *excludes* `**/*IntegrationTest.java` (`pom.xml:448-451`)
and Failsafe *includes* it (`:565-568`), so the class runs under `mvn verify`, and its absence
from `surefire-reports` after `mvn test` is correct rather than a naming error. r2 had this
backwards, which would have pushed an implementer to rename the class back to `…IT` and
reintroduce the phantom-gate bug round 1 found.
**Baseline `mvn verify` before gating on it** — there are 33 `*IntegrationTest` classes, 14
`@Disabled`, so 19 that Failsafe will attempt. Without a pre-change baseline the "all green"
gate is unfalsifiable. Note 2 failures pre-exist on clean `develop` (`OptionalSafetyArchTest`,
`MobilePalletizingServiceTest`), and `mvn test` **mutates** the tracked `archunit_store`,
so `git checkout` it before committing;
(3) §11 filled in with SHAs, results, and per-tenant deltas.

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Report numbers change for affected SKUs; a client queries the shift | **High** (r2: re-rated from Medium once Fix B was measured at 2,894 SKUs / −194,757 on the largest tenant) — trust/support cost, possible restatement of a previously-issued report | Capture per-tenant before/after deltas (§8.3 step 1) so any number can be explained precisely. D4 (§10) leaves client comms with the requester |
| Quote-escaping error in the `EXECUTE` string body | High — function fails at call time, all three reports 500 | Copy the body verbatim from `pg_get_functiondef` and change only five lines; §9 verify script asserts the exact doubled-quote forms; DEV apply + smoke precedes UAT |
| Wrong migration version number (head moved) | Medium — out-of-order or duplicate version | Step 2 re-checks the head; note `V2.2.05` was renamed on 2026-07-30 |
| Applied to DEV while UAT still lacks `V2.2.05` | Low — divergent tenants, confusing status output | §7.1 makes the head check a prerequisite; the runbook's `--status` gate catches it |
| Performance regression from the extra GROUP BY / join key | Low | `client_id` is already in the aggregate's source rows; grouping by one more column on an already-grouped scan does not change the plan shape. Confirm with `EXPLAIN (ANALYZE)` on `wsl/wh01_om1_v2` (largest data set) before/after |
| Fix silently lost by a future UTC-style migration | Medium — regression with no error | §3 records the hazard; the follow-up (§10 D6) is to make pre-Phase-F diff the three function bodies rather than count them |
| Orphan `itemdata.client_id` ⇒ `sv.client_id IS NULL` ⇒ new predicate never true ⇒ figures silently COALESCE to 0 | Medium — "wrongly inflated" would become "silently zero", which is harder to spot | No FK exists (`itemdata.client_id` → `client(id)`) so it is possible in principle; **measured 0 on all 5 tenants 2026-07-30**. §7.1 keeps it as a per-tenant pre-flight |
| Phase-F replay on a newly-onboarded tenant reverts the fix | Low — real but already covered | **Covered by the existing post-Phase-F path**, not by anything this plan adds: the runbook has the operator backfill to `2.2.00` then `flyway migrate`, applying `V2.2.07` from `db/migration` **after** `V1.2.05`. r2 claimed this was "closed by mirrors" — those mirrors execute nowhere (§0 row 4), so that closure was false. Stated honestly here |
| Other v1 tenants still client_id-blind | Medium — v1 reports wrong for clients that never got the hand-fix | Out of scope by D5; **explicitly flagged for a separate ticket** — WineCo is the only v1 DB verified |

---

## 10. Open Questions / Resolved Decisions

### Resolved with the requester before drafting (2026-07-30)

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Bundle Fix A and Fix B? | ~~One migration, both~~ **REVERSED — see D1-R** | Superseded |
| ~~D1-R~~ | Bundle Fix A and Fix B? *(re-opened in r2 with measurements)* | ~~Unbundle~~ **superseded by D1-R2** | D1 was taken on the implicit premise that the two corrections were comparable in size. They are not, and I had not measured Fix B when I offered the choice. Fix B touches **2,894 SKUs / −194,757 adjustments** on the largest tenant vs Fix A's 135 — **~54×**. Fix B also moves numbers regardless of client count or SKU sharing, which invalidated three of r1's "unchanged"/"inert" oracles outright. Unbundling restores "unchanged" as a valid Fix-A oracle and forces Fix B to earn its own measured delta. Requester re-confirmed 2026-07-30 with the figures in hand |
| **D1-R2** | Bundle Fix A and Fix B? *(re-opened again in r3)* | **ONE migration — `V2.2.07`, both fixes** | D1-R unbundled to get separately-measured deltas. Round 2 showed that benefit is **unobtainable**: `apply-pending-tenant-flyway.sh` has no `-target` (zero occurrences), so one `--apply` applies everything pending and there is no sanctioned way to stop between the two. Attribution is instead analytical — both affected SKU sets are enumerable by SQL before the apply (§8.3 check #3), which works regardless of file count. The one genuine benefit unbundling *did* have (a failed second migration leaves the tenant at `2.2.07` with Fix A live) does not justify a file whose body never survives, and against it the two-file scheme cost 19 redundant verify checks. Requester approved the cut 2026-07-30 |
| D2 | Sysprop-gate the change? | **Unconditional** | The current numbers are wrong; no tenant benefits from keeping them. Gating a SQL function would need two bodies or a runtime branch — uglier than the fix. Precedent for gating (SBDEV-1666/1762) was *behaviour* change, not arithmetic correctness |
| D3 | Patch `V2.2.00` base dump too? | **No — rely on the delta** | `provision-fresh-v2-db.sh` applies `db/migration` in order, so a fresh DB ends up correct. Hand-editing a generated dump would desync it from its documented refresh procedure |
| D4 | Include v1/wms-api? | **v2 only** | WineCo's v1 DB already has the fix by hand, so its reports are correct today. **Caveat the requester should note:** other v1 tenants were never checked and are likely still blind — separate ticket |

### Open

| # | Question | Owner | Blocking? |
|---|---|---|---|
| D5 | The Java port plan `260420-v2-port-plpgsql-functions-to-java` (`status: reviewed`, unimplemented) must carry the `client_id` predicate when it lands, or it will reintroduce this bug. Add a note to that plan now, or handle at port time? | requester | no |
| D6 | Should pre-Phase-F migration checks diff the three report-function bodies (not just count functions), so a future UTC-style rewrite cannot silently discard a hand-fix again? Own ticket? | requester | no |
| D7 | Do any affected clients need a restatement of previously-issued reports, or is a forward-only correction acceptable? | requester / business | no — does not block the fix |
| D8 | No architecture or design doc currently covers these three report functions. Worth a `wms-design-doc` for the reporting subsystem? | requester | no |
| D9 | **27 `*IT.java` files in this repo never execute** — Surefire's excludes and Failsafe's overriding `<includes>` both miss the pattern (§8.2). Separate ticket to either rename them or fix the Failsafe config? | requester | no — but it means "integration coverage" repo-wide is overstated by 27 classes |

---

## 11. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1.1–1.3 — live read-only on `dev_wh01_om1`, `wh01_om1` and all 4 UAT tenants. Fix A defect reproduced (`PNRO23` 8,322 vs 1,074/7,248) and the corrected aggregation pre-validated inline. **r2 correction:** in r1 this row was half-true — Fix B was justified only by grepping sibling bodies and was never numerically measured. r2 measures it fleet-wide (§1.2), plus function ownership and NULL-`client_id` counts on all 5. `db_verified: true` now covers both fixes |
| 1 | **All callsites enumerated** | ✓ §0 — 14 rows; #1–#2 fixed, #3–#5 and #13–#14 excluded with rationale, #6–#12 verification-only (no edit needed, signature unmoved) |
| 2 | **Adjacent bugs** | ✓ §2 Bug 2 — found by grepping the sibling bodies for the same activitycode pairs. §0 #13 records the `all_shipped` subquery checked and found already client-safe |
| 3 | **Backward compatibility** | ✓ §5 — signature and `RETURNS TABLE` unchanged; `StockHistoryView` projection and all 5 call sites untouched. Output *values* change by design (§9 risk row 1) |
| 4 | **Concurrency** | ✓ no — `CREATE OR REPLACE` on a function is atomic and the function is read-only; no locks, no races, no retry semantics involved |
| 5 | **Multi-tenant** | ✓ §1.2, §7.2 steps 4/9 — per-tenant migration via the runbook; per-tenant deltas captured; the fix *is* a tenant-data-correctness fix and every query stays within one tenant DB |
| 6 | **Error handling** | ✓ no new throw path — the change is arithmetic within one query. The one new failure mode (bad quote escaping) is a deploy-time break caught on DEV before UAT (§9 risk row 2) |
| 7 | **Observability** | ✓ **revised in r2.** No runtime metric is warranted — the fix removes wrong output rather than adding a failure mode to count. But r1 then parked the only *recurrence* control in a non-blocking open question (D6), which is too weak for client-visible numbers given §3 documents that this exact loss has already happened once. r3 specified **one** durable assertion: an executable check that `pg_get_functiondef('public.stock_history')` contains the `client_id` predicate. **r4 note: r3 only *described* it — it was in neither §8.2's method table nor the written test, so the row overclaimed.** It now exists as `stockHistoryBodyRetainsClientIdPredicate` (§8.2), asserting the body Postgres resolves *after the full `db/migration` chain runs*, which is the non-tautological form: it fails if a later migration replaces the function from a stale body, the failure mode §3 documents as already having happened once. (r2 claimed a second assertion, the onboarding mirrors; those execute nowhere and are removed — §0 row 4.) That converts D6 from a hope into a gate |
| 8 | **Rollback / migration** | ✓ §5 Fix C, §7.1 — new `V2.2.07`, `CREATE OR REPLACE` (no DROP), idempotent, re-runnable. Rollback is a forward migration restoring the old body; no data to unwind since nothing is stored |
| 9 | **Test coverage** | ✓ §8.2 — **11** named IT methods, all passing (r3 cut 4 that could not fail or were redundant; r4 added the recurrence gate). §8.1 records why no unit test; §8.4 six manual scenarios. SBDEV-2217 confirmed inapplicable in practice, not just in theory — the suite runs green under `mvn test` |
| 10 | **Cross-version (v1↔v2)** | ✓ no — v2 only by D4. v1's repo is behind its own live DB; other v1 tenants likely affected and flagged for a separate ticket (§9 last row) |

---

## 12. Horizontal Scalability Validation

v2 runs multiple replicas. Verdicts for this change:

| # | Concern | Verdict | Note |
|---|---|---|---|
| 1 | In-JVM state | **N/A** | No Java change; nothing cached in-process |
| 2 | Connection pool math | **N/A** | Same number of queries, same connections per request |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` involvement |
| 4 | Long transactions | **No** | Read-only report query; `streamStockCount` already wraps its stream in `@Transactional(readOnly = true)` and that is unchanged |
| 5 | Request affinity | **N/A** | Stateless report call |
| 6 | Retry / idempotency | **No** | Pure read; replay is harmless. The migration itself is idempotent (`CREATE OR REPLACE`) |
| 7 | Tenant context | **No** | Existing `TenantContext` routing unchanged; the fix operates inside a single tenant DB |
| 8 | Distributed lock correctness | **N/A** | No locks taken |
| 9 | Cache invalidation | **No — verified** | Resolved in r2 (was r1's one open implementation-time check). `CacheConfig.java:36-39` (Caffeine) and `:60-67` (Redis) declare exactly four caches — `sysprops`, `clients`, `locations`, `itemdata`; there is no report/stock cache, and `grep -rn 'Cacheable\|CacheEvict' src/main/java/net/aim_ai/wms/repo/` returns **zero** hits. Nothing to evict; replicas cannot serve stale numbers |
| 10 | External notifications | **N/A** | No HTTP or message send |

**r2: no rows need an implementation-time check.** Row 9 — r1's only open item — is
resolved to a verified No. Everything is inert because no Java executes differently.

---

## 13. v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | **N/A** — no new repository call or lazy-load path. Existing `streamAllBy` transaction contract untouched |
| 2 | Transaction manager | **N/A** — no new `@Transactional` |
| 3 | `@Transactional(readOnly=true)` | **N/A** — no new service method |
| 4 | Caffeine cache invalidation | **No — verified** | See §12 row 9. Closed in r2 |
| 5 | Jakarta namespace | **N/A** — no Java change |
| 6 | H2-compatible test SQL | **Yes** | PL/pgSQL + `EXECUTE` + `timestamptz` cannot run on H2 → §8.2 is Testcontainers-only, deliberately |
| 7 | `BaseControllerTest` for controller changes | **N/A** — no controller change; endpoints are Spring Data REST-generated |
| 8 | Micrometer metrics | **N/A** — no new failure mode to measure |

---

## 14. Acceptance

Machine-checkable acceptance script:
[`sbdocs/9-System/scripts/verify-SBDEV-2777-stock-history-client-id-blind-mis-aggregation.sh`](../../../9-System/scripts/verify-SBDEV-2777-stock-history-client-id-blind-mis-aggregation.sh)

Run with `PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api`. Final acceptance is
**`Result: N pass, 0 fail, 0 skip`**. Precisely what `0 skip` means: r2 **eliminated**
skips rather than counting them — an absent behavioural gate is now a FAIL, so the counter is
always zero and carries no independent signal. The load-bearing part is `0 fail`. r1 defined acceptance as
"`N pass, 0 fail`", a string the script never prints, and its exit test ignored `$SKIP`
entirely, so a run with the behavioural gate skipped exited 0 and read as success. That
was a P5 violation; r2 makes an absent or unrun integration test a **FAIL**.

The script proves **code shape only**. Acceptance additionally requires the §8.3
before/after capture per tenant, which is what actually proves the arithmetic moved — and
moved only where predicted.

> Per `[[negative-test-verify-scripts-before-trusting-them]]`: run the script against the
> pre-fix tree first and confirm it **fails**. A script that passes before the fix is
> proof of nothing.

---

## 15. Implementation Status

**MERGED to `develop` 2026-07-31 (PR #112, merge `7d9aee6`). NOT applied to any database.**

> The app does not run Flyway at runtime, so merging changes nothing operationally — every
> tenant still returns the blind numbers. `status` stays **`reviewed`**, not `implemented`,
> until the migration is actually applied and the §8.3 before/after capture is recorded.
> The two open acceptance criteria are the apply and the per-tenant delta capture.

| Item | State |
|---|---|
| `db/migration/V2.2.07__fix_stock_history_client_id_aggregation.sql` | **Written**, untracked. Body sourced from `pg_get_functiondef` on `dev_wh01_om1` per §7.2 step 2 and verified byte-identical to the shipped body apart from the five intended edits (all 52 line lengths match the live definition; the 5 edits were mechanically reversed and the result compared line-for-line) |
| `StockHistoryClientIsolationIntegrationTest` | **Written. 13/13 pass** — `Tests run: 13, Failures: 0, Errors: 0, Skipped: 0`. Container bumped `postgres:12` → **`postgres:16`** to match the 16.10 the tenants actually run (the 12 was inherited from `ReplenishmentMonitorViewSchemaIT`, a `*IT.java` file that never executes) |
| Full unit suite | `Tests run: 4556, Failures: 2, Errors: 0` — the 2 are exactly the known clean-`develop` baseline (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`). **No new failures.** Tracked `archunit_store` mutation reverted |
| Code review | **Opus code-reviewer, verdict COMMENT — 0 critical, 0 high**, 2 medium + 6 low. All 2 mediums and 4 of 6 lows fixed (see below); the reviewer independently byte-diffed the body, replayed the pre-fix body, mutation-tested two shape guards, and replayed the chain on PG16 |
| TDD gate (pre-fix run) | **Confirmed genuine.** Against the unfixed function, at the time of the 10-method suite: `Tests run: 10, Failures: 6, Errors: 0`. `Errors: 0` is the load-bearing part — it failed on assertions, not harness breakage, so the self-contained pattern really does clear SBDEV-2217. The 4 invariant guards (LEFT-JOIN preservation, fan-out, column count, as-of window) passed before *and* after, as they must. **At the final 13 methods the pre-fix body fails 9 of 13** (the r4 additions — decoy, historical-stock and recurrence-gate tests — all fail pre-fix too). The commit message and PR body cite the earlier figure of 6; stale but harmless |
| Verify script | **`Result: 28 pass, 0 fail, 0 skip`**. Negative-tested first per `[[negative-test-verify-scripts-before-trusting-them]]`: against the pre-fix tree it returned `6 pass, 3 fail, 0 skip` and **exit 1** |
| Surefire/Failsafe note | The script's `T1` runs `mvn test -Dtest=<class>`; Surefire's `-Dtest` **overrides** the `**/*IntegrationTest.java` exclude, so the class does execute and its report lands in `surefire-reports`. §8.5's `failsafe-reports` expectation applies to a plain `mvn verify` — both are correct, they are different invocations. `archunit_store` was not mutated (only this class ran) |
| Independent verification of the post-review fixes | **APPROVED** (Opus verifier, separate lane). Did not trust the green suite: rebuilt the fixture in its own `postgres:16` container, reproduced all 26 values, and **mutation-tested every new oracle** — dropping the Fix-B `type` qualifier gives `received` 7 → 1007 and `adjustments` 3 → 1003; sign-flipping `+ shipped` gives 640 → 240; pinning the join to client 9001 leaves *every* CA assertion passing and is caught **only** by the new CB ones. Also ran a deletion probe (removed every r4 fixture row) confirming all 20 pre-existing checks return bit-identical values, so the additions perturb nothing. Found 1 defect — a factually wrong comment claiming `stock_view` excludes locks 103/104/403/404 when it excludes only 405 and 2 — **fixed in `2a2dd14`** |
| Commit SHA / PR | `ee92337` + `2a2dd14` on `bugfix/SBDEV-2777-stock-history-client-id-aggregation` → **[PR #112](https://github.com/SiteBossInc/wms2-api/pull/112) MERGED into `develop` 2026-07-31**, merge commit `7d9aee6`. Both commits verified as ancestors of `develop` (no [[stacked-v2-pr-merge-order-orphan-trap]]) |
| ClickUp | SBDEV-2777 → **`on dev`**. The comment states explicitly that this means *code on `develop`*, **not** a live fix: the app does not run Flyway at runtime, so the DEV auto-deploy does not apply the migration and all 5 tenants still return the blind numbers |
| Runbook §6.1 watermark row | **DONE** — added `V2.2.07` (function-body shaped, both Fix-A and Fix-B clauses required) **and** `V2.2.06`, which was missing too. Probe validated against a live unfixed tenant: returns `false`, while a control pattern matching the *existing* `MANUAL_REMOVAL`/`STOCK_REMOVED` pair returns `true` — proving the quadruple-quote escaping matches rather than failing open |
| DEV apply + §8.3 before/after capture | _pending — requires tunnels; nothing has been applied to any tenant_ |
| EXPLAIN gate (§7.2 step 5b) | _pending_ |
| Baseline `mvn verify` (§8.5) | _pending_ |
| Runbook §6.1 watermark row (§7.2 step 10) | _pending_ |

**Two defects were found by executing the plan rather than reading it**, both in the test
scaffolding and neither in the fix:

1. **The IT contradicted itself.** The Fix-B rows were seeded onto the same `(CLIENT_A,
   SHARED_SKU)` cell the Fix-A assertions measure, so `received` was asserted as both 100 and
   107 and `adjustments` as both 5 and 8 — two tests that could never pass together once both
   fixes shipped in one migration. Fix B moved to its own two-client SKU; see §8.2's r4 callout.
   This is the same Fix-A/Fix-B entanglement §10 D1-R identified, resurfacing inside the fixture
   after D1-R2 re-bundled the migrations.
2. **§11 row 7's recurrence gate did not exist** — it was described in prose but present in
   neither §8.2 nor the code. Now implemented and passing.

Both are consistent with §16's closing observation: every defect found across all rounds has
been in the scaffolding, never in the fix.

### Code-review findings and their disposition (r4)

Verdict **COMMENT — 0 critical, 0 high.** The reviewer executed rather than read: byte-diffed the
new body against `V2.2.00:39-89`, replayed the *pre-fix* body into a live DB to confirm the test
genuinely fails, mutation-tested both shape guards, replayed the whole chain on PG16, and
confirmed all three reachable tenants carry a body byte-identical to the base dump (so
`CREATE OR REPLACE` provably clobbers no hand-fix).

| Finding | Sev | Disposition |
|---|---|---|
| **Fix-B's `type` qualifier had no oracle** — dropping it (counting bare `STOCK_REMOVED` / `MANUAL_REMOVAL`) passed all 11 tests, yet on real data would fold `STOCK_CREATED`/`STOCK_TRANSFERRED` into `received` and re-diverge from the siblings Fix B exists to match | MEDIUM | **FIXED + PROVEN.** Three decoy rows added to `FIXB_SKU` (`STOCK_REMOVED/STOCK_CREATED`, `MANUAL_REMOVAL/STOCK_TRANSFERRED`, `PICKING/STOCK_CREATED`, all amount 1000) plus `stockHistoryIgnoresFixBDecoyRows`. **Re-ran the reviewer's exact mutation: it now fails 2 tests** (`expected: 7 but was: 1007`) where it previously passed all 11 |
| **`shipped` and `total_stock_today` were 0 in every fixture row** — 2 of the 7 preserved columns never exercised, `all_shipped` never ran with a match, and `historical_stock` only ever validated at zero where a dropped or sign-flipped term is invisible | MEDIUM | **FIXED.** New `STOCKED_SKU` (two-client) with seeded `unitload` + `stockunit` + CLOSED `billoflading_position`; `stockHistoryDerivesHistoricalStockPerClient` asserts `total_stock_today`, `shipped` and `historical_stock` for both clients (A: 500/200/**640**, B: 70/5/**66**). The reviewer's cheaper fallback was not needed — `unitload_type` id 0 and `location` id 0 are both base-dump seeded |
| Header claimed five lines "marked SBDEV-2777" that do not exist; adding such markers would be a **trap** (they sit inside the `EXECUTE` string and would enter the function body) | LOW | **FIXED** — header now enumerates the five line numbers and explicitly forbids inline markers |
| No statement terminator, unlike all six sibling migrations | LOW | **FIXED** — `$function$;` |
| Sibling-propagation tests asserted only client `CA`; an implementation binding every row to the first client would pass | LOW | **FIXED** — both now assert `CA = −115` **and** `CB = −922` |
| Test container `postgres:12` vs tenants on 16.10 | LOW | **FIXED** — bumped to `postgres:16` (reviewer had already verified the chain applies there) |
| **Plan §5 wrongly claimed `itemdata.client_id` has no FK to `client(id)`** — `V2.2.00:5434` defines one, and it is live | LOW | **FIXED** — §5 corrected with a callout. Error was in the safe direction (NULL `client_id` is structurally impossible, not merely measured-zero), but left standing it invites a defensive `coalesce` that would reintroduce the blindness |
| `stockHistoryBodyRetainsClientIdPredicate` is a whitespace-exact match, so a semantically identical reformat false-FAILs | LOW | **ACCEPTED AS-IS** — the reviewer judged this acceptable for its stated purpose (stale-DROP+CREATE detection); the behavioural tests carry the semantics |
| Orphan `(itemdata, client_id)` stockrecord pairs vanish post-fix, so a cross-client total can legitimately *decrease* with no reconciliation trail | LOW (open q) | **PROBE ADDED** to §7.1 pre-flight; measured 0 on `wms2-wineco-dev` |
| `mvn verify` may never reach this class on `develop` (Surefire's 2 known failures abort before Failsafe) | MEDIUM (low conf) | **CONFIRMED REAL, and it is why the verify script's `T1` uses `mvn test -Dtest=<class>`** — Surefire's `-Dtest` overrides the `*IntegrationTest` exclude, so the class runs and reports to `surefire-reports`. §8.5's `failsafe-reports` expectation applies only to a plain `mvn verify`. CI reaching this class is a **pre-existing repo-wide problem** (the 2 baseline failures), not something this PR introduces — flagged, not silently absorbed |

---

## 16. Review log

### Round 1 — ralplan consensus, 2026-07-30

Architect and Critic ran sequentially. **Critic verdict: ITERATE**, 6 blockers. All applied
in r2. Every source-level claim below was independently re-verified before being accepted.

| Finding | Who | Severity | Disposition in r2 |
|---|---|---|---|
| Fix B is ~54× Fix A and was never measured; it breaks three "unchanged"/"inert" oracles | Critic | Blocker | D1 re-opened and **reversed** — unbundled into `V2.2.07` / `V2.2.08`. §1.2 publishes both radii; measured fleet-wide |
| §8.3 check #1 was a phantom gate — aggregated `stockrecord` against itself, never called `stock_history`, same answer before and after | Critic | Blocker | Replaced with a real before/after capture of the function's own output |
| All 27 `*IT.java` files never execute (Surefire excludes / Failsafe `<includes>` override) | Critic | Blocker | Test renamed `…IntegrationTest`; §8.5 now requires confirming it appears in surefire-reports; orphaned ITs → D9 |
| Default IT harness scans only `db/v1-to-v2-onboarding/schema`, so §8.2 could never see the fix | Architect | Blocker | Self-contained container pattern adopted; SBDEV-2217 caveat removed as inapplicable |
| Verify script exits 0 with the behavioural gate skipped; §14's acceptance string is one the script never prints | Critic | Blocker | Skip is now a FAIL; §14 requires `0 skip` |
| `mvn -q` suppresses the INFO lines carrying `BUILD SUCCESS` and `Tests run:` → guaranteed false-FAIL | Architect | Blocker | `mvn_test_passes` rewritten |
| `myanswer` positional binding — adding a column there is a runtime failure on every report, and all 21 r1 checks passed | Architect | High | Landmine callout in §5 + regex guard + behavioural column-count test |
| §0 row 4 wrongly excluded — `V1.2.05` is a live onboarding path, so Phase-F silently reverts the fix | Architect | High | Exclusion overturned. **Architect's remedy (patch `V1.2.05`) rejected** on P3 grounds; Critic's mirrored-delta pattern (`V2.1.17` precedent) adopted instead |
| Verify script: `LEFT JOIN`→`JOIN`, dropped `WHERE sr.created > $1`, swapped B1/B2 pairs, dropped `RETURN`/`CYCLE_COUNT`/`MANAGE_INVENTORY` branches, vacuous negatives on a glob miss, no version-collision check — all score `21 pass, 0 fail` | Critic | High | All added to the script |
| `returned` per client untested — a third of Fix A unverified | Critic | High | Test added, plus 5 more (LEFT-JOIN preservation, fan-out, column count, as-of window, conservation invariant) |
| Cache question (r1's one open item) | Architect | — | **Resolved No** — 4 caches only, 0 `@Cacheable` in `repo/` |
| `itemdata UNIQUE (client_id, item_nr)` makes the join PK-equivalent; both `client_id` columns `NOT NULL` | Architect | — | Added to §5 as the correctness proof; settles the single-client question from schema |
| Function ownership prerequisite | both | Medium | **Measured clean on all 5**; kept as a pre-flight |
| Orphan/NULL `client_id` could silently zero figures | Critic | Medium | **Measured 0 on all 5**; pre-flight probes added; risk row added |
| EXPLAIN should be a hard gate, criterion "aggregate node type unchanged" | both | Medium | Adopted as step 5b |
| Runbook §6.1 watermark probe rows missing | Architect | Medium | Step 10; must be function-body shaped, not the usual sysprop check |
| Pre-mortem missed the two highest-probability failures | Critic | — | Both were real and are now fixed rather than merely listed |

**Where the reviewers disagreed:** the `V1.2.05` remedy. The Architect wanted the file
patched; the Critic showed it breaks no checksum but rewrites the historical record of
what five production-lineage databases received, and pointed at the existing byte-identical
mirror convention. The Critic's route satisfies all five principles; the Architect's
trades P3 for no additional benefit. **Critic's route adopted.**

**What survived unchanged:** the root-cause diagnosis, Fix A's design, the `CREATE OR
REPLACE`-without-`DROP` choice, the zero-Java-change claim, and §0 rows 3, 5, 13, 14.
The review changed what this plan *measures and gates on*, not what it *does*.

### Round 2 — Architect ran; loop stopped by the requester, 2026-07-30

**Architect verdict: ITERATE**, 2 blockers, 4 high, 3 medium. **Both blockers were defects r2
itself introduced.** The Critic pass was stood down: the requester chose to take the cut
recommendations and spend the remaining effort on the TDD gate rather than a fourth document
round. Every finding below was independently re-verified from source before being applied.

| Finding | Severity | Disposition in r3 |
|---|---|---|
| **The `V2.1.18`/`V2.1.19` mirrors are dead files** — `04-schema-bridge.sh:21-36` runs a hard-coded list ending at `V2.1.16`; zero `V2.1.17` references anywhere in the toolkit; Phase C precedes Phase F so a mirror would be reverted by `V1.2.05` anyway; the chain is psql-applied, not Flyway-sorted | **Blocker** | **Both files dropped.** §0 row 4 exclusion restored with the correct rationale. r2's "closed by mirrors" risk row corrected to "already covered by the post-Phase-F `db/migration` path" |
| **Unbundling delivers nothing operationally** — `apply-pending-tenant-flyway.sh` has zero `-target` occurrences, so one `--apply` applies all pending and there is no sanctioned way to stop between `V2.2.07` and `V2.2.08` | **Blocker** | **Collapsed to one migration** (D1-R2). Attribution moved to §8.3 check 3, which classifies changed rows by SKU set and works regardless of file count |
| §8.5 told the implementer to confirm the test in `surefire-reports` — but Surefire *excludes* `*IntegrationTest` and Failsafe includes it, so it lands in `failsafe-reports` under `mvn verify`. As written it would read a correct absence as a naming error and argue for renaming back to `…IT` | High | Corrected to `failsafe-reports` + `mvn verify`, with the named XML artefact |
| §9 still carried an "@Disabled with a TODO" row contradicting §8.2, §8.5, §14 and the script | High | Row deleted |
| §8.3 said "realistic `as_of`, not epoch", but the §1.2 census has no `created` filter while `stock_history` does — so the stated expectation failed by construction. Also "exactly the §1.2 SKUs" should be "⊆" | High | Epoch mandated for the capture, realistic only for 5b's EXPLAIN; expectation restated as a subset; conservation invariant added as check 2b |
| Stale version numbers in the operational steps (`2.2.05 → 2.2.06`; DEV is at `2.2.06`) | Medium | Swept — `2.2.06 → 2.2.07`, UAT gate now `V2.2.05` + `V2.2.06` |
| `mvn verify` gated with no baseline (33 `*IntegrationTest`, 14 `@Disabled`, 19 attempted) | Medium | Baseline required before gating |
| §11 row 9 said 8 IT methods; §8.2 listed 14 | Medium | Reconciled at 10 |
| Fixture cost unbudgeted (~40 lines of hand-rolled JDBC) | Medium | Stated, with a shared `@BeforeAll` |
| Over-engineering: 19 of ~50 verify checks tested a body that never survives; `SingleClientUnchanged` cannot fail on a correct fix; 4 SQL files for a 5-line change | — | **Cuts taken in full** — 4 SQL files → 1, ~50 checks → ~26, 14 IT methods → 10 |

**What survived all three revisions unchanged:** the root-cause diagnosis, Fix A's design and
its `UNIQUE (client_id, item_nr)` correctness proof, `CREATE OR REPLACE` without `DROP`, the
zero-Java-change claim, §0 rows 3/5/13/14, the `myanswer` positional-binding landmine, and the
self-contained Testcontainers pattern. **Every defect found across both rounds was in the
scaffolding, never in the fix.**

### Honest note on this plan's history

Three revisions, two review rounds. Round 1 found that three of r1's four acceptance oracles
could not detect a wrong implementation and one could never execute. Round 2 found that r2's
response to that introduced two dead artefacts and a mis-aimed confirmation step. r3 is
therefore **smaller than r2**, not larger — the corrective action was subtraction. If a future
revision grows this plan again, that is the signal to stop and ask whether the addition has an
executing consumer.
