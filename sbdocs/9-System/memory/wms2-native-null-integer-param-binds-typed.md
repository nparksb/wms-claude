---
name: wms2-native-null-integer-param-binds-typed
description: "In wms2-api native @Query, a null Integer @Param binds TYPED on PG14 (Spring Data JPA 3/Hibernate 6) — bare `:p IS NULL` works; CAST is convention, not a fix. String/untyped params differ"
metadata:
  node_type: memory
  type: project
  originSessionId: 73044a3b-94bc-4eac-81f7-0e33353ba62c
  modified: 2026-10-29T02:30:55.315Z
---

On wms2-api (Spring Boot 3.5 / Spring Data JPA 3 / Hibernate 6, PostgreSQL 14), a native `@Query` with
`AND (:state IS NULL OR p.state = :state)` and a **null `Integer` `@Param`** runs fine. The "could not determine
data type of parameter $N" error does not happen.

Measured 2026-10-29 on SBDEV-3591. The architect consult said the CAST was required. A mutant removing
`CAST(:state AS integer)` from `OrderDetailMonitorViewRepository.findByClientOffsetAndLimit` still passed the
PostgreSQL IT (`OrderDetailMonitorViewStateFilterIT`, null-state case).

**Why:** the "PG can't type a null param" folklore came from `MessageRepository`/`StockrecordRepository`
comments. Repeating it makes a defensive CAST read as load-bearing, and gets a contract test written that pins the
CAST text, which asserts implementation shape.

**How to apply:** for an optional Integer/Long native param, either form works. Keep the CAST only as convention,
and say so. Do NOT generalise to String params or to params declared as `Object`: those can still bind untyped,
which is why `MessageRepository` casts. Re-measure with an IT on any Spring Data or Hibernate major upgrade.
Settle the question with a mutant against a PostgreSQL IT, not by reasoning.

Related: [[hub-code-traps]].
