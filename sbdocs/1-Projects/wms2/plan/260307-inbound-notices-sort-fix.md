---
title: "Inbound Notices Qty Required / Received Sort Fix — v2 Port Analysis"
ticket: ""
ticket_url: ""
type: "migration-analysis"
priority: "low"
status: "closed — not needed"
project: ["wms2-api"]
version: "v2"
requester: "sync-sweep"
created: "2026-05-03"
updated: "2026-05-03"
related: []
tags:
  - plan
  - v1-sync
  - advice
  - inbound-notices
db_verified: false
---

# Inbound Notices Sort Fix — v2 Port Analysis

**V1 Source Commit:** `07ae9ab` — "Fixed Inbound Notices Qty Required / Received sort not working" (Arden Latraca, 2026-03-16)
**V2 Target:** `wms2-api`
**Status:** CLOSED — not needed in v2

---

## 1. Summary

1 v1 fix analysed. **0 confirmed still needed. 0 NEW v2-only issues.** The fix is already incorporated into v2 through a different but equivalent implementation. No code changes required.

---

## 2. V1 → V2 Applicability Analysis

| V1 Fix | Description | V2 Verdict | Rationale |
|--------|-------------|------------|-----------|
| F1 | Add `qtyRequired`/`qtyReceived` to `getOpenNoticesByKeyword` SQL | **Not needed (V2 already correct)** | `AdviceRepository.java` L85-86: correlated subqueries produce both columns |
| F2 | Add `qtyRequired`/`qtyReceived` to `getClosedNoticesByKeyword` SQL | **Not needed (V2 already correct)** | `AdviceRepository.java` L114-115: same correlated subquery pattern |
| F3 | Add missing `countQuery` to both methods | **Not needed (V2 already correct)** | L91-93 and L120-122: explicit `countQuery` on both methods |
| F4 | Remove Java-side qty calculation from `ViewDtoService` | **Not needed (V2 already correct)** | `ViewDtoService.java` L967-968: uses `result.getQtyRequired()` / `result.getQtyReceived()` from `AdviceNoticeView` projection — no Java-side loop over `receivingDtoViewRepository` |

---

## 3. V2 Implementation — Evidence

### `AdviceRepository.getOpenNoticesByKeyword` (v2 L68-95)

```java
"(SELECT COALESCE(SUM(ap.notifiedamount), 0) FROM adviceposition ap WHERE ap.advice_id = a.id) as qtyRequired, " +
"(SELECT COALESCE(SUM(grp.amount), 0) FROM goodsreceiptposition grp JOIN adviceposition ap2 ON grp.adviceposition_id = ap2.id WHERE ap2.advice_id = a.id) as qtyReceived " +
...
countQuery = "select count(a.id) from advice a left join client c on a.client_id = c.id ..."
```

Returns `Page<AdviceNoticeView>` — a typed projection interface with `getQtyRequired()` and `getQtyReceived()` (`BigDecimal`). No `Object[]` casting needed.

### `AdviceRepository.getClosedNoticesByKeyword` (v2 L97-124)

Identical pattern. Explicit `countQuery` at L120-122.

### `ViewDtoService.getAdviceViewByKeyword` (v2 L934-977)

```java
dto.put("qtyRequired", result.getQtyRequired());
dto.put("qtyReceived", result.getQtyReceived());
```

No `receivingDtoViewRepository.getQtyByAdvicenumber()` call — that Java-side loop was eliminated when v2 adopted the projection interface.

---

## 4. Why v2 Doesn't Need the `SELECT * FROM (...) AS a` Wrapper

The v1 fix wrapped both queries in `SELECT * FROM (...) AS a` to make PostgreSQL honour `ORDER BY` on the computed column aliases (`qtyrequired`, `qtyreceived`). This wrapper was necessary in v1 because:

1. Spring Data JPA's auto-generated `countQuery` (when none is specified) generates `SELECT count(*) FROM (inner_query) AS derived_table` — which requires an alias in PostgreSQL. The wrapper provided that alias.
2. The `LEFT JOIN ... GROUP BY` aggregation approach placed the aggregated columns at a nested scope, making them unreachable without the outer wrapper.

In v2:
1. Both methods have an **explicit `countQuery`** — the auto-generation path is never triggered.
2. The correlated subquery approach places `qtyRequired`/`qtyReceived` as **top-level SELECT aliases**. PostgreSQL natively supports `ORDER BY column_alias` on top-level aliases, so no wrapper is needed.

---

## 5. Approach Comparison

| Aspect | v1 (post-fix) | v2 (current) |
|--------|---------------|--------------|
| Aggregation | LEFT JOIN + GROUP BY aggregation in subquery | Correlated subquery per row |
| Wrapper | `SELECT * FROM (...) AS a` | None needed |
| Count query | Explicit (added by the fix) | Explicit (already present) |
| Return type | `Page<Object[]>` (index-based) | `Page<AdviceNoticeView>` (typed projection) |
| Java qty calc | Removed by the fix | Never present in v2 |
| Performance note | Slightly better at scale (single join scan vs N correlated subqueries) | Fine for typical advice table sizes |

The v2 implementation is overall cleaner: typed projection eliminates index-based `result[16]`/`result[17]` lookups and is less fragile under schema changes.

---

## 6. Sync Log Action

Mark `07ae9ab` as `already-done` in the next sweep run. The sync log anchor (`7f06c6f`) can advance past this commit without any v2 code change.

---

## 7. Horizontal Scalability Validation

N/A — no code changes. Read-only repository queries; no state, no locks, no scheduled jobs.

---

## 8. Changelog

| Date | Ver | Author | Notes |
|------|-----|--------|-------|
| 2026-05-03 | v1 | Nam Park (migration analysis) | Analysis complete. Verdict: not needed. |
