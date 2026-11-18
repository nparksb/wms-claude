---
name: wms2-dev-ui-test-credential-panderson
description: "Test login for wms2-web-ui browser tests on DEV and UAT is panderson / dev@sb (Nam, 2026-10-14; UAT added 2026-10-31) — use it, don't ask; never PRD"
metadata:
  node_type: memory
  type: reference
  originSessionId: fa0d14a5-1d4d-4d38-87b0-e6df8bc82613
  modified: 2026-10-31T13:24:14.318Z
---

For any browser/E2E testing of the v2 WMS UI on DEV (e.g. `https://wsl-wineco.wms.dev.sbo.li`), log in as
**username `panderson`, password `dev@sb`**. Nam said 2026-10-14: "Use panderson / dev@sb credential for any
further testing you need."

**UAT too (Nam, 2026-10-31: "use panderson account for UAT").** The same password works on
`https://wsl-wineco.wms.uat.sbo.li` (realm `wineco` on `kc2.uat.sbo.li`). It lands on the WSL dashboard as
"Welcome, Site". Used for SBDEV-3290's AC-4 login check. **Still never PRD.**

Facts measured 2026-10-14: panderson HAS warehouse access on wsl-wineco dev (lands on the Pick Pack Monitor
dashboard; header shows "Welcome, Smith"), so it cannot by itself exercise a no-warehouse-access path — fake the
claim client-side instead (rewrite the token response in puppeteer), don't strip the account's Keycloak groups.

Pass it via env vars (`WMS_USER`/`WMS_PASS`) to the script, not baked into a file. Recipe:
[[wms2-web-ui-headless-browser-recipe]].
