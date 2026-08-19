---
title: "SBDEV-2890 (v1) — transaction_detail() excludes every full-move unit-load pick: same defect as v2, live in production"
ticket: "SBDEV-2890"
ticket_url: "https://app.clickup.com/t/868kp3jpr"
type: "bugfix"
severity: "high"
priority: "high"
status: "reviewed"
project: ["wms-api"]
version: "v1"
requester: "nam.park@siteboss.net"
assignee: "Nam Park"
created: "2026-08-10"
updated: "2026-08-10"
revision: 1
db_verified: false
db_verified_note: >
  NOT verified against live data — DB MCP not connected in the authoring session.
  Acceptable because the root cause is provable from source: the predicate
  `sr.amount != 0` is deterministically false for every row the writer emits with
  `setAmount(BigDecimal.ZERO)` at StockrecordService.java:267. The implementer MUST run
  the §11 query against a v1 production/staging tenant before starting, to size the
  defect. Unlike the v2 plan, there is no specific reported tenant — v1 was not the
  subject of the ticket; this defect was found by cross-version analysis.
related:
  - "[[SBDEV-2890-transaction-detail-ul-picks-excluded]]"
tags:
  - plan
  - wms1
  - reporting
  - flyway
  - picking
  - cross-version
---

# SBDEV-2890 (v1) — `transaction_detail()` excludes every full-move unit-load pick

