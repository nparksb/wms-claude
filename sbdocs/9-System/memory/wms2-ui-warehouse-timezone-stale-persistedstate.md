---
name: wms2-ui-warehouse-timezone-stale-persistedstate
description: "After UTC migration, wms2 UI dates render in the wrong tz because persistedState rehydrates a stale tenant-scoped warehouseTimezone"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4de17f86-0cd9-435c-a3fe-8d0aac474f23
---

During v1→v2 UTC migration validation, a migrated **NY tenant (Hydra)** showed certain wms2-web-ui dates **3h early (LA wall-clock)** while an **LA tenant (WineCo) looked fine** — a date wrong-by-3h on a non-LA tenant = a stale `warehouseTimezone`, and LA tenants can NEVER reveal a tz bug (LA was the legacy global default, so it's coincidentally correct for them).

**Root cause:** `plugins/persistedState.client.js` called `createPersistedState()(store)` with no `paths`, persisting the whole Vuex root state. `warehouseTimezone` is tenant-scoped and authoritative from `tenant_discovery.timezone` (re-fetched each boot by `initTenantAuth.client.js` into its own dedicated `warehouseTimezone` localStorage key + committed to the store). But `persistedState` loads AFTER `initTenantAuth` and rehydrated the whole-state `vuex` blob from the **previous tenant's** session, clobbering the freshly-fetched NY value back to the prior LA value. `dateFormatter.js` reads `store.state.warehouseTimezone` and `.tz()`-converts UTC API timestamps with it → every date rendered in LA.

**Diagnostic fingerprint** (browser console on the broken page): `localStorage.getItem('warehouseTimezone')` = correct (`America/New_York`) but `$nuxt.$store.state.warehouseTimezone` and `JSON.parse(localStorage.getItem('vuex')).warehouseTimezone` = stale (`America/Los_Angeles`). DB/migration was correct (all columns `timestamptz`, UTC values right) — this is purely a UI display bug.

**Fix applied** (both `wms2-web-ui` and `wms2-mobile-ui`, `feature/utc-timezone`): `createPersistedState({ reducer: ({ warehouseTimezone, ...rest }) => rest })` to exclude the tenant-scoped tz from the blob, plus a post-rehydrate `store.commit('setWarehouseTimezone', localStorage.getItem('warehouseTimezone'))` so already-stale blobs self-heal without a manual clear. Did NOT reorder plugins (mobile CLAUDE.md says don't).

**How to apply (future tenant migrations):** validate the UI on a **non-LA** tenant — LA tenants hide tz bugs. If dates are off by the NY−LA (3h) or other tz delta, check the live `store.state.warehouseTimezone` vs the dedicated localStorage key before suspecting the DB migration. Related: [[wineco-wsl-v1-v2-migration-status]].
