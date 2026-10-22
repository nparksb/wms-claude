---
name: wms2-new-sequence-key-first-draw-fails
description: "wms2 can never CREATE a los_sequencenumber key: String @Id carries @GeneratedValue(SEQUENCE) → first draw throws DataIntegrityViolationException (500); every existing key came from migrated data"
metadata:
  node_type: memory
  type: project
  originSessionId: 1622ae45-d0bb-48e8-bd54-3543480f2f93
  modified: 2026-10-07T21:20:00.000Z
---

Found 2026-10-07 testing SBDEV-3677 on dev. `LosSequencenumber.classname` is a `String` `@Id` annotated
`@GeneratedValue(SEQUENCE, seqentities)`. `SequenceTransactionService.getNextSequenceNumber` builds a new
row when the key is missing; Hibernate treats it as detached (generated id already set, version null) and
throws `DataIntegrityViolationException: Detached entity with generated id '<key>' has an uninitialized
version value 'null'` — uncaught → plain HTTP 500, no row written. Reproduced in a scratch H2 IT.

Consequence: Dashboard `printToteLabels` (needs `PICKING_TOTE_DEFAULT`, absent on all 4 PRD tenants and
dev) can never succeed; it ALSO needs a location named exactly like the client's section, which no
environment has. So that path has never run anywhere ([[sbdev-3325-oms-egress-watchdog]] SBDEV-3677).

**How to apply:** a 500 on a first-use numbering path → check `los_sequencenumber` for the key. Workaround
on dev: seed `(classname, 0, 0)`. Also blocks Admin → Label Printing tote generation (`/v3/labelPrinting/totes/generate`).

**Status 2026-10-07: MERGED to develop as 5e353fd8 (PR #474) and deployed to dev; NOT on main/PRD until a release** —
re-check git before assuming either way. Fix also added a 23505 retry (concurrent first draw), a blank-key refusal, and a
taken-label skip in Dashboard `printToteLabels`. ShipItEZ nywh PRD lacks CYCLECOUNT, CYCLECOUNT_POSITION,
LOCATION_UNIT_LOAD_CONSTRAINT, USER_ROLE (first cycle count / user role there = 500 until deployed).
Side finding (FILED 2026-10-08 as SBDEV-3688; FIX MERGED to develop c9d2ebe9 (PR #478), on dev 2026-10-08, NOT on main/PRD — minting now skips taken labels via UnitloadService.nextFreeLabel/mintUnitloadLabel, createNewUnitload refuses; no live PRD exposure measured): `UnitloadService.createUnitload(name, ...)` RETURNS the existing unit load when the exact label exists —
a stale tote sequence silently shares totes rather than failing. Lesson from the work: an IT `@MockitoSpyBean` boots
an extra cached context whose pool can exhaust Postgres `max_connections` for a later 50-thread IT — use raw
DriverManager connections (ClosebolLockOrderProbeIT pattern) for race tests instead.
Instrument trick that found it with no server logs: diff `pg_stat_user_tables` scan/insert counters around
one API call on a quiet DB (no pg_stat_statements on dev).
