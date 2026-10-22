---
name: sbdev-2726-shared-vuex-blob-facility-code
description: "WMS web+mobile UI facility_code=[object Object] from shared vuex localStorage blob"
metadata: 
  node_type: memory
  type: project
  originSessionId: 50923e14-62bd-4abf-a57d-571f1819fe93
  modified: 2026-07-26T12:01:32.176Z
---

SBDEV-2726 (Fulfillment Development Backlog, ClickUp 868kgagte). MERGED 2026-07-26 into develop, ClickUp "on dev": wms2-web-ui PR #25 (merge 0b35c093) + wms2-mobile-ui PR #24 (merge 43d6b6c58), SAME branch `tasks/SBDEV-2726-facility-code-shared-vuex-blob` — merged together (both apps must abandon the shared `vuex` key simultaneously). Code-reviewed both (APPROVE 0 crit/high); casing MEDIUMs verified NON-ISSUE (wms2-api TenantFilter.java:47 lowercases facility_code → routing is case-insensitive). Also folded in: axios clears facility_code/X-Tenant-ID when unresolved (no stale/"null" header), mobile setNewWarehouse `/mobile/` trailing slash + same-warehouse short-circuit.

**Symptom:** wms2-web-ui nav breaks after using wms2-mobile-ui and returning; backend logs `tenant key: wine-[object object]` / `No cached configuration`. axios sends `facility_code: [object Object]` (backend lowercases it in the routing key).

**Root cause (LANDMINE):** wms2-web-ui (`/`) and wms2-mobile-ui (`/mobile/`) are **same-origin**, and BOTH used `vuex-persistedstate` with the **default `vuex` localStorage key**. So each app rehydrates + re-persists the OTHER's entire root state — proven: the mobile `vuex` blob carried web's whole `admin` module (`client.clients` = hundreds of objects). `selectedWarehouse`/`warehouses` leaked across apps; a transient object reached the header. Self-heals once `initializeWarehouse` re-derives the string, so the flat localStorage keys (`selectedWarehouse=WSL`, `warehouseCode=wsl`) look clean after the fact — the object lives only in the `vuex` blob / in-memory store.state, which `axios.js` PREFERS over the URL-authoritative `warehouseCode`.

**Second bug:** mobile `pages/index.vue` warehouse `v-select` setter called `this.setNewWarehouse(...)` which was **never defined anywhere in the mobile repo** → selecting a warehouse threw (likely object injector in multi-warehouse dialog flow). Fixed by implementing it as a subdomain redirect mirroring web's `WarehouseMenu` (each warehouse = distinct `{warehouse}-{client}` subdomain/tenant), preserving `/mobile` base.

**Fix pattern (both apps):** (1) app-specific persistedstate `key` (`vuex-web`/`vuex-mobile`) + exclude `selectedWarehouse`+`warehouses` from reducer + `localStorage.removeItem('vuex')`; (2) axios resolves `facility_code` to a non-empty STRING only (store → explicit key → `warehouseCode`), never a non-string; (3) `setWarehouse` rejects non-strings/unwraps single-element arrays; (4) getters guard before `.toUpperCase()`.

Keycloak `warehouse` claim is a clean string array (`['WSL']`, or `['wh1','wh2']` multi-warehouse) — NOT the source. Casing inconsistency (web preserves `WSL`, mobile lowercases `wsl`) left as-is (possible follow-up; backend filters may be case-sensitive). Distinct from [[clickup-wms-tickets-fulfillment-backlog]] convention.
