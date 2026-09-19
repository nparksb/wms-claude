---
name: qa-station-v1-vs-v2-repo-map
description: OMS v2 UI is v2/siteboss-frontend (QA Manager = apps/qa); omsv2-UI is a Lovable prototype; v1/qa-ui + v1/qa-api are OMS v1 only
metadata: 
  node_type: memory
  type: project
  originSessionId: 75060194-ee15-400f-bfc3-b3e78707041b
  modified: 2026-09-16T20:22:07.510Z
---

Nam, 2026-09-16, flagged as important. **QA is part of the OMS, and the QA code lives in a different
repo per OMS version.** Getting this wrong aimed three of SBDEV-1512's four phases at the wrong repos.

| QA surface | OMS v1 | OMS v2 |
|---|---|---|
| UI | `v1/qa-ui` (Nuxt 2 / Vue 2, package `qa-manager`) | **`v2/siteboss-frontend` → `apps/qa`** — reached via the **Application Switcher** icon → *QA Manager*. Returns: `apps/qa/src/containers/Returns/` |
| Backend | `v1/qa-api` (Python Flask) | **`v2/oms-laravel-api`** — `routes/legacy-qa.php` (base `/old_code/qa/v1`, Flask-shaped for compat), `app/Services/Qa/`, models `ParcelReturn` / `ReturnMgmtLut` |

**`v2/siteboss-frontend` is THE OMS v2 UI** — a React 19 / Vite 7 / MUI v7 **monorepo**, `apps/`:
`admin cms owl pos qa shared siteboss website`. Two traps: **`main` is the DEVELOPMENT branch**
(`main` → `qa` → `production`, per `BRANCHING.md`; there is no `develop`), and the root `npm test` is
a stub that `exit 1`s — tests are **Cypress component specs** at `apps/**/src/**/*.cy.jsx`.

⚠ **`v2/omsv2-UI` is NOT the deployed OMS v2 UI.** It is a Lovable prototype (`@lovable.dev/mcp-js`,
`lovable-tagger`, `/.lovable/oauth/consent`, Cypress pointed at `omsv2.lovable.app`); its `main` has
not moved since 2026-05-11 and `git log --all -S'QA Manager'` returns **nothing** across its entire
history. Do not target it. See [[derive-cross-repo-claims-from-origin-develop]].

⚠ **`v1/qa-ui` and `v1/qa-api` are OMS v1 ONLY** — not shared infrastructure. The `v1/` prefix is the
trap: it reads as "the QA station, which happens to live under v1". Combined with
[[v1-is-reference-only-v2-is-the-only-target]] they are off-limits for new work.

**Search trap that cost a wrong conclusion:** `siteboss-frontend`'s source is under `apps/*/src`, so
`git grep -- src` returns **zero** and looks authoritative — the positive control still passes,
because the path filter, not the pattern, is what is wrong. Scope greps to `apps/` or omit the
pathspec. See [[a-zero-scan-needs-a-positive-control]].

**Measured 2026-09-16 while retargeting SBDEV-1512** — where the damaged quantity is actually lost:

- `apps/qa` UI is **correct**: `ManageReturns.handleManage` already submits
  `{item_id, qty_undamaged, qty_damaged, qty_missing}` per item.
- `oms-laravel-api` **drops it**: `app/Services/Qa/QaReturnService.php::buildReturnAdvicePositions`
  (the v2 counterpart of qa-api's `build_wms_create_advice_request`) builds the WMS advice from an
  `$undamagedByItem` map only, skips lines via `if ($qty <= 0) continue;`, and emits
  `amount_of_bottles` with no damaged field. It reaches the WMS via `WmsApiService` →
  `PUT {host}/rest/advice/create`.
- The v1 qa-ui defects have **no v2 counterpart** — confirmed by reading the v2 code, not by failing
  to find it. Defect A (Vuetify programmatic-write emits no `change`) cannot occur: `ManageReturns`
  holds `disposition` in React state and the submit handler reads that same state. Defect C
  (`processApiErrors` doing `.forEach` on a string) has no analogue: v2 uses structured error bars
  with i18n keys and explicitly branches on the re-fetched record, not a parsed error string.
