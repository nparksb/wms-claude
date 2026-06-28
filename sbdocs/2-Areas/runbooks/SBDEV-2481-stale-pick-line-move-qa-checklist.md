---
title: "QA Checklist: Stale Pick-Line Realignment on Stock / Unit-Load Move (SBDEV-2481, WMS v1)"
type: qa-checklist
status: active
version: "wms-api v1 (Java 8, Spring Boot 2.3.7, PostgreSQL)"
scope: "v1/wms-api + wms-mobile-ui + wms-web-ui — verifying the SBDEV-2481 fix (block/realign pick lines when stock or a unit load moves)"
owner: "nam.park@siteboss.net"
created: "2026-06-24"
updated: "2026-06-24"
last_verified: ""
verified_by: ""
ticket: "SBDEV-2481"
pr: "https://github.com/SiteBossInc/wms-api/pull/176"
related:
  - "[[SBDEV-2481-stale-pick-line-realignment-on-stock-move]]"
tags:
  - qa
  - picking
  - move-stock
  - regression
---

# QA Checklist — SBDEV-2481: Stale Pick-Line Realignment on Stock / Unit-Load Move

Verifies that picking line items no longer go stale when stock tied to released picking work is moved. The fix keys off the **owning `Pickingorder`'s state**: a **not-started** group's pick lines are **realigned** to the new location; an **active** group **blocks** the move with a clear message.

