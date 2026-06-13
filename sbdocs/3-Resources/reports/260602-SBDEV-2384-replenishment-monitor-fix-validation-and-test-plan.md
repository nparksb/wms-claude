---
title: "SBDEV-2384 — Replenishment Monitor Fix: Validation & Manual Test Plan"
type: report
ticket: "SBDEV-2384"
ticket_url: "https://app.clickup.com/t/SBDEV-2384"
project: [wms1]
status: validated-on-dev
created: 2026-06-02
updated: 2026-06-02
db_verified: true
environment: "wms1-wineco-dev (wh01_om1 @ localhost:25060)"
related:
  - "[[SBDEV-2384-replenishment-monitor-pickpack-classification-fix]]"
  - "[[260601-wineco-replenishment-pickpack-source-and-order-count]]"
  - "[[wms1-release-orphaned-stock-reservation]]"
tags:
  - report
  - validation
  - test-plan
  - wms1
  - replenish
  - SBDEV-2384
---

# SBDEV-2384 — Replenishment Monitor Fix: Validation & Manual Test Plan

**Audience:** QA, operations, and anyone verifying the Replenishment Monitor fix on a dev/staging server.
**Status:** Fix B (DB view) validated live on `wms1-wineco-dev` 2026-06-02. Fix A (app JAR) pending UI confirmation on the deployed build.
**Code:** branch `task/SBDEV-2384`, commit `9412fa4`, PR [#169 → release](https://github.com/SiteBossInc/wms-api/pull/169).

---

## 1. What was wrong, and what changed

The Replenishment Monitor's **"on replenishable location"** figure counted stock sitting on **pick-only** faces (e.g. the area `Storage and Picking`, which is `useforpicking=true, useforreplenish=false`) as if it were replenishable supply. Operators therefore saw replenishable inventory that did not exist and expected replenishment to resolve a pick shortage it could not.

**Root cause:** both read paths classified the replenishable bucket by a hardcoded area-**NAME** list that wrongly included `'Storage and Picking'`, instead of the canonical boolean column `location_area.useforreplenish`.

**The fix — classify by the flag in both read paths (staging bucket left unchanged):**

| Fix | Where | Change |
|---|---|---|
| **A** | `ReplenishmentMonitorViewRepository.getReplenishViewSummary()` (the inline native query the **Monitor UI** calls) | `on_replenishable_location(_names)` now use `loc_area.useforreplenish = true` |
| **B** | DB view `replenishment_monitor_view` (the Spring Data REST `/replenishmentMonitorView` path) — new migration `V1.26.29__…flag_based_classification.sql` | same flag-based bucket; deployed 17-column shape otherwise byte-identical |
| **C** | Commented DDL in `ReplenishmentMonitorView.java` | doc hygiene only |

> **Two independent read paths.** The **Monitor UI** uses Fix A (in the JAR). The **REST `/replenishmentMonitorView` (`findAll`)** path uses Fix B (the DB view). Both must be deployed; test both. If they disagree for the same SKU, the JAR is older than the view.

**Intended behavioral deltas** (not regressions):
- Pick faces (`useforpicking, NOT useforreplenish`) drop out of the replenishable bucket — *this is the fix*. Numbers go **down**.
- Dual-purpose faces (`useforpicking AND useforreplenish`) are now correctly **counted** (the old name list had a comma typo that never matched). 0 such locations on WineCo today.
- `Deep Storage` and `Outbound` appear in **neither** bucket — correct by flag.
- No API/JSON contract change — only the numeric value of `on_replenishable_location` corrects.

---

## 2. Deployment status on `wms1-wineco-dev` (validated 2026-06-02)

| Path | Check | Result |
|---|---|---|
| **Fix B (view)** | `position('Storage and Picking' in pg_get_viewdef('public.replenishment_monitor_view', true)) > 0` | **false** — name list gone; view is flag-based ✅ |
| **Fix A (JAR)** | Monitor UI value for a pick-face SKU (manual, §4) | ⏳ confirm on the deployed app build |

```sql
-- Confirm Fix B is deployed (returns false when fixed):
SELECT position('Storage and Picking' in
  pg_get_viewdef('public.replenishment_monitor_view', true)) > 0 AS still_buggy;
```

---

## 3. Live validation evidence (read-only, `wms1-wineco-dev`)

### 3.1 Area configuration (the canonical truth)

| Area | useforpicking | useforreplenish | # locations | In replenishable bucket? |
|---|---|---|---|---|
| Storage and Replenish | f | **t** | 415 | ✅ yes (correct reserve) |
| Storage and Picking | **t** | f | **2161** | ❌ no — **the bug**: was wrongly counted |
| Storage Picking and Replenish (from) | t | t | 0 | ✅ yes (none today) |
| Deep Storage | f | f | 0 | no |
| Inbound / Default / users | f | f | 13 / 16 / 116 | staging bucket (unchanged) |
| Outbound | f | f | 45 | neither bucket |

### 3.2 Old vs new for SKUs currently **live on the Monitor**

A SKU is on the Monitor when `bottles_needed − available_pick_stock > 0` (the view's `HAVING`). Verified live:

| SKU | On Monitor? | Bottles needed (shown) | **old** `on_replenishable` (name-based) | **new** `on_replenishable` (flag-based) | Note |
|---|---|---|---|---|---|
| **CH2022** | ✅ yes (24 − 5) | 19 | **5** | **0** | 5 bottles were on a pick-only face — now excluded |
| **LEO-TEST-WINE-1** | ✅ yes (24 − 2) | 22 | **2** | **0** | same pattern |
| **TestReplenNA** | ✅ yes (6 − 0) | 6 | 90 | 90 | **control** — real reserve, unchanged |
| TestSKUWINECO3 | ❌ no (avail 24 > need 3) | — | 24 | 0 | filtered out by HAVING |
| **BW23CPN** | (no current shortage) | — | 63 | 0 | all 63 bottles on pick-only faces |

**Headline:** `CH2022` is on the Monitor with a 19-bottle shortage. Pre-fix it reported **5** replenishable; post-fix it correctly reports **0** (no reserve to pull from). `TestReplenNA` proves the fix does *not* touch legitimate reserve stock (90 → 90).

> **Note on the deployed view value:** a direct `SELECT … FROM replenishment_monitor_view WHERE sku_id='CH2022'` materializes the entire view (it aggregates the full `stockunit` table) and is expensive. The view's `on_replenishable_location` is exactly the per-SKU expression `round(sum(CASE WHEN useforreplenish THEN amount ELSE 0 END))`, which equals the **new flag-based** column above. Since the deployed view definition is confirmed flag-based (§2), the view returns **0** for CH2022.

---

## 4. Manual test plan

### 4.1 UI test — exercises Fix A (the Monitor screen)

| # | Scenario | Steps | Expected |
|---|---|---|---|
| 1 | Pick-only stock not shown as replenishable | Open the **Replenishment Monitor**; locate **CH2022** (or any SKU whose only stock is on a *Storage and Picking* face) | "On replenishable location" = **0** (was 5 for CH2022) |
| 2 | Reserve stock still counted | Locate **TestReplenNA** (stock in a real replenish area) | "On replenishable location" = **90** (unchanged) |
| 3 | Mixed stock | SKU with both pick-face and reserve stock | Column = reserve qty only (pick face excluded) |
| 4 | Staging bucket unchanged | SKU with stock in *Inbound* | "On non-replenishable location" still includes it |

**Pass criteria:** scenario 1 shows 0 and scenario 2 shows 90 on the live Monitor.
**If scenario 1 still shows 5** while the view query (§4.2) shows 0 → the deployed JAR predates commit `9412fa4`; redeploy the app.

### 4.2 DB validation — confirms Fix B + parity (read-only)

Run against `wms1-wineco-dev`. **Use per-SKU queries** — the full view is too heavy to materialize in one shot.

**B1 — Verify the deployed view is flag-based:**
```sql
SELECT position('Storage and Picking' in
  pg_get_viewdef('public.replenishment_monitor_view', true)) > 0 AS still_buggy;
-- expect: still_buggy = false
```

**B2 — Old vs new for a specific SKU (the core check):**
```sql
SELECT i.item_nr AS sku,
  round(sum(CASE WHEN loc_area.name IN
      ('Storage and Replenish','Deep Storage','Storage, Picking and Replenish (from)','Storage and Picking')
    THEN su.amount ELSE 0 END)) AS old_name_based,
  round(sum(CASE WHEN loc_area.useforreplenish = TRUE
    THEN su.amount ELSE 0 END)) AS new_flag_based
FROM stockunit su
  JOIN unitload ul ON ul.id = su.unitload_id
  JOIN location loc ON loc.id = ul.storagelocation_id
  JOIN location_area loc_area ON loc_area.id = loc.area_id
  JOIN itemdata i ON i.id = su.itemdata_id
WHERE su.entity_lock=0 AND ul.entity_lock=0 AND loc.entity_lock=0
  AND i.item_nr = 'CH2022'           -- swap in any SKU
GROUP BY i.item_nr;
-- live result: CH2022 -> old_name_based = 5, new_flag_based = 0
```

**B3 — Find SKUs currently on the Monitor (demand side, fast):**
```sql
SELECT i.item_nr AS sku, round(sum(cop.amount)) AS bottles_needed
FROM customerorder_position cop
  JOIN customerorder co ON co.id = cop.order_id
  JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
  JOIN itemdata i ON i.id = cop.itemdata_id
WHERE cop.state < 200 AND co.pickingdate <= current_date AND cob.type = 'PICK_PACK'
GROUP BY i.item_nr
ORDER BY bottles_needed DESC
LIMIT 10;
```

**B4 — Full Monitor math for a candidate set (confirms which are on the Monitor + the delta):**
```sql
WITH skus AS (
  SELECT unnest(ARRAY['CH2022','LEO-TEST-WINE-1','TestReplenNA']) AS item_nr
),
demand AS (
  SELECT i.item_nr, round(sum(cop.amount)) AS bottles_needed
  FROM customerorder_position cop
    JOIN customerorder co ON co.id = cop.order_id
    JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
    JOIN itemdata i ON i.id = cop.itemdata_id
  WHERE cop.state < 200 AND co.pickingdate <= current_date AND cob.type='PICK_PACK'
    AND i.item_nr IN (SELECT item_nr FROM skus)
  GROUP BY i.item_nr
),
stock AS (
  SELECT i.item_nr,
    round(sum(CASE WHEN la.useforpicking AND NOT la.useforreplenish
                   THEN su.amount - su.reservedamount ELSE 0 END)) AS available_pickface,
    round(sum(CASE WHEN la.useforreplenish THEN su.amount ELSE 0 END)) AS new_flag_based
  FROM stockunit su
    JOIN unitload ul ON ul.id=su.unitload_id
    JOIN location loc ON loc.id=ul.storagelocation_id
    JOIN location_area la ON la.id=loc.area_id
    JOIN itemdata i ON i.id=su.itemdata_id
  WHERE su.entity_lock=0 AND ul.entity_lock=0 AND loc.entity_lock=0
    AND i.item_nr IN (SELECT item_nr FROM skus)
  GROUP BY i.item_nr
)
SELECT d.item_nr AS sku, d.bottles_needed,
       COALESCE(s.available_pickface,0) AS available,
       (d.bottles_needed - COALESCE(s.available_pickface,0)) AS net_shortage_on_monitor,
       COALESCE(s.new_flag_based,0) AS new_flag_based
FROM demand d LEFT JOIN stock s ON s.item_nr=d.item_nr
ORDER BY net_shortage_on_monitor DESC;
-- net_shortage_on_monitor > 0  => SKU appears on the Monitor
```

---

## 5. How to interpret results

- **Expect numbers to drop, not break.** The corrected figure reflects true replenishable inventory. Pick faces, Deep Storage, and Outbound now appear in *neither* bucket — by design.
- **A SKU only appears on the Monitor when it has a net shortage** (`bottles_needed − available_pick_stock > 0`). If a test SKU isn't on the screen, it has no current shortage — use B2 to validate the classification regardless.
- **Dual-purpose faces can *increase* a figure** (`useforpicking AND useforreplenish`). 0 such locations on WineCo today, so no live impact here.
- **UI vs view disagreement** for the same SKU ⇒ deployed JAR is older than the view; redeploy.

---

## 6. Sign-off checklist

- [ ] **B1** on target env → `still_buggy = false` (view is flag-based).
- [ ] **UI scenario 1** (CH2022 or equivalent) → "on replenishable location" = **0**.
- [ ] **UI scenario 2** (TestReplenNA) → "on replenishable location" = **90** (unchanged control).
- [ ] **B2/B4** for 2–3 production SKUs → `new_flag_based` matches the Monitor's on-screen value.
- [ ] App build deployed = commit `9412fa4` / PR #169 (UI path).
- [ ] **Deploy gates** acknowledged (see §7).

---

## 7. Deploy gates (carry-over from the plan §7.1 — confirm before production)

1. **Confirm Flyway manages the target schema.** No `flyway_schema_history` was found during investigation; if Flyway is *not* managing prod, Fix B must be delivered as a DBA-run `CREATE OR REPLACE VIEW` per tenant DB. (On `wms1-wineco-dev` the view change was applied manually for this validation.)
2. **Migration version ordering.** The migration is named **`V1.26.29__…`** (chosen over `V1.1.06` to avoid colliding with `develop`'s existing `V1.1.06__…` script and to sit above the out-of-band `V1.26.28_…` single-underscore file, which standard Flyway ignores). Confirm `V1.26.29` is strictly greater than the highest **applied** Flyway version on the target tenant before deploy.
3. **Apply Fix A (JAR) and Fix B (view) in the same maintenance window** to avoid a window where one read path is corrected while the other still miscounts.

---

## Appendix — evidence provenance

- DB: `wms1-wineco-dev` (`wh01_om1` @ `localhost:25060`), read-only queries, 2026-06-02. `statement_timeout = 0`.
- View definition flag-based confirmed via `pg_get_viewdef`.
- Per-SKU old-vs-new deltas from the `stockunit → unitload → location → location_area` join, `entity_lock = 0` on all three (matches the production query's lock filter).
- Automated test: `ReplenishmentMonitorViewRepositoryIT` (Testcontainers) — 4/4 pass, exercising both read paths. Acceptance script `verify-SBDEV-2384-…sh` — 14 pass, 0 fail.
