---
name: wms2-dev-ui-test-credential-panderson
description: "Dev test login for wms2-web-ui browser tests is panderson / dev@sb (Nam, 2026-10-14) — use it, don't ask"
metadata:
  node_type: memory
  type: reference
  originSessionId: fa0d14a5-1d4d-4d38-87b0-e6df8bc82613
  modified: 2026-10-14T18:11:39.567Z
---

For any browser/E2E testing of the v2 WMS UI on DEV (e.g. `https://wsl-wineco.wms.dev.sbo.li`), log in as
**username `panderson`, password `dev@sb`**. Nam said 2026-10-14: "Use panderson / dev@sb credential for any
further testing you need." DEV only — never use it against UAT/PRD.

Facts measured 2026-10-14: panderson HAS warehouse access on wsl-wineco dev (lands on the Pick Pack Monitor
dashboard; header shows "Welcome, Smith"), so it cannot by itself exercise a no-warehouse-access path — fake the
claim client-side instead (rewrite the token response in puppeteer), don't strip the account's Keycloak groups.

Pass it via env vars (`WMS_USER`/`WMS_PASS`) to the script, not baked into a file. Recipe:
[[wms2-web-ui-headless-browser-recipe]].