> **Build under test:** branch `task/SBDEV-2481` / [PR #176](https://github.com/SiteBossInc/wms-api/pull/176). Not on `develop` yet.

---

## 0. Prerequisites

1. **Deploy `task/SBDEV-2481`** to the test/UAT env (or run locally: `cd v1/wms-api && mvn spring-boot:run`).
2. **Migration `V1.26.30`** is applied to that env's DB (ships with the branch; Flyway runs it at startup). It adds `ro_id` to `replenishment_monitor_view` — unrelated to picking, but part of the branch.
3. Mobile UI (`:3001`) and Web UI (`:3000`) point at that API.
4. DB access (psql / DB MCP) to the tenant DB for verification.

---

## 1. Set up the two preconditions

You need one picking group of each state:

- **Not-started** → push parcels, release for picking, **don't open/start** the group. Owning `Pickingorder.state = PROCESSABLE (300)`. → expect **realign**.
- **Active** → same, then **open the group on the scanner and start a pick** (process one location). Owning `Pickingorder.state = STARTED (500)`. → expect **block**.

Find a candidate pick line + owning-order state:

```sql
SELECT pp.id AS pickline, pp.pickfromstockunit_id AS su, pp.pickfromlocationname AS stored_loc,
       po.id AS pickorder, po.state AS order_state, l.name AS actual_loc
FROM pickingorder_position pp
JOIN pickingorder po ON po.id = pp.pickingorder_id
JOIN stockunit su    ON su.id = pp.pickfromstockunit_id
JOIN unitload ul     ON ul.id = su.unitload_id
JOIN location l      ON l.id = ul.storagelocation_id
WHERE po.state < 700 AND po.state <> 800
ORDER BY po.state;   -- state 300 = realign candidates, state 500 = block candidates
```

State constants: `PROCESSABLE=300`, `RESERVED=400`, `STARTED=500`, `PICKED=600`, `FINISHED=700`, `CANCELED=800`.

---

## 2. Test matrix

For each row: record the pick line's `pickfromstockunit_id` and `pickfromlocationname` **before**, perform the move, then re-query (§3).

| # | Scenario | Action (UI) | Expected | Pass criteria | Pass/Fail |
|---|----------|-------------|----------|---------------|-----------|
| 1 | Fixed-assignment move, **not-started** | Admin → move the SKU's fixed location to a new flowbin | Move succeeds; pick line realigned | `pickfromlocationname` = new location; `pickfromstockunit_id` **unchanged** | |
| 2 | Fixed-assignment move, **active** | Same, owning order STARTED | **Blocked** — _"This stock is currently tied to active picking work. Please wait till picking is complete before moving this stock or changing its fixed assignment."_ (HTTP 422) | UL still at old location; pick line unchanged | |
| 3 | Mobile move-unit-load, **not-started** | Mobile `/move-unitload` → scan UL → new destination | Realigned | location string updated | |
| 4 | Mobile move-unit-load, **active** | Same, STARTED | Blocked with the message | no write committed | |
| 5 | Manual move-stock (web/mobile), **not-started** | `/move-stock` → source → destination | Realigned | location updated | |
| 6 | Manual move-stock (mobile), **active** | Same, STARTED | Blocked; **no partial write** | UL location unchanged | |
| 7 | Replenishment finish, **not-started** | Mobile `/replenish` → finish an order moving stock into the pick flowbin | Realigned (via stock-move hook) | location updated | |
| 8 | Send-to-nirvana | Trigger nirvana/delete on stock backing a pick line | **Blocked** — never strands the pick line | stock NOT moved to nirvana | |
| 9 | Concurrency | Start a pick on the group on device A **and** attempt the move on device B near-simultaneously | Exactly one proceeds; the other waits then blocks; no deadlock / 500 | no stale line afterward | |
| 10 | **Outbound pass-through (regression guard)** | Ship / truck-load / finish-pick a UL whose owning order is **active (500)** | **NOT blocked, NOT realigned** — shipping proceeds normally | pick-line strings untouched; no error | |
| 11 | **Manual split (regression guard)** | Split a stock unit (`CODE_MANUAL_SPLIT`) that backs a pick line | Split succeeds; existing pick line untouched | no block, no change | |

> **#10 and #11 are the highest-value regression checks.** They prove the guard does NOT touch outbound/split flows. **If shipping is ever blocked with the "active picking work" message, that is a bug — fail the build.**

---

## 3. SQL verification helpers

**Per-line: is the pick line aligned with its stock's real location?** (after scenarios 1, 3, 5, 7 → expect `aligned = true`)

```sql
SELECT pp.pickfromlocationname AS stored, l.name AS actual,
       (pp.pickfromlocationname = l.name) AS aligned,
       pp.pickfromunitloadlabel AS stored_label, ul.labelid AS actual_label
FROM pickingorder_position pp
JOIN stockunit su ON su.id = pp.pickfromstockunit_id
JOIN unitload ul  ON ul.id = su.unitload_id
JOIN location l   ON l.id = ul.storagelocation_id
WHERE pp.id = <pickline_id>;
```

**Whole-tenant staleness count** (detector SQL is fixed by this build):

```sql
SELECT getpickingorderpositioncount();   -- trends to 0 for not-started groups after moves
```

---

## 4. Acceptance gotchas (fail the test if any of these are wrong)

- **The block is HTTP 422 with the readable message** — NOT a generic 500. A 500 means the wrong exception type leaked; fail it.
- **`pickfromstockunit_id` must NEVER change** on a realign — only the location/label strings update. If the FK changes, fail it (data-integrity regression).
- **Outbound never blocked (#10)** — shipping/truck-load/finished-pick must flow even when the owning order is STARTED.
- **No partial write on a blocked move (#6, mobile)** — re-query confirms the UL location/label is unchanged after a block.

---

## 5. Out of scope for this build (do not fail the build on these)

- **Backfill of pre-existing stale rows** (the 15 not-started + 22 active observed before deploy) is a separate post-deploy step — see plan §7.3 runbook. This fix prevents *new* staleness; it does not retroactively clean old rows until the backfill runs.
- **`CODE_DAMAGED`** is intentionally pass-through (damaging stock that backs a pending pick is a separate follow-up ticket).
- **WMS v2** — this is the v1 fix only; the v2 port is pending (ticket tagged for both).

---

## 6. Sign-off

| Field | Value |
|-------|-------|
| Tester | |
| Env / build (tag) | |
| Date | |
| Result (pass/fail per row) | |
| Notes / defects raised | |
