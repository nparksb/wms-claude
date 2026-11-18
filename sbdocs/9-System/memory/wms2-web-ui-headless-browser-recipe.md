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

**2026-09-25 (macOS, SBDEV-3500):** Chrome is at `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.
Fastest exact verification: log in through the UI, capture the `authorization` / `x-tenant-id` / `facility_code`
headers from the page's first `https://wms-api.dev.sbo.li/v3` request (`page.on('request')`), then call the
endpoints with node `fetch` and compare `totalElements` against a DB count using the query's own predicate.
Credentials go in via env vars, never in the script. The UI sends `facility_code: WSL` (uppercase).
Script kept at scratchpad `pup/sbdev3500.js` for that session only.

**2026-10-29 (SBDEV-3591): count requests BY METHOD.** The UI calls `wms-api.dev.sbo.li` cross-origin with
custom headers, so the FIRST call to each URL shape is preceded by a CORS `OPTIONS` preflight to the same
URL, which is then cached. A `page.on('request')` counter keyed on URL alone reports "2 requests" for one
user action. It looked exactly like a double-fetch regression, but it was one GET plus its preflight; the Shipper
control showed the same. Filter `r.method() === 'GET'` / `'POST'`. Likewise, an export capture that takes the
first match gets the preflight's empty body. Probe kept at scratchpad `pup-scripts/sbdev3591-ui.js` for that
session: login, dropdown items, request-per-action counting, page reset, export body, and a client-side
`$nuxt.$router.push` leave (a full reload never runs `beforeRouteLeave`).

**2026-11-04 (SBDEV-3509): toasts and logins.** A `MutationObserver` set up in `evaluateOnNewDocument` silently
never attaches, because `document.documentElement` is null at that point. The result was a false "no toast" (S1
control failed). Scan `.toasted` elements on a 250 ms interval instead, and always run a positive toast control
first. For a second login in the same profile: `$nuxt.$kc.logout()` inside `Promise.all` with
`waitForNavigation`, then `goto(HOST)` and wait for `#username`. That gives a new `sid`; check it changed.
Adjustment alerts can be made without touching stock or OMS by inserting a `stockrecord` row (MANAGE_INVENTORY /
STOCK_ALTERED, ids 99000000NN). Script: scratchpad `pup/sbdev3509.js` (session-only).

**2026-11-06 (SBDEV-4032): admin sysprop screens.** `/admin` → tab "Parameters & Configuration" → sub-tab
"System Settings" / "Warehouse Details" (click `.v-tab` by text; `$router.push('/admin')` only takes after the post-login
`/dashboard` landing). The settings table is paginated, so click `mdi-magnify` and type the key. ⚠ In the edit dialog the
textarea labelled **Description (`#description`) is the `description` column**, not `additionalcontent`. Asserting on the
wrong column made a correct save look like a lost write. Use run-unique values (`Date.now() % 1e5`): a value equal to the
DB's leaves Warehouse Details' Save button hidden. Omit `userDataDir`, because a persisted profile skips the login form.
Script: scratchpad `pup/sbdev4032.js` (session-only).

**2026-11-06 (SBDEV-3221): target a table by a header only it has.** After the post-login `/dashboard` landing, the
Pick Pack Monitor's `.v-data-table` is still in the DOM, so `waitForFunction(tbody tr >= 1)` and `querySelector('.v-data-table')`
are satisfied by the DASHBOARD table. The first run read its 14 headers and reported "0 Receive buttons" for a user who has
the button, which looked like a regression. Pick the table by a unique header (e.g. "Qty Expected" for the open-notice
table) and wait for a data row in THAT table; always run the persona that should see the element first, as the
positive control. Persona swap without second credentials: move `panderson`'s `mywms_group_mywms_user` row to a
role-specific group (e.g. GROUP000034 = CS-REP only, 0 members on dev), snapshot before, diff after. AccessService
reads functions from the DB uncached, so it takes effect on the next login. Script: scratchpad `pup/sbdev3221.js`
(session-only).
