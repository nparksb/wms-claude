---
title: "WMS v2 UI ↔ API Datetime Audit (read + write paths)"
type: report
status: complete
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-09
last_verified: 2026-06-09
verified_by: "Static audit of wms2-web-ui + wms2-mobile-ui (feature/utc-timezone); date-column types confirmed in wms2-hydra-dev2; display-path systemic bug reproduced live + fixed"
related:
  - ./260526-utc-migration-code-changes-reference.md
  - ../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md
  - ../../2-Areas/wms-utc-timezone-migration/README.md
tags: [report, wms2, utc, timezone, frontend, audit]
---

# WMS v2 UI ↔ API Datetime Audit (read + write paths)

**Question audited:** Across both v2 UIs (`wms2-web-ui`, `wms2-mobile-ui`), are datetimes exchanged with
`wms2-api` handled correctly end-to-end — **sent** in a format the API can accept/store (UTC for
`timestamptz`), and **displayed** in the correct warehouse-local time?

**Scope:** both directions. Audited on branch `feature/utc-timezone`. Read-only investigation; the one code
change referenced (the display-path fix) was committed separately during the investigation.

**Filename note:** created as `…-outbound-…` when it covered only the write path; later expanded to both
directions (kept the filename for link stability).

## Overall verdict — ✅ PASS (both directions), one systemic display bug found & fixed

| Path | Verdict | Headline |
|---|---|---|
| **Write** (UI → API) | ✅ Correct | UIs send **no `timestamptz`** at all; every user-entered temporal value is a `date` column sent as `YYYY-MM-DD` (tz-agnostic — correct). |
| **Read / display** (API → UI) | ✅ Correct **after fix** | Display code is thorough (84 web components + 3 mobile route through warehouse-TZ helpers), but a state-management bug fed them a stale tenant timezone. Root-caused and **fixed** (`wms2-web-ui 53eed00`, `wms2-mobile-ui d6861cb`). |

Contract being validated (from
[260526-utc-migration-code-changes-reference.md](./260526-utc-migration-code-changes-reference.md),
Phase 2.9 / 4.0 / 4.3 / 4.5 / 4.7):

- Backend stores `timestamptz` in **UTC** and emits it either as LEGACY bare `yyyy-MM-dd HH:mm:ss` (pinned UTC) or `ISO8601_UTC` (`…Z`).
- Frontend **display**: convert UTC → warehouse-local via the `$format*` helpers, which read `warehouseTimezone` (from `tenant_discovery.timezone`).
- Frontend **send**: `timestamptz` → UTC ISO-8601 (`$parseDateForApi`); pure `date` → `YYYY-MM-DD` (`$formatDateForPicker`); transaction-report `startDate`/`endDate` → warehouse-local `YYYY-MM-DD HH:mm:ss` (`$parseTransactionReportDate`).

---

# Part 1 — Write path (UI → API)

**Defining finding:** neither UI sends any `timestamptz` / UTC datetime. Every user-entered temporal input
maps to a PostgreSQL **`date`** column and is sent as a bare **`YYYY-MM-DD`** string (timezone-agnostic).
That is exactly correct — `date` columns must **not** be UTC-converted (converting risks an off-by-one day).
So there is **no UTC-format risk on the write path**, because there are no outbound timestamps to get wrong.

### Web UI — every date-bearing write

| Flow | Field → column | Sent as | Helper | Verdict |
|---|---|---|---|---|
| Picking-date update — `updatePickingDatePop.vue:93,107-112` → `store/outbound/pickPack.js:221` (`POST /customerOrder/pickingDateBatchUpdate`) | `customerorder.pickingdate` (**date** ✓) | `YYYY-MM-DD` | `$formatDateForPicker` | ✅ |
| Transfer date edit — `transferDetails.vue:166-172` → `store/outbound/transfer.js:179` (`PATCH /customerorder/{id}`) | `customerorder.pickingdate` (**date** ✓; there is **no** `customerorder.shipped` column) | `YYYY-MM-DD` | `$formatDateForPicker` | ✅ |
| PO / advice delivery window — `createPurchaseOrderForm.vue:248-251,80-83` → `store/receiving/createPo.js:94,107` (`POST /advice/create`, `/advice/update`) | `advice.dayofdelivery` / `dayofdeliveryuntil` (**date** ✓) | `YYYY-MM-DD` | `$formatDateForPicker` | ✅ |
| Cycle-count create — `createCycleCountForm.vue` → `store/internalOps/createCc.js:64` (`POST /cycleCount/create`) | — (shipper / name / note / areas only) | n/a | — | ✅ no date sent |
| Inbound-BOL bulk upload — `inboundBolUpload.vue:108,141` | `"Ship From"` = **origin location**, not a date | n/a | — | ✅ not temporal |

