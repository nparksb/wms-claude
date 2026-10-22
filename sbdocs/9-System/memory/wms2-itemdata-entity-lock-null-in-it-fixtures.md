---
name: wms2-itemdata-entity-lock-null-in-it-fixtures
description: "wms2 itemdata.entity_lock is nullable with no default; IT fixtures that omit it make every `entity_lock = 0` query silently skip the item"
metadata:
  node_type: memory
  type: project
  originSessionId: 23bc21d0-2182-4a2c-9f76-f63deba095ee
  modified: 2026-10-05T18:51:39.413Z
---

`itemdata.entity_lock` (V2.2.00 base schema) is `integer` NULLABLE with NO default. IT fixtures that INSERT itemdata
without the column (e.g. `AbstractReplenishRedirectPgFixture.seedBase`) leave it NULL, so any query filtering
`itemData.entity_lock = 0` (the no-FLA shortage queries in `ItemdataRepository`, others) silently excludes the item.

**Why:** found on SBDEV-3654 (2026-10-05). A lane-exclusion test on the shortage query passed vacuously, and only the
positive control (same fixture, no lane) going red exposed it. It is a false green, not a false red, so nothing else
would have caught it.

**How to apply:** when a test exercises a query with `entity_lock = 0` on a table whose fixture insert omits the
column, set it explicitly (`UPDATE itemdata SET entity_lock = 0 ...`). Always pair a "row is excluded" assertion with
a positive control on the same fixture. See [[a-zero-scan-needs-a-positive-control]] and
[[green-tests-that-prove-nothing]].
