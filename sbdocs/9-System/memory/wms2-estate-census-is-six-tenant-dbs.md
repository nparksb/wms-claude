---
name: wms2-estate-census-is-six-tenant-dbs
description: A v2 estate-wide count needs SIX tenant DB MCPs — missing the two WineCo ones under-counted by 8.5x
metadata: 
  node_type: memory
  type: reference
  originSessionId: 9852c2e4-0668-4f20-ba3b-56ab5830f9fa
  modified: 2026-09-15T14:26:21.653Z
---

An "across the whole v2 estate" claim needs **all six** reachable tenant-DB MCP servers, not the
Hydra/ShipItEZ four that come to mind first:

| MCP | what it is |
|---|---|
| `wms2-hydra` | **the only v2 PRD tenant** |
| `nywh-hydra-uat` | Hydra UAT |
| `c1wh-shipitez-uat` | ShipItEZ UAT, the **largest** (≈108k customerorder, ≈264k pickingorder_position) |
| `nywh-shipitez-uat` | ShipItEZ UAT, small |
| `wsl-wineco-uat` | WineCo UAT |
| `wms2-wineco-dev` | WineCo dev — see [[wineco-dev-db-is-dev-wh01-om1-not-the-migration-env-target]] |

**Why:** measured on SBDEV-3332 (2026-09-15). A census of `markedforcancellation = true` over the
first four returned 17 rows and "all 17 at state 800". Over all six it is **145 rows, and six are
NOT at 800** — an 8.5x under-count plus a false uniformity claim, caught by a review lane. "All four
v2 environments" was also wrong as a phrase: there are three *environments* (dev/uat/prd) and six
*tenant DBs*, so "four" matched neither.

**How to apply:**
- Sweep all six before any sentence containing *every · all · none · exactly* about the estate, and
  say which axis you counted (DBs, not environments).
- Landlord DBs are a separate axis again — see [[wms2-dev-landlord-is-dev-landlord-not-landlord]].
- The first query after idle drops; retry once
  ([[wms-mcp-first-query-after-idle-drops]]).
- State the rule, not the enumeration: a per-DB table with a date survives, "17 rows" does not.