**Ticket:** [SBDEV-2890](https://app.clickup.com/t/868kp3jpr)
**Project:** wms-api (v1) | **Version:** v1 | **Type:** bugfix
**Priority:** high
**Status:** reviewed
**Date:** 2026-08-10

**Paired v2 plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-2890-transaction-detail-ul-picks-excluded.md` — **primary; gated first.**

---

## 0. Why this plan exists

SBDEV-2890 was reported against **v2** (OMS V2 → WMS V2, UAT, TESTTOTAL/NYWH). Cross-version analysis while fixing v2 established that **v1/wms-api carries the identical defect, and v1 is production.**

v1 is in fact where the defect *originated* — v2 inherited it when the v2 base schema was generated from a v1 snapshot. See §3.

**This plan was not requested by the ticket.** It is a cross-version finding. Confirm with the product owner whether v1 warrants its own ticket before implementing; the fix itself is one line and low-risk, but shipping to v1 production is a separate release decision from the v2/UAT fix.

---

## 1. Problem Statement

The v1 Detailed Transaction Report omits every **full-move (unit-load) pick**. Partial-move picks render correctly. Beginning and ending balances therefore cannot be reconciled against the movement rows between them, for any window, on any tenant.

No v1 user report is attached to this plan — the defect was found by source analysis. The impact statement is derived from behaviour, not from a reported incident. **§11 sizes it against real data before any work starts.**

Symptom precision matters here exactly as it does in v2: it is **not** "picks are missing", it is **"full-move UL picks are missing"**. See §2.3.

---

## 2. Root Cause Analysis

### 2.1 The defect

`transaction_detail()` admits picking rows at **`V1.1.08__wms_functions.sql:210`**:

```sql
       (sr.activitycode = ''PICKING'' AND (sr.type = ''STOCK_CREATED'' OR sr.type = ''STOCK_TRANSFERRED'') and sr.amount != 0) OR
```

The `and sr.amount != 0` binds to the **whole parenthesised type group**, while the same function values the two types from **different columns** at `V1.1.08:176-178`:

```sql
WHEN sr.activitycode = ''PICKING'' AND sr.type = ''STOCK_CREATED''     THEN sr.amount
WHEN sr.activitycode = ''PICKING'' AND sr.type = ''STOCK_TRANSFERRED'' THEN sr.amountstock
```

### 2.2 The writer proves the guard is always false

`StockrecordService.recordTransferStockUnit` (`StockrecordService.java:259`):

```java
rec.setAmount(BigDecimal.ZERO);              // :267
rec.setAmountstock(stockunit.getAmount());   // :268  <- the actual picked quantity
...
rec.setType(WmsConstants.StockRecordType.STOCK_TRANSFERRED);   // :288
rec.setActivitycode(activityCode);                             // :289  <- CODE_PICKING
```

`0 != 0` → false, for **every** full-move UL pick. The `THEN sr.amountstock` arm at `:178` is unreachable dead code.

The v1 and v2 writers are **identical, offset by 6 lines** — same fields, same order, same early-return.

### 2.3 PICKING-writing paths (v1 line numbers)

Structure verified as identical to v2:

| # | Path | v1 location | type | amount | amountstock | Visible now? | After fix |
|---|---|---|---|---|---|---|---|
| 1 | **Full move** | `StockunitBusinessService:238` → `:253` | `STOCK_TRANSFERRED` | **0** | picked qty | **NO — the bug** | **YES** |
| 2 | Placeholder SU | `SUBS:227` → `:235` `createStockUnit(…, ZERO, false, …)` | `STOCK_CREATED` | **0** | 0 | No (correct) | **No — stays suppressed** |
| 3 | **Partial move / merge** | `SUBS:274` `recordCreation` | `STOCK_CREATED` | picked qty | dest total | **YES — works today** | Yes (unchanged) |
| 4 | Partial move, source side | `SUBS:273` `recordRemoval` | `STOCK_REMOVED` | −qty | — | No — not in allow-list | No (unchanged) |
| 5 | sendToNirvana | `SUBS:330` | `STOCK_TRANSFERRED` | — | — | No — non-PICKING activity codes; SU zeroed first so `StockrecordService:260` early-returns | No (unchanged) |

Entry: `transferStockToUnitLoad` at `StockunitBusinessService:132`; full/partial split at `:227`/`:238`.

### 2.4 Corroborating divergence — Summary counts what Detailed cannot show

**Only `V1.0.03` and `V1.1.04` define `transaction_summary`; `V1.1.08` redefines `transaction_detail` only.** So the live summary is **`V1.1.04:367`**, and its `depleted_picked` arms are:

```sql
CASE WHEN sr.activitycode = ''PICKING'' AND sr.type = ''STOCK_CREATED''     THEN sr.amount        -- :417
     WHEN sr.activitycode = ''PICKING'' AND sr.type = ''STOCK_TRANSFERRED'' THEN sr.amountstock   -- :418
```

**No `!= 0` guard.** Identical asymmetry to v2: a UL pick counts in v1 Summary and is invisible in v1 Detailed. **AC-5 ports to v1 unchanged.**

---

## 3. The Regression Chain — v1 is where it started

| Commit | Date | Author | Effect |
|---|---|---|---|
| — | — | — | `V1.0.03:315` — `(PICKING AND sr.type = ''STOCK_CREATED'')` only. UL picks never included. **The original SBDEV-1319 bug.** |
| `f1b79c1` | 2025-04-23 | Leonardo Castro | `V1.1.04:210` — added `STOCK_TRANSFERRED`, **no amount guard**, plus the `amountstock` arm at `:417-418`. **The SBDEV-1319 fix.** |
| `4a0a26e` | 2026-04-15 | Leonardo Castro | `V1.26.28__wms_functions.sql` (362 insertions) re-created `transaction_detail` **with `and sr.amount != 0`**. **The regression** — re-broke SBDEV-1319. |
| `26cc07c` | 2026-05-05 | Nam Park | Renamed `V1.26.28` → `V1.1.08`. **Plain `git log` on the file shows only the rename — use `git log --follow`.** |
| — | — | — | v2 `V2.2.00` base schema inherited this already-broken body. |

**v1 has been silently broken since 2026-04-15.** No commit in either repo references SBDEV-1319, so whether its fix ever reached v1 production is unconfirmed — flagged as an open question in §10.3.

---

## 4. Architecture Overview

```
Mobile pick confirm
   │
   ▼
transferStockToUnitLoad                        StockunitBusinessService:132
   │
   ├── destinationStockUnit == null ──► FULL MOVE                     :238
   │        └─► recordTransferStockUnit                               :253
   │               └─► StockrecordService                             :259
   │                      amount      = 0                             :267   ◄── the zero that kills it
   │                      amountstock = picked qty                    :268
   │                      type        = STOCK_TRANSFERRED             :288
   │
   └── else ────────────────────────►  PARTIAL MOVE
            ├─► recordRemoval  (STOCK_REMOVED)                        :273
            └─► recordCreation (STOCK_CREATED, amount = qty)          :274   ◄── renders fine today

   placeholder SU: :227 ─► createStockUnit(…, ZERO, false, …)         :235

                              ▼  stockrecord table
   ┌──────────────────────────────────────────────────────────────────┐
   │ transaction_detail()    V1.1.08                                  │
   │   WHERE … PICKING AND (CREATED OR TRANSFERRED) AND amount != 0   │ :210 ◄── 0 != 0 → dropped
   │   VALUE  … TRANSFERRED THEN amountstock                          │ :178 ◄── unreachable
   ├──────────────────────────────────────────────────────────────────┤
   │ transaction_summary()   V1.1.04  (NOT redefined by V1.1.08)      │
   │   depleted_picked … TRANSFERRED THEN amountstock                 │ :418 ◄── live, no guard
   └──────────────────────────────────────────────────────────────────┘
```

### Key files

| File | Lines | Role |
|---|---|---|
| `src/main/resources/db/migration/V1.1.08__wms_functions.sql` | `210` | **The defect** |
| ″ | `176-178` | Value CASE — correct, unreachable for `STOCK_TRANSFERRED` |
| `src/main/resources/db/migration/V1.1.04__wms_functions.sql` | `367`, `417-418` | Live `transaction_summary`, unguarded — basis for AC-5 |
| ″ | `3`, `367` | Signature: `timestamp **without** time zone` |
| `src/main/java/net/aim_ai/wms/service/StockrecordService.java` | `259-303` | `recordTransferStockUnit` |
| ″ | `260` | Early-return when amount ≤ 0 — proves no phantom rows |
| `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` | `227`, `235`, `238`, `253`, `273`, `274`, `330` | Branch structure |

---

## 5. Fix Design

### Fix A — scope the amount guard to the type it describes

**New migration: `V1.26.32__fix_transaction_detail_ul_picks.sql`.**

> **⚠ Migration numbering in v1 is not what it looks like.** The tail of the sequence is the `V1.26.x` block, **not** `V1.1.x`:
> `… V1.1.08, V1.1.09__pick_path_direction.sql, V1.26.29__replenishment_monitor_view_flag_based_classification.sql, V1.26.30__replenishment_monitor_view_add_ro_id.sql, V1.26.31__trim_itemdata_item_nr_whitespace.sql`
>
> Flyway splits the version on `.` and compares each part **numerically**, not lexically: `V1.26.31` → `[1,26,31]` vs `V1.1.09` → `[1,1,9]`; the first parts tie, then `26 > 1`. So `V1.26.31` is unambiguously the highest.
>
> **Use `V1.26.32`.** Naming it `V1.1.10` would sort *before* the three `V1.26.x` migrations and be **rejected as out-of-order** on any already-migrated tenant unless `outOfOrder=true`. Do not do that. Note this contradicts the v1 `CLAUDE.md` guidance to "continue the V1.1.x sequence" — that guidance predates the V1.26.x block and is stale.

**Before** (`V1.1.08:210`):

```sql
       (sr.activitycode = ''PICKING'' AND (sr.type = ''STOCK_CREATED'' OR sr.type = ''STOCK_TRANSFERRED'') and sr.amount != 0) OR
```

**After:**

```sql
       (sr.activitycode = ''PICKING'' AND ((sr.type = ''STOCK_CREATED'' AND coalesce(sr.amount, 0) != 0)
                                        OR (sr.type = ''STOCK_TRANSFERRED'' AND coalesce(sr.amountstock, 0) != 0))) OR
```

Byte-identical to the v2 change.

### 5.1 Properties — same as v2, verified against v1 sources

1. **Placeholder row stays suppressed** — path 2 writes `STOCK_CREATED` with `amount = 0` (and `amountstock = 0`); fails both arms. AC-2.
2. **`coalesce` is a proven no-op**, not a semantic change: `NULL != 0` → `NULL` → excluded; `coalesce(NULL,0) != 0` → `false` → excluded. Retained for symmetry with the v2 fix so the two functions stay diffable.
3. **No phantom rows** — `StockrecordService:260` early-returns when amount ≤ 0, so every persisted `STOCK_TRANSFERRED` picking row has `amountstock > 0`.
4. **`CREATE OR REPLACE`, no `DROP`** — preserves OID, ownership and ACLs; no window where the function is absent.

### 5.2 v1-specific hazards

**Hazard 1 — the signature must match v1 exactly.** v1's report functions take `timestamp **without** time zone` (`V1.1.04:3`, `:367`); v2's take `timestamp **with** time zone` (`V2.2.08:36`). A `CREATE OR REPLACE` whose signature does not match the existing one **creates an overload instead of replacing** — leaving the broken function live and callable, with the fix sitting inertly beside it. **Do not copy the v2 signature.**

**Hazard 2 — copy the `V1.1.08` body, not `V1.1.04`.** `V1.1.08` is the current live definition. Copying `V1.1.04` would revert whatever else `4a0a26e` changed in that 362-line rewrite. Prove it with a one-hunk diff (§7.2 Step 3).

**Hazard 3 — no inline comment inside the `EXECUTE` string.** The changed line sits inside the single-quoted `EXECUTE` body; an inline `--` becomes part of the stored function and changes `pg_get_functiondef` output. Document the change in the file header instead.

**Hazard 4 — the test suffix.** See §8.1. In v1 the gate test **must** be named `…IT.java`; a `…IntegrationTest.java` file never executes.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `src/main/resources/db/migration/V1.26.32__fix_transaction_detail_ul_picks.sql` | **New** | `CREATE OR REPLACE FUNCTION transaction_detail(...)` with v1's `timestamp without time zone` signature; V1.1.08 body, picking WHERE arm rescoped. |
| `src/test/java/net/aim_ai/wms/service/TransactionDetailUlPickIT.java` | **New** | Testcontainers + Flyway regression test covering **AC-1 … AC-6, AC-8**. **Name must end `IT`** — see §8.1. Every test carries `SBDEV-2890` + its AC id (§8.3). |
| `src/test/java/net/aim_ai/wms/service/TransactionDetailAllowListStructuralIT.java` | **New** | **AC-9** — parses `pg_get_functiondef` from the Testcontainers DB and asserts allow-list ⊖ value-CASE is empty modulo the accepted-exclusion set. Separate file: it is a whole-function structural property, not a row-level fixture. |
| `src/test/java/net/aim_ai/wms/unit/service/StockunitBusinessServiceFullMoveInvariantUnitTest.java` | **New** | **AC-10** — full-move branch entered only when the whole stock unit moves. Plain Mockito unit test, **no container** — so it must NOT carry the `IT` suffix, or Surefire will exclude it (`pom.xml:541`) and it will never run. |
| `sbdocs/9-System/scripts/verify-SBDEV-2890-transaction-detail-ul-picks-excluded-v1.sh` | **New** | Machine-checkable acceptance for the v1 side. |

**No Java production code changes.**

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Prerequisite | Status | Notes |
|---|---|---|
| **Product sign-off** | **Blocking** | This is a cross-version finding, not a reported v1 incident. Confirm v1 is in scope and whether it needs its own ticket before shipping to production. |
| **v2 gated first** | Sequencing | The v2 plan is primary. Land and validate v2 before or alongside; do not let the two diverge. |
| **DB state** | Required before starting | Run §11 against a v1 tenant to size the defect. `db_verified: false`. |
| **Branch base** | **Blocking** | v1 local `develop` is **stale** (missing 2 migrations). `git fetch origin` and branch from `origin/develop`. |
| **Branch name** | — | `fix/SBDEV-2890-transaction-detail-ul-picks` (v1 convention uses `fix/`, per v1 `CLAUDE.md`). |
| **Migration number** | Re-confirm | `V1.26.32`; highest existing is `V1.26.31`. See §5 numbering note. |
| **Feature flags / sysprops / config** | N/A | None. |
| **Data migration** | N/A | DDL only; history becomes visible retroactively at query time. |
| **Deploy order** | Yes | Must reach every v1 tenant DB. |
| **External systems** | v1 OMS (PHP/ZF2) | No change required — it renders whatever the function returns. |

### 7.2 Steps

1. **Capture the FAIL baseline** with the v1 verify script.
2. **Run §11** and record the result.
3. **Create `V1.26.32`** by copying **`V1.1.08`** verbatim, changing **only** line 210, rewriting the header. Prove exactly one changed hunk by diff. **Verify the signature reads `timestamp without time zone`** (Hazard 1).
4. **Confirm no inline comment** inside the `EXECUTE` string.
5. **Write the three test classes** per §6 — `TransactionDetailUlPickIT` (AC-1…AC-6, AC-8), `TransactionDetailAllowListStructuralIT` (AC-9), `StockunitBusinessServiceFullMoveInvariantUnitTest` (AC-10, **no `IT` suffix**). Only **AC-1 and AC-5 are RED** pre-fix; everything else is a green-before-and-after guard (§8.3).
6. `mvn verify -Dit.test=TransactionDetailUlPickIT` → green.
7. **Regression:** full `mvn verify`. v1 has no existing `transaction_detail` test to re-run, so the burden falls on the new test plus the manual plan.
8. **Re-run the verify script** → `Result: N pass, 0 fail, 0 skip`.
9. **Manual verification** per §8.5.
10. **Update §13.**

---

## 8. Testing Plan

### 8.1 ⚠ v1 uses the OPPOSITE test-suffix convention to v2

| | v1/wms-api *(this plan)* | v2/wms2-api |
|---|---|---|
| Surefire **excludes** | `pom.xml:541` `**/*IT.java` | `pom.xml:450-451` `**/*IntegrationTest.java`, `**/*E2ETest.java` |
| Failsafe **includes** | `pom.xml:644` `**/*IT.java` | `pom.xml:567-568` same two patterns |
| Surefire **includes** | *(none declared — Maven defaults apply)* | *(none declared — Maven defaults apply)* |
| Test **must** be named | **`…IT.java`** | `…IntegrationTest.java` |
| A `…IntegrationTest.java` file | **runs under Surefire, in the wrong phase** | runs (Failsafe) |
| A `…IT.java` file | runs (Failsafe) | never runs |

Each Failsafe `<includes>` **overrides** the default rather than appending, so there is zero overlap between the two repos.

**How the v1 mistake actually manifests — it is not silence.** v1's Surefire block declares only `<excludes>**/*IT.java</excludes>` (`pom.xml:540-541`) and **no `<includes>`**, so Maven's defaults (`**/*Test.java`) still match a file named `…IntegrationTest.java`. Such a test would **execute under Surefire during `mvn test`**, outside Failsafe's pre/post-integration-test lifecycle — most likely erroring on Testcontainers lifecycle rather than passing. So the v1 failure mode is a **noisy misfire**, not the silent no-op that the same mistake causes in v2.

The naming rule is unchanged and non-negotiable: **`…IT.java` in v1.** Use `mvn verify`, not `mvn test`.

### 8.2 Harness — v1 starts from zero

**v1 has no `transaction_detail` or `transaction_summary` test at all.** There is no existing harness to copy, unlike v2.

- Build from the v1 precedent `src/test/java/net/aim_ai/wms/service/ReplenishGenerationTransactionBoundaryIT.java`.
- v1 **does** have Testcontainers (`pom.xml:392-406`).
- Prefer raw `PostgreSQLContainer` + Flyway over `classpath:db/migration` (mirroring the v2 harness rationale) rather than `AppPostgresDBSetupExtension`, so the test actually exercises the migration under change.
- **Mockito 3.3.3 — no `mockStatic()`** (v1 `CLAUDE.md`). Not expected to matter for a JDBC-level test, but do not reach for static mocking.
- **Fixture requirement: seed `created == modified`.** v1 has the same windowing divergence as v2 (detail on `modified`, summary on `created`), so AC-5 will be flaky otherwise.

### 8.3 Integration tests — `TransactionDetailUlPickIT`

Identical matrix to the v2 plan:

| AC | Seeded row | Assertion | Before | After |
|---|---|---|---|---|
| **AC-1** | `PICKING`/`STOCK_TRANSFERRED`, `amount=0`, `amountstock=12` | Row returned, `depleted_picked = 12`, `transaction_name = 'Picked'` | **RED** | GREEN |
| **AC-2** | `PICKING`/`STOCK_CREATED`, `amount=0`, `amountstock=0` | No row | GREEN | GREEN |
| **AC-3** | `PICKING`/`STOCK_CREATED`, `amount=5`, `amountstock=20` | Row, `depleted_picked = 5` | GREEN | GREEN |
| **AC-4** | `PICKING`/`STOCK_TRANSFERRED`, both NULL | No row; no NULL numeric output column | GREEN | GREEN |
| **AC-5** | Mixed incl. a UL pick, `created == modified` | **`depleted_picked` term only:** `SUM(transaction_detail.depleted_picked) == transaction_summary.depleted_picked` | **RED** | GREEN |
| **AC-8** | Mixed non-picking | `STOCK_RELOCATED` excluded; PUTAWAY/REPLENISHMENT/DAMAGED totals unchanged | GREEN | GREEN |
| **AC-9** | *(structural)* | Every `activitycode`/`type` pair in a value CASE is admitted by the WHERE allow-list | **GREEN** — see correction below | GREEN — regression guard, not a gate |
| **AC-10** | *(Java-level)* | Full-move branch taken **only** when `amount == sourceStockunit.getAmount()` | GREEN | GREEN |

> **Test-annotation convention — required, enforced by the verify script.** Every test above must carry **both** `SBDEV-2890` **and** its AC id (`AC-1` … `AC-10`) in a `@DisplayName` or comment. AC ids are unique only within a ticket, so the script searches only files naming `SBDEV-2890`. A test omitting the ticket string reports FAIL.

**AC-5 is scoped to `depleted_picked` only — do not generalise it.** The two v1 functions use different row-admission models exactly as in v2 (summary admits-all-then-classifies; detail uses an allow-list), and several terms are not comparable by construction. The picking term reconciles because both sides value from the same columns and excluded rows contribute 0. See the v2 plan §8.3 for the full analysis. No reconciliation assertion of any kind exists in v1 today.

#### AC-9 — closes the bug class; specification

v1 carries the same sibling defect as v2: the `received` value CASE at `V1.1.08:158` classifies `STOCK_REMOVED` + `STOCK_ALTERED`, which the allow-list at `:199-202` never admits. Latent (no live writer emits that pair) but identical in shape to the picking bug.

**Implement exactly as the v2 plan §8.3 specifies** — the four decisions (source of truth, what counts as a value CASE, branch scope, wildcard rule) are settled there and are not repeated. Only the v1-specific coordinates differ:

| | v1 |
|---|---|
| Function to read | `pg_get_functiondef('public.transaction_detail(character varying, character varying, timestamp without time zone, timestamp without time zone)'::regprocedure)` — **note `without time zone`** |
| Sibling pair's value CASE | `V1.1.08:158` |
| Allow-list block | `V1.1.08:199-202` |
| Accepted exclusions | `Set.of(Pair.of("STOCK_REMOVED", "STOCK_ALTERED"))`, each entry requiring a plan reference |

**Two parser traps proven during the v2 gate run — v1 will hit both:**

1. **Anchor the allow-list on the TRIPLE paren** `(((sr.activitycode = ''RECEIVING'')`. The two-paren form occurs **twice** — once in the `received` value CASE, once opening the allow-list. Anchoring on the shorter form matches the value CASE first and yields an **empty** value region, making the whole assertion silently vacuous. This happened in v2 and was caught only because the test asserted its own parser sanity. Keep that sanity assertion.
2. **Do not split on `" UNION "`.** The source contains `\n UNION\n`, so that never matches and the subsequent region search lands in the wrong branch.

> **⚠ Correction — AC-9 is a regression guard, not a red-then-green gate.** An earlier revision claimed AC-9 would be RED pre-fix because "the picking pair is unadmitted". **That is wrong, and the v2 TDD gate proved it empirically: AC-9 passed on the unfixed build.** The picking pair is *syntactically present* in the pre-fix allow-list (`V1.1.08:210` names both types); the defect is that `and sr.amount != 0` makes the `STOCK_TRANSFERRED` arm **unreachable at runtime**, which no static set-difference can detect. Runtime reachability is what AC-1 and AC-5 prove. Keep AC-9 — just never read a green AC-9 as evidence the fix works.

**AC-10 pins the invariant AC-1 rests on.** `StockunitBusinessService:227` diverts to placeholder-creation when `sourceStockunit.getAmount().compareTo(amount) > 0 || fixLocationAssignment != null`, so the full-move branch at `:238` fires only when `amount == sourceStockunit.getAmount()` — the sole reason `amountstock` equals the picked quantity. All fixtures seed via raw JDBC, so without AC-10 a change to `:227` would make `transaction_detail` over-report picked quantity with every test still green.

> **AC-4 holds as written in v1 — keep it intact.** An earlier revision of this plan offered an escape hatch ("drop the NULL half if it fails pre-fix"). That was wrong on the facts and has been removed: a `PICKING` row matches no arm of v1's `received` CASE (`V1.1.08:155-158`) or `returned` CASE (`:189`), so it falls to `ELSE 0` — a literal, never NULL. Admitting UL picks introduces **no** new NULL exposure. The hatch was unnecessary and would have been a loophole capable of masking a genuine future failure.
>
> v1's separate, **pre-existing** NULL problem is real but orthogonal — see §10.6.

### 8.4 Regression tests

v1 has no existing coverage of these functions to re-run — that absence is itself a finding. Full `mvn verify` guards against unrelated breakage; correctness rests on §8.3 and the manual plan.

### 8.5 Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| 1 | UL picks appear | v1 staging | Run the Detailed Transaction Report for a client+window with known full-move UL picks | UL picking rows appear with non-zero quantity | |
| 2 | Reconciliation | v1 staging | Sum beginning + movement rows for one SKU | Equals ending quantity | |
| 3 | Detail ↔ Summary | v1 staging | Run both reports, same client+window | `depleted_picked` totals agree (they do not today) | |
| 4 | Partial-pick unchanged | v1 staging | Compare a partially-picked SKU before/after | Identical — no duplicate, no changed quantity | |
| 5 | No phantom zero rows | v1 staging | Scan for `Picked` rows with quantity 0 | None | |
| 6 | SQL before/after | Restored v1 snapshot | Run both functions pre- and post-migration | `sum(depleted_picked)` matches after, did not before | |
| 7 | Function not overloaded | v1 staging | `SELECT count(*) FROM pg_proc WHERE proname = 'transaction_detail';` | Exactly **1** — proves Hazard 1 avoided | |

### 8.6 Unit tests

**One, for AC-10.** The *fix* is entirely in-database, so no unit test covers the SQL change itself — coverage for that is integration-level by necessity, since v1 unit tests cannot exercise PL/pgSQL.

But AC-10 is a **Java** invariant and needs a Java home:

- `StockunitBusinessServiceFullMoveInvariantUnitTest` — assert the full-move branch (`:238`) is entered only when the whole stock unit moves, i.e. that `:227`'s divert condition (`getAmount().compareTo(amount) > 0 || fixLocationAssignment != null`) still routes every partial move away from it.
- **No `IT` suffix** — this is a plain Mockito test with no container. In v1, Surefire *excludes* `**/*IT.java` (`pom.xml:541`), so naming it `…IT.java` would stop it running under Surefire while Failsafe spun it up in the wrong phase.
- **Mockito 3.3.3 — no `mockStatic`** (v1 `CLAUDE.md`). Feasible here because the divert condition reads only from the passed `Stockunit` and the `fixLocationAssignment` lookup, both injectable through mocked repositories.

**Two setup traps proven while writing the v2 equivalent — v1 will hit both:**

1. **The `EntityManager` is field-injected** (`@PersistenceContext`). Constructor injection satisfies the collaborators, so Mockito **skips field injection entirely** and the field stays `null`, producing an NPE on `entityManager.refresh(...)` early in `transferStockToUnitLoad`. Set it explicitly with `ReflectionTestUtils.setField(service, "entityManager", entityManager)`.
2. **`createStockUnit` resolves the location with `findById`, not `findByIdForUpdate`.** Stubbing only the locking variant makes the *partial-move* case die with `EntityNotFoundException: Location not found`. Stub both.

This is the only Java test in the plan; everything else is integration-level.

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Signature mismatch creates an overload** | Broken function stays live; fix appears applied but changes nothing | §5.2 Hazard 1; manual scenario 7 asserts exactly one `pg_proc` row; verify script asserts `without time zone` |
| **Wrong migration number (`V1.1.10`)** | Out-of-order rejection on migrated tenants | §5 numbering note with the numeric-comparison rationale |
| **Copied from `V1.1.04` instead of `V1.1.08`** | Reverts the rest of `4a0a26e`'s 362-line rewrite | One-hunk diff mandated at §7.2 Step 3 |
| **Test named `…IntegrationTest.java`** | Never executes; green build proves nothing | §8.1; verify script asserts the suffix |
| **AC-4 fails pre-fix for unrelated reasons** | Scope creep into SBDEV-2801-equivalent work | §8.3 caveat — record as a separate v1 defect, do not expand this plan |
| **Shipping to v1 production without sign-off** | Unrequested production change | §7.1 blocking prerequisite |
| **v1 and v2 fixes diverge over time** | Same bug reappears in one repo only | Byte-identical predicate in both; shared plan base name; AC-5 in both |
| **Report returns more rows** | Longer render on UL-heavy tenants | Expected and correct; report was under-returning |
| **No existing test coverage to regress against** | Unrelated breakage could slip through | Full `mvn verify` + manual plan |

---

## 10. Open Questions / Resolved Decisions

### 10.1 Resolved — same scope exclusions as the v2 plan

OMS-side defects → **[SBDEV-2895](https://app.clickup.com/t/868kp5grd)** (v2 OMS only; the v1 OMS is a different PHP 5.6/ZF2 codebase and was **not** audited — see §10.4). The "~18 SKUs" complaint is **refuted, not deferred** (v2 plan §10.2); it is a data-population question. SBDEV-1232 stays separate.

### 10.2 Deferred — `sr.created` vs `sr.modified` windowing divergence

Present in v1 as in v2. Out of scope; drives the `created == modified` fixture requirement in §8.2.

### 10.3 Open — did SBDEV-1319's fix ever reach v1 production?

**No commit in either repo references SBDEV-1319.** `V1.1.04` (2025-04-23) contains the fix and `V1.26.28`/`V1.1.08` (2026-04-15) removed it, but whether `V1.1.04` was ever deployed to all tenants is unconfirmed. Determine this before writing release notes — it changes whether this is a *regression* users once saw fixed, or a defect that was only ever fixed in source.

### 10.4 Open — v1 OMS (PHP 5.6 / ZF2) was not audited

The four OMS defects in SBDEV-2895 were found in **v2's `oms-laravel-api`**. The v1 OMS is an entirely different codebase and was **not** examined for equivalents. Do not assume parity in either direction. Out of scope here; worth a separate look if v1 report completeness is ever questioned.

### 10.5 Deferred — latent `recordZeroAmount` defect

v1's `createStockUnit` should be checked for the same never-read `recordZeroAmount` parameter documented in the v2 plan §10.3 — where the real mechanism turned out to be **two write paths for `STOCK_CREATED`**, one guarded (`StockrecordService.recordCreation`) and one not (`createStockUnitCore`, which hand-rolls the record inline). **Not verified in v1.** Do not assert it in v1 without checking.

### 10.6 ⚠ Open — v1 never received SBDEV-2801's NULL hardening. Separate live defect.

Found while validating AC-4. **This is a production HTTP-500 class in v1 today, unrelated to the UL-pick fix but worth its own ticket.**

SBDEV-2801 hardened six NULL-producing expressions in **v2 only** (migration `V2.2.08`). v1's `transaction_detail` never got the equivalent, and its output columns are inconsistently guarded:

| Column | `V1.1.08` | NULL-safe? |
|---|---|---|
| `received` | `… ELSE 0 END)` — single-argument `coalesce`, a no-op | **No** — a NULL `sr.amount` propagates |
| `returned` | `… ELSE 0 END)` — same | **No** |
| `transfer` | bare CASE, no `coalesce` | **No** |
| `net_change` | bare CASE, no `coalesce` | **No** |
| `depleted_picked` | `… END, 0)` | Yes |

The failure mode is exactly SBDEV-2801's: `stockrecord.amount` is nullable, the `RECEIVING`/`RETURN` allow-list arms carry no type qualifier, and writers that populate only `amountstock` (e.g. `recordCounting`'s `STOCK_COUNTED` rows, and v1-era history) enter the report with `amount` NULL. If the Java mapper unboxes those columns, one NULL row turns the whole report into an opaque 500 for that window.

**Explicitly NOT fixed by this plan** — it is a different defect with a different blast radius, and bundling it would make an urgent one-line fix into a six-expression rewrite. **Recommend its own ticket: "port SBDEV-2801 NULL-hardening to v1".**

**Note for sequencing:** if that ticket is done first, it will produce a new v1 migration and this plan's `V1.26.32` may need renumbering. Coordinate.

---

## 11. Verification query — run BEFORE starting

`db_verified: false`. Run against a representative **v1 tenant** DB:

```sql
-- Expect NON-ZERO. These are the full-move UL picks currently invisible in v1's Detailed report.
SELECT count(*) FROM stockrecord sr
  JOIN client c ON sr.client_id = c.id
 WHERE sr.activitycode = 'PICKING'
   AND sr.type = 'STOCK_TRANSFERRED'
   AND sr.modified > now() - interval '90 days';
-- Result: ____________
```

Non-zero ⇒ defect confirmed live and sized on v1, and §7.1's product sign-off conversation has a number attached to it.

---

## 12. Horizontal scalability validation

v1 `CLAUDE.md` does not mandate this section (it is a v2 requirement), but the two rows that matter are recorded for parity with the v2 plan:

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 7 | Flyway concurrency on multi-instance startup | **Yes — no new mitigation** | Advisory lock on `flyway_schema_history` serialises replicas; `CREATE OR REPLACE` is idempotent |
| 10 | Result-set size | **Yes — note only** | Report was under-returning; will now return more rows. Not a regression |
| 1-6, 8, 9 | In-JVM state, pool math, scheduled jobs, long transactions, request affinity, retry/idempotency, distributed locks, cache invalidation | **N/A** | No Java change; no bean, transaction, lock, cache or scheduled job touched |

**v1-specific constraints** (per v1 `CLAUDE.md`): no JPA associations touched; no entity `.equals()` comparison involved; Mockito 3.3.3 limitation noted in §8.2; no `/rest/**` endpoint modified.

---

## 13. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | **no — `db_verified: false`.** Root cause provable from source (`StockrecordService:267` writes ZERO; predicate is deterministically false). §11 gives the sizing query the implementer must run first. |
| 1 | All callsites enumerated | ✓ §2.3 — all five PICKING paths. **v1 `!= 0` sweep: 52 hits across three files** (`V1.0.03`=17, `V1.1.04`=17, `V1.1.08`=18). **Exactly one is the defective picking-predicate form** (`V1.1.08:210`); the other 17 in that file are the `tr.<column> != 0` label-picker family (cosmetic row labelling, no row-visibility effect), and `V1.0.03`/`V1.1.04` are superseded at runtime by `V1.1.08` |
| 2 | Adjacent bugs | ✓ No sibling **guard** of the `!= 0` form in v1 — but v1 **does** carry the same sibling instance of the bug *class* as v2: the `received` value CASE at `V1.1.08:158` classifies `STOCK_REMOVED`+`STOCK_ALTERED`, which the allow-list at `:199-202` never admits. Latent (no live writer emits the pair), documented and excluded — see AC-9. Plus §10.5 (`recordZeroAmount`, recorded as unverified in v1 rather than asserted) and §10.6 (missing SBDEV-2801 NULL hardening) |
| 3 | Backward compatibility | ✓ §5.1.4 — signature preserved (Hazard 1 guards it); no Java/API change |
| 4 | Concurrency | ✓ §12 row 7 |
| 5 | Multi-tenant | ✓ §7.1 deploy order — must reach every v1 tenant DB |
| 6 | Error handling | ✓ No new throw path. §8.3 caveat flags that v1 lacks SBDEV-2801's NULL hardening — recorded, not silently absorbed |
| 7 | Observability | no — no new failure mode; v1 has no metrics stack comparable to v2's |
| 8 | Rollback / migration | ✓ §5 numbering note; rollback = re-apply the V1.1.08 body as a new migration. No data written |
| 9 | Test coverage | ✓ §8.3 integration, §8.5 manual. §8.4 records the absence of existing coverage as a finding |
| 10 | Cross-version (v1↔v2) | ✓ This **is** the cross-version plan. v2 primary and gated first; §14 |

---

## 14. Cross-version pairing

| | v1/wms-api *(this plan)* | v2/wms2-api *(primary)* |
|---|---|---|
| Broken predicate | `V1.1.08:210` | `V2.2.08:242` |
| Value CASE arms | `V1.1.08:176-178` | `V2.2.08:208-210` |
| Live `transaction_summary` | `V1.1.04:367`, arms `:417-418` | `V2.2.00:460`, arms `:509-510` |
| Writer | `StockrecordService:259` → `:267`, `:268`, `:288` | `:265` → `:272`, `:273`, `:293` |
| Early-return guard | `:260` | `:266` |
| Branch structure | `:227`/`:235`, `:238`→`:253`, `:273`/`:274`, `:330` | `:336-342`, `:345`→`:360`, `:369`/`:376`/`:377`, `:425` |
| New migration | **`V1.26.32`** | **`V2.2.12`** |
| Timestamp type | `without time zone` | `with time zone` |
| Gate test name | **`TransactionDetailUlPickIT.java`** | `TransactionDetailUlPickIntegrationTest.java` |
| Existing harness | **None** | `TransactionDetailNullAmountIntegrationTest` |
| NULL hardening (SBDEV-2801) | **Absent** — see §8.3 caveat | Present (V2.2.08) |
| TDD gate | **Pending** | Gated first |

The predicate change is byte-identical in both repos. Keep it that way — divergence is how this bug survives a third time.

---

## 15. Acceptance

**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2890-transaction-detail-ul-picks-excluded-v1.sh`

Run **before** (must FAIL) and **after** (must report `Result: N pass, 0 fail, 0 skip`). Paste that line in the completion report.

**Recorded baseline — validated against three trees:**

| Tree | Result | Meaning |
|---|---|---|
| Current `origin/develop` (pre-fix) | `2 pass, 27 fail, 0 skip` | Both passes are legitimate absence assertions (no wrong-suffix twin, no stray `V1.1.1x` migration) |
| Correct fix | `18 pass, 11 fail` — **zero** S/A/V/H failures | Remaining failures are test-file checks, expected until the gate writes them |
| **Correct body, but signature drops `sku_in`** | `17 pass, 12 fail` — **S5 FAILS** | The overload trap is caught |

That third row is v1's most dangerous failure mode: `CREATE OR REPLACE` with a mismatched signature creates a **second** function instead of replacing, leaving the broken one live and callable while the fix sits inertly beside it. An earlier revision of this script used a loose `transaction_detail\(.*timestamp without time zone.*\)` regex that **passed** on that fixture. The signature is now pinned verbatim from `V1.1.08:3`. Manual scenario 7 (`pg_proc` count) is the runtime confirmation of the same property.

Code shape only. Full acceptance also requires `mvn verify` green in `v1/wms-api`, the §8.5 manual plan (scenarios 1–3 and **7** at minimum — 7 proves the overload hazard was avoided), and the §11 query recorded.

---

## 16. Implementation Status

*Not yet implemented. Blocked on §7.1 product sign-off.*

- [ ] Product sign-off that v1 is in scope
- [ ] §11 query run; result recorded
- [ ] Verify-script FAIL baseline captured
- [ ] `V1.26.32` created; one-hunk diff proven; signature confirmed `without time zone`
- [ ] `TransactionDetailUlPickIT` RED on AC-1 + AC-5 pre-fix
- [ ] Migration applied; ACs green (AC-4 per §8.3 caveat)
- [ ] Full `mvn verify` green
- [ ] Verify script: `Result: __ pass, 0 fail, 0 skip`
- [ ] Manual plan §8.5 executed, incl. scenario 7
- [ ] Commit SHA(s): ____________