**Confirmed-harmless `$moment` uses (not sent to the API):** date-picker `:min`/`:max` bounds
(`createPurchaseOrderForm.vue:266-280`, `.toISOString()`); export filenames
(`outboundBols.js`, `inboundNotices.js`, `cycleCount.js:203`, `_YYYY-MM-DD_HH-mm-ss`).

### Mobile UI — no datetimes sent
13 store modules; **no date-entry widgets, no expiry/lot/date payload keys.** All ~33 write endpoints carry
scanned codes, IDs, quantities, and state transitions; operation timestamps are **server-stamped**. ✅

### Two structural facts that make the write path safe
- **`$parseDateForApi`** (UTC ISO-8601 helper, `dateFormatter.js:64`) is **defined but unused** in both UIs — consistent with "no `timestamptz` is sent from the UI." Available the day a write *does* target a `timestamptz`.
- The **transaction-report endpoints** (`getTransactionSummaryReport`/`DetailedReport`), which need the *warehouse-local* (not UTC) carve-out, are **not called from either UI** (OMS-facing). That footgun is not exercised here.

### Evidence — `date`-column types verified in `wms2-hydra-dev2` (2026-06-09)
| table | column | data_type |
|---|---|---|
| advice | dayofdelivery | **date** |
| advice | dayofdeliveryuntil | **date** |
| billoflading | shipped | **date** |
| customerorder | pickingdate | **date** |
| customerorder | shipped | *(does not exist)* |

Every column the UIs write a date into is `date` ⇒ `YYYY-MM-DD` is the correct wire format.

---

# Part 2 — Read / display path (API → UI)

**Design:** the backend emits UTC; converting UTC → warehouse-local for **display** is entirely the
frontend's job, via the `$format*` helpers in `plugins/dateFormatter.js`, which call
`.tz(warehouseTimezone)`. `warehouseTimezone` is captured per-tenant at boot from
`tenant_discovery.timezone` (`initTenantAuth.client.js`).

## 2a. Display code coverage — ✅ thorough (Phase-4.4 refactor complete)

| UI | Components routing timestamp display through `$format*` helpers | Bypass / raw display | `toLocaleString` (browser-local) |
|---|---|---|---|
| Web | **84** components | none for live API timestamps* | **none** |
| Mobile | **3** (only ones that show timestamps: `cancellation/cancellationDetail.vue`, `cancellation/cancellationList.vue`, `picking/selectOrder.vue`) | none | none |

\* The only two web `.format(` sites are non-display: `updatePickingDatePop.vue` (picker default "today")
and `reports/popups/exportReport.vue:117` (export **filename** timestamp). Every component with a local
`getTimeDate`/`getDate` method **delegates** to the helpers (verified e.g. `outboundBolDetails.vue:149-151`
→ `$formatDateTime`; `containerRecord.vue:302-303` → `$formatDateTime`). No `toLocaleString` /
`toDateString` display anywhere in either repo. Mobile has no `.format(`, no hardcoded zones, no local
formatters — the only timestamp displays go through the helpers.

## 2b. Systemic defect (FOUND & FIXED) — stale cross-tenant `warehouseTimezone`

The display **code** was correct, but a state-management bug fed it the wrong timezone, so **every** one of
the 84 refactored components rendered in the wrong zone for **non-LA** tenants.

