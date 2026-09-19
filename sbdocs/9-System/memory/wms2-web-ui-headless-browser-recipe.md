---
name: wms2-web-ui-headless-browser-recipe
description: "How to drive the real wms2-web-ui on dev headlessly (host, tenant key, login flow, puppeteer-core outside the repo) — the only way to verify rendering, since v-autocomplete and Vuetify are stubbed in every Jest test"
metadata:
  node_type: memory
  type: reference
---

Established working 2026-08-26. This is the only route to a *visual* verdict: no Jest test in
wms2-web-ui mounts real Vuetify (no `createLocalVue`, no plugin registration), so every component
test stubs `v-autocomplete`, `v-card-title` etc. and cannot answer "does it render correctly".

**The pieces:**
- **UI host:** `https://wsl-wineco.wms.dev.sbo.li` — the only `active` row in the dev landlord's
  `tenant_discovery` table. The pattern is `<warehouse>-<client>.wms.dev.sbo.li`; the UI derives the
  discovery key as `` `${warehouse}-${clientName}` `` from `hostParts[0].split('-')`
  (`plugins/initTenantAuth.client.js:33-35`). ⚠ `cypress.config.js`'s `baseUrl` is the **OMS** host
  and returned HTTP 500 — do not use it for WMS.
- **Discovery:** `GET https://wms-api.dev.sbo.li/api/public/authConfig?key=wsl-wineco` → realm
  `wineco`, client `om1`, auth server `https://kc2.dev.sbo.li`. Inactive keys 404.
- **Browser:** Chrome is already installed (`/usr/bin/google-chrome`). Install **`puppeteer-core`**
  (not `puppeteer` — no Chromium download needed) **OUTSIDE the repo**, e.g. into the scratchpad, so
  `package.json` is untouched. Cypress's node module is NOT installed.
- **Login:** plain Keycloak form — `#username`, `#password`, `#kc-login`, then it returns to the UI.
- ⚠ **Wait on a selector, never a fixed sleep.** A 5s sleep gave `THEAD: []` / no rows on one run and
  a full table on another. Use
  `waitForFunction(() => document.querySelectorAll('tbody tr').length >= 5)`.

**Live UI facts worth knowing:**
- SKU Data is at `/masterData/materialData/sku-data`; details opens from an **`mdi-eye-outline`**
  button in the last (unlabelled) column — **clicking the row does nothing**.
- The edit affordance is an `mdi-pencil-outline` in that same column, and for a non-`sb_admin` it is
  rendered **visible but disabled** at Vuetify's `rgba(0,0,0,0.26)` — which at 1600px sits at
  x≈1536-1572, flush to the container edge, and looks absent in a screenshot while being present in
  the DOM. Check `button.disabled`, not pixels.
- `sbtest` / dev password holds WMS roles `inventory-manager` + `inventory-worker` and Keycloak groups
  `/wms_user`, `/warehouse/develop`, `/warehouse/wsl` — **no `sb_admin`**, so it can reach SKU Data
  (it holds `WEB_UI_VIEW_ITEM_DATA`) but **cannot open the putaway edit dialog**. Verifying that
  dialog's markup needs an `sb_admin` token. See
  [[wms2-keycloak-groups-claim-emits-full-paths]] and [[wms2-putaway-config-is-sb-admin-only]].
