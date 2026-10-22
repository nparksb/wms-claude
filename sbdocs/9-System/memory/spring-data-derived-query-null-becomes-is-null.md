---
name: spring-data-derived-query-null-becomes-is-null
description: "A Spring Data DERIVED finder rewrites a null argument to IS NULL; native SQL `=` never matches NULL — matters for any finder whose result gets mutated"
metadata:
  node_type: memory
  type: feedback
  originSessionId: d3676c74-2bd7-4023-b57c-1ddb9e27814c
  modified: 2026-10-08T21:12:34.765Z
---

A derived Spring Data JPA finder (`findByAAndB(a, b)`) binds a null argument as `IS NULL`, not `= NULL` (verified in spring-data-jpa 3.5.7, `ParameterMetadataProvider$ParameterMetadata`). A native `@Query` with `col = :x` matches nothing for null. Converting a native finder to a derived one silently changes null semantics.

**Why:** SBDEV-3292 (2026-10-08): the release finder `findByUnitloadIdAndCustomerordernumberOrderByIdDesc` was first written derived; a null order number would have returned every unnumbered `pickingorder_unitload` row on the tote (any order's) and a null tote id would have returned already-released rows — and the callers RELEASE what they get. Caught only by a re-review lane, not by the author or the first two lanes. Pinned on Postgres by `PickingorderUnitloadReuseIT` null-key cases plus an ArchUnit check that the finder is native.

**How to apply:** for a finder whose rows a caller will update/delete, either use a native/JPQL `@Query` with `=` or guard nulls in the service; never assume a derived finder treats null like SQL. Related: [[wms2-repository-tests-commit-they-do-not-roll-back]], [[tote-reuse-nonunique-optional-finders]].