- **Symptom:** a migrated **NY** tenant (Hydra) showed many timestamps **3h early** (LA wall-clock); the **LA** tenant (WineCo) looked fine. A date wrong-by-3h on a non-LA tenant — and an LA tenant being immune — is the fingerprint of a stray hardcoded/leaked **`America/Los_Angeles`** (the legacy global default), which is coincidentally correct for LA tenants only.
- **Root cause:** `plugins/persistedState.client.js` called `createPersistedState()(store)` with **no `paths`**, persisting the whole Vuex root state — including the tenant-scoped `warehouseTimezone`. Loading **after** `initTenantAuth` (`nuxt.config.js` plugin order), it rehydrated the **previous tenant's** `vuex` blob and clobbered the freshly-fetched NY value back to LA. `dateFormatter` then `.tz()`-converted to LA.
- **Live fingerprint (browser console on the broken page):** `localStorage['warehouseTimezone']` = `America/New_York` (correct, dedicated key) **but** `$nuxt.$store.state.warehouseTimezone` and the `vuex` blob = `America/Los_Angeles` (stale). DB/migration was correct (all columns `timestamptz`, UTC values right).
- **Fix:** exclude `warehouseTimezone` from the persisted blob (`reducer`) and re-assert it from its dedicated localStorage key after rehydration so already-stale browsers self-heal. Committed **`wms2-web-ui 53eed00`**, **`wms2-mobile-ui d6861cb`** (`feature/utc-timezone`).
- Full write-up: [[wms2-ui-warehouse-timezone-stale-persistedstate]] (project memory) and the Hydra run record §4.5-adjacent notes.

## 2c. Residual cosmetic items (low severity, not timezone-correctness)

- **Hardcoded `'(EST)'` column labels** — ✅ **FIXED (2026-06-09):** `containerRecord.vue:133` `'Time Stamp (EST)'` → `'Time Stamp'` (the value was always correctly warehouse-converted; only the static header text was wrong for non-Eastern warehouses). `stockUnitRecord.vue:142` already read plain `'Time Stamp'`. A repo-wide sweep for parenthesized TZ abbreviations `(EST|EDT|PST|PDT|CST|CDT|MST|MDT|UTC|GMT)` across both UIs found no other occurrences.
- **`date` columns rendered via `$formatDateTime`** (e.g. `outboundBolDetails.vue:57` `outboundBol.shipped`) show a spurious `12:00:00 am` time. Cosmetic — not a tz error. Use `$formatDate` for `date`-only fields.

---

# Caveats (audit scope honesty)

1. A terminal-output redaction mangled grep **match** terms, so the surface was mapped with `rg -l` (clean file paths) across three lenses — helper usage, `.format(`/picker widgets, and date-key payloads — then the actual payload builders / formatters were read directly, and column types confirmed in dev2. A timestamp path hidden behind a key none of those lenses caught is unlikely but not provably zero.
2. **Bulk CSV uploads** (inbound BOL, SKU, location) pass file-cell values straight through, outside the picker/helper path. Date-bearing import templates depend on the file, not the UI.
3. This was a read-only audit; the only code change referenced (the `persistedState` fix) was committed separately and **not yet pushed/merged**.

# Recommendations (PR-review checklist)

1. **Display:** every timestamp shown in the UI must go through a `$format*` helper (never bare `$moment().format()` / `toLocaleString` / raw interpolation). Coverage is currently complete — keep it that way.
2. **Send — `date` columns:** `$formatDateForPicker` → `YYYY-MM-DD` (current, correct).
3. **Send — `timestamptz` columns:** if any new UI write targets one (e.g. an appointment/scheduled time), it **must** use `$parseDateForApi` (UTC ISO-8601). None exist today.
4. **Tenant-scoped state must never ride in the persisted `vuex` blob** (the bug class fixed here). Keep `warehouseTimezone` (and other per-tenant/auth state) out of `persistedState`.
5. **Validate migrated tenants on a *non-LA* warehouse** — LA tenants structurally hide timezone bugs.
6. **Cosmetic:** remove the hardcoded `(EST)` labels; use `$formatDate` (not `$formatDateTime`) for `date`-only columns.
