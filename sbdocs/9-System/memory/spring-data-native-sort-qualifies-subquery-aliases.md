---
name: spring-data-native-sort-qualifies-subquery-aliases
description: "wms2 paged native query sorted by a \"(SELECT …) as x\" alias becomes \"order by a.x\" → PG 500; fix with \")::numeric as x\", NOT a LATERAL join (18x slower)"
metadata:
  node_type: memory
  type: project
  originSessionId: aa99a64d-c785-4688-ad42-77641fba0512
  modified: 2026-10-28T11:31:12.493Z
---

Spring Data JPA 3.5.7 (no JSqlParser on wms2-api's classpath → DefaultQueryEnhancer → QueryUtils) appends a Pageable sort as `<detectedTableAlias>.<prop>` unless FIELD_ALIAS_PATTERN `[^\s()]+\s+as\s+(\w+)` matches the alias. A scalar-subquery alias `(SELECT … a.id) as qtyRequired` does not match (token ends in `)`), so the sort is `order by a.qtyRequired` → `column a.qtyrequired does not exist` → 500. SBDEV-3616 (PR #579, 2026-10-28).

**Why:** the fix shape matters. Moving the sums into `LEFT JOIN LATERAL` also sorts, but measured on DEV it took the default `created desc LIMIT 20` page from ~85 ms to ~1.55 s — a select-list scalar subquery is evaluated only for rows surviving LIMIT; a lateral is not. `(…)::numeric as x` is recognised and keeps the plan (no-op cast when already numeric).

**How to apply:** `PagedNativeQuerySortAliasUnitTest` now enforces the rule repo-wide. Its only other hit, `AdvicepositionRepository.findReturnsAudit`, is exempted (never sorted; detectAlias reads its alias as `LEFT`). If JSqlParser is ever added, that test fails on purpose — the enhancer changes. Related: [[a-zero-scan-needs-a-positive-control]].
