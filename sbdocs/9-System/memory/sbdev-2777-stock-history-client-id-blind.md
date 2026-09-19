---
name: sbdev-2777-stock-history-client-id-blind
description: "v2 stock_history() aggregates/joins stockrecord by SKU string only, so shared SKUs report all-clients totals per client; V2.2.07 MERGED to develop 2026-07-31 (PR #112) but applied to NO database"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3f910dda-33b7-4623-a00b-7e0652f7b508
  modified: 2026-07-31T01:05:33.937Z
---

`public.stock_history(timestamptz)` on all 5 v2 tenants groups `stockrecord` by
`sr.itemdata` (the SKU **string**) and joins `received_recordset.itemdata = sv.item_nr`
with no `client_id` — so every client stocking a shared SKU gets the all-clients total for
`received`/`returned`/`adjustments`, and `historical_stock` derives from those. Proven on
`dev_wh01_om1`: `PNRO23` returns 8,322 for both clients 146701 and 512500; truth is
1,074 / 7,248. Fix B (separate defect, same function): omits
`(STOCK_REMOVED,STOCK_ALTERED)`→received and `(MANUAL_REMOVAL,STOCK_ALTERED)`→adjustments
that both sibling report functions already count — **~54× Fix A's blast radius**
(2,894 SKUs / −194,757 adjustments on `wsl/wh01_om1_v2`).

**Status 2026-07-31:** `V2.2.07` + a 13-method IT **MERGED to `develop`** via PR
[#112](https://github.com/SiteBossInc/wms2-api/pull/112) (merge `7d9aee6`; commits `ee92337` +
`2a2dd14`), ClickUp **"on dev"**. Verify script 28/0, IT 13/13.

**But the reports are STILL WRONG on all 5 tenants.** "on dev" means code on `develop`, not a
live fix — the app does not run Flyway at runtime, so the DEV auto-deploy does **not** apply the
migration. Don't test the reports on DEV and conclude the fix failed. Remaining operator work:
capture the pre-fix baseline FIRST (§8.3 check 1 — irrecoverable once applied), pre-flight
probes, apply to DEV, confirm `PNRO23` → 1,074 / 7,248, EXPLAIN gate, then UAT — which sits at
2.2.05 and **needs `V2.2.06` first**.

LANDMINES:
- **Surefire's `-Dtest=X` OVERRIDES the `**/*IntegrationTest.java` exclude** (`pom.xml:448-451`).
  `mvn test -Dtest=SomeIntegrationTest` really does run it, reporting to `surefire-reports`;
  a plain `mvn verify` runs it under Failsafe into `failsafe-reports`. Both correct — never
  rename a class based on which report directory it appears in. (Separately: 27 `*IT.java`
  files match neither plugin's patterns and **never execute**.)
- **Do NOT add `client_id` to the `myanswer` projection** — `RETURN QUERY` binds positionally
  through `SELECT *`; an 8th inner column is a *runtime* failure on every report.
- **Source the body from `pg_get_functiondef`, never a migration script** (`V1.2.05:48-56` uses
  multi-line `%TYPE` and fails verify `C5`).
- **Green tests are not evidence a new assertion is an oracle.** Both the reviewer and the
  verifier found real holes by *mutating the implementation* and checking the assertion fires.
  The Fix-B `type`-qualifier hole survived all 11 tests until decoy rows were added.
- **Two independent fixes in one migration must be tested on DISJOINT (client, SKU) cells**,
  or the assertions contradict each other (`received` asserted as both 100 and 107).
- `stock_view.total_stock` excludes entity_lock **405 and 2 only** — 103/104/403/404 are
  separate reporting buckets that still count toward the total.
- `itemdata.client_id` **does** have an FK to `client(id)` (`V2.2.00:5434`) — the plan claimed
  otherwise through r3.
- Onboarding mirrors (`V2.1.18`/`V2.1.19`) are a trap: `04-schema-bridge.sh` runs a hard-coded
  list ending at `V2.1.16` (Phase C) and `V1.2.05` runs in Phase F *after* it. A function-body
  watermark probe is only safe **because** no mirror exists.

See [[wms2-utc-v1205-hardcoded-function-list]] (the same `V1.2.05` DROP+CREATE that discarded
WineCo v1's hand-applied `client_id` grouping — this ticket is the v2 half),
[[negative-test-verify-scripts-before-trusting-them]],
[[wms2-develop-preexisting-test-failures]],
[[flyway-runbook-covers-dev-and-uat-via-env-flag]].

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

shared SKUs report all-clients totals per client (PNRO23: 8,322 vs true 1,074/7,248); V2.2.07 MERGED to develop 2026-07-31 (PR #112, merge 7d9aee6), ClickUp 'on dev' — but applied to NO database, so reports are STILL WRONG on all 5 tenants (app doesn't run Flyway at runtime); UAT at 2.2.05 needs V2.2.06 first; LANDMINES: Surefire `-Dtest` overrides the *IntegrationTest exclude, never add client_id to the myanswer projection, mutate-then-check before trusting a new assertion, Fix A/Fix B need disjoint (client,SKU) cells
