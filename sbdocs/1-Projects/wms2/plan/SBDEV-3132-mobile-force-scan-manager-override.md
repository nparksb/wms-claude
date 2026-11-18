---
title: "Mobile force-scan with manager override (per-tenant)"
ticket: "SBDEV-3132"
ticket_url: "https://app.clickup.com/t/868kxnbpb"
type: "feature"
priority: ""
status: "in-progress"
project: ["wms2"]
version: "v2"
requester: "WineCo (Daily Check-in 2026-08-27)"
created: "2026-10-26"
updated: "2026-10-28"
tier: "T3"
db_verified: true
revision: "r3 (after architect r2 + critic r2)"
base_commit: "bb3e3580 (wms2-api origin/develop) · 1497c3b (wms2-mobile-ui origin/develop)"
related:
  - "[[SBDEV-3741]]"
  - "[[SBDEV-3222]]"
  - "[[SBDEV-3548]]"
tags:
  - plan
---

# Mobile force-scan with manager override (per-tenant)

**Ticket:** [SBDEV-3132](https://app.clickup.com/t/868kxnbpb) · `pr submitted` (P1) · **Tier T3**. The credential endpoint decides the tier; the work also adds a Flyway migration and spans two repos.

**Repos:** `v2/wms2-api` (P1) and `v2/wms2-mobile-ui` (P2–P9). P0 is a device spike and merges no code.

**Evidence:** `.omc/research/SBDEV-3132-analysis.md`, `…-architect.md`, and the reviews `.omc/research/SBDEV-3132-review-{architect,critic}-r{1,2,3}.md` (IDs `aH/aM/aL#`, `cH/cM/cL#` for r1; `aN#`/`cN#` for r2; `aC#`/`aL-#`/`cC#`/`cL#` for r3; the r1 `cL#` and r3 `cL#` sets are distinguished by the revision log they appear in).

Citations are `file` plus a quoted snippet; line numbers are hints only. Mode: ralplan DELIBERATE.

---

## Implementation Status

| Phase | Repo / branch | State | Evidence |
|---|---|---|---|
| P0 device spike | — | **kit ready, awaiting a device run** (blocks P2) | harness `sbdocs/3-Resources/reports/assets/sbdev-3132-p0-scan-spike.html` (headless-tested 2026-10-28); report [261028-sbdev-3132-p0-honeywell-scan-spike](../../../3-Resources/reports/261028-sbdev-3132-p0-honeywell-scan-spike.md) |
| **P1 wms2-api** | `wms2-api` `feature/SBDEV-3132-p1-api` off `a49cc458` | **on dev** — [PR #577](https://github.com/SiteBossInc/wms2-api/pull/577) merged as `ce20ee89` (2026-10-28), dev serves `develop-ce20ee89` | commits `8357bffc` feat · `1c139ae2` `c2cefdfb` `6b872a4b` review fixes · `0c27cbd4` tests · `21e63023` deslop |
| P2 ScanInput / dialog / rail | `wms2-mobile-ui` | **on dev — wms2-mobile-ui #99 merged as 54b481e7 (2026-10-28; Docker develop build success, dev bundle serves P2 code)**: built ahead of P0 with Nam's OK. Only the `fake` (test-only) detection strategy plus the fail-closed default ship, so the flag must stay off until P0's strategy lands. Commits `25aa820`, `989ff7c`, `ba7d2db`, `7a94839` on `feature/SBDEV-3132-p2-scaninput`. Jest 65 suites / 921 tests / 0 failures (base 58 / 760 / 0). Conformance PASS; code and security review findings all fixed (2 Mediums — the shared dialog-lock flag, found by both, and autofill M2, fixed as a masked field per Nam — plus every Low); 2 re-review rounds APPROVE. Reports: `.omc/research/SBDEV-3132-p2-*.md` | worktree `.claude/worktrees/wms2-mobile-ui/SBDEV-3132` |
| P3–P9 identity-field migration | `wms2-mobile-ui` | not started | — |

**P1 merge (2026-10-28, `wms-merge`):** re-graded on current develop `27231419` (10 newer commits: SBDEV-3929/3930/3940) via merge commit `ea5f42cf`, no conflicts; CI run 40646710247 green and local `mvn clean verify -Pci` 9179 unit / 1060 IT, 0 failures. Merged pinned to `ea5f42cf` → merge commit `ce20ee89`; develop push run 40649579376 test+build green; dev `/api/public/version` = `develop-ce20ee89…`. Dev DB (`dev_wh01_om1`): `flyway_schema_history` 2.2.42 success 07:40 UTC, table `mobile_manual_entry_override` present (0 rows), function granted to inventory-manager/outbound-manager/super-admin only, sysprops false/10/15. Doc markers flipped (15 in 5 files). CI fix before merge: `9c8e5c32` (collision script `LC_ALL=C`; glibc en_US collation let `[A-Za-z]` match `é`).

**P1 verification (2026-10-28):** full `mvn test` 9175 run / 0 failures / 0 errors (baseline 8928 on `a49cc458`); `ManualEntryOverrideThrottleIT` + `ManualEntryOverrideMigrationIT` 49 / 0; collision `--self-test` 14/14 on `/bin/bash` 3.2 and bash 5; PIT 100% on service, controller, limits, verifier 87/88 (survivor `setDaemon`, unobservable); every new assertion hand-mutated. Reviews: conformance + code + security, then three scoped re-review rounds, all findings fixed incl. Lows, final verdicts APPROVE. Reports: `.omc/research/SBDEV-3132-p1-{impl-report,conformance,code-review,security-review,fix-report,code-rereview,security-rereview,fix2-report,code-rereview2,security-rereview2,rereview3,deslop,doc-drift}.md`.

**Nam's implementation-time decisions (2026-10-28):** (A) an approval resets only its own pair bucket; the picker bucket is time-only; (B) approver cap default 25 → 10 with the per-realm rule in the sysprop description; (C) rows decided before Keycloak capped at 30 per picker per 10 min. Approved the `GUARDED` `hasSize(16 → 17)` change.

**Still open before the PRD flag flip:** O2 (WineCo PRD restricted/exempt counts), O4 (per PRD/UAT realm: brute-force lockout + direct grants on, issuer matches, **built-in direct-grant flow** — review S-N-L1 — and cap × facilities < `failureFactor` − 5), and a dev probe for any non-`invalid_grant` 400 a picker's input can trigger (review C-OQ-2). Docs updated with `✓ merged(SBDEV-3132: #577 ce20ee89, 2026-10-28)`: sysprop catalog, role matrix, function-to-docs map, scheduled-jobs catalog.

Amendments below are marked **⚠ Amended 2026-10-28** in place; the original text is kept.


## RALPLAN-DR summary

**Principles**
1. **Honest boundary.** This is a client-side deterrent plus an audit trail, never proof of a physical scan (§1, §6).
2. **One enforcement point.** One extended `ScanInput`, enforced by a Jest rail that sees every input tag (P2-RAIL).
3. **The server owns the decision and the credential.**
   - The server decides who is restricted.
   - The approver is verified over a certificate-verifying client.
   - The token never leaves the server.
   - No secret reaches a log or RUM, including through the axios plugin (cN1).
4. **Off by default, reversible.**
   - The sysprop defaults to `false`.
   - A flip reaches every device **that can reach the API** within ≤3 min (2 min server cache + 60 s client refetch).
   - Policy uncertainty never rejects a real scan (§3.6).
5. **Measure the device first.** The detection signal is a pluggable strategy chosen by P0.

**Drivers**
1. No casual typing or pasting of identity values, and scanning unchanged.
2. No new password oracle, token, log or RUM leak, and **no lockout amplifier beyond Keycloak's own** (cN12), following the P26/P27 lessons.
3. The rollout never blocks the floor.

**Viable options**

| Option | Pros | Cons (bounded) |
|---|---|---|
| **A. One ScanInput + server `scanPolicy` + server-verified ROPC override + audit** (chosen) | Reuses existing seams. The one server step is audited, throttled and serialised. No mutable JVM state | Bypassed by devtools, a prefix-programmed keyboard, or a hand-typed printable prefix (P0 must close the last). 33 sites over 7 PRs. The SSO password is typed on a shared device |
| **B. Override token on every identity handler** | The server could reject typed submits *if* it could tell them apart | It can't: a scan carries no proof either. ~40–60 handler signatures (estimate, not enumerated). **Rejected** |
| **C. A with a WMS-held PIN** | No SSO password on the floor | A new secret store, hashing, enrolment and reset, plus an app lockout over a 10⁴–10⁶ space. **Fallback** |
| **D. A as a directive** | Smaller per-site diff | No home for the dialog state; fights Vuetify input handling. **Rejected** |
| **E. Device-only lock-down (EB/MDM)** | No code | Per device, not per user; no exemption, audit or override. **Supplement** (P0 item 6) |

**Pre-mortem**

| # | Failure | Prevent | Recover |
|---|---|---|---|
| 1 | Every scan reads as typed on flip day. Causes: an IME-text wedge, an unprovisioned device, or too strict a timing rule | P0 device measurement; UAT flip first; §5.1 row 2 | Flip off. Takes ≤3 min with no reload (P2-S6, M9) |
| 2 | Manager lockout or credential exposure | Advisory-locked, IdP-attempt-only throttles plus an exempt pre-check before any IdP call (§3.3); constant `X-Authz-Denied`, so no axios retry; no axios-retry opt-out (cN1); Keycloak temporary lockout as a release gate | Admin clears the lockout or waits out the window; flip off for the shift; DENIED rows (§7.4) name the picker; reset the password if exposed |
| 3 | Partial migration with the flag on, and "zero overrides" reads as success | Pending = 0 before any PRD flip; the rail sees every tag | Flip off, add the site to pending, migrate it, flip again |
| 4 | Every scan rejected on flag-off tenants (cH2) | Unknown policy = `guarded`, which never rejects (P2-S5); typed Enter still submits in `off`/`guarded` (P2-R14, aN7) | Code defect: revert the workflow PR. M15 checks it on a device |

**Expanded test plan** (detail in §5.2 and §7)
- **Unit:** JUnit P1-A1…A10; Jest ScanInput/detector/dialog/store/reducer specs through the real `plugins/axios.js` and reducer; P2-RAIL.
- **Integration:** `ManualEntryOverrideMigrationIT`, plus `ManualEntryOverrideThrottleIT` (boundaries, reset, deterministic race, `pg_locks`); collision `--self-test`.
- **Browser and device:** HB-1 (local, at P3/P5/P7), the §7.3 manual plan with counts, and a Honeywell pass (P0, M11). **No CI e2e is claimed.**
- **Observability:** the audit table and the §7.4 queries (per approver, per picker, per workflow, stranded `PENDING`); one INFO line; RUM events.

---|---|
| Unit, JUnit | `MobileForceScanControllerUnitTest`, `ManualEntryOverrideServiceUnitTest`, `KeycloakPasswordVerifierUnitTest` (HTTPS mock + positive TLS control, real `NimbusJwtDecoder`, discovery issuer), `ManualEntryOverrideLoggingUnitTest`, `ManualEntryOverrideTxBoundaryTest`, `ForceScanSeedConsistencyTest`, rails |
| Unit, Jest | ScanInput, detector, dialog, store and reducer specs through the **real** `plugins/axios.js` and the real reducer; the rail; per-workflow specs |
| Integration | `ManualEntryOverrideMigrationIT`; **`ManualEntryOverrideThrottleIT`** (boundary rows + concurrency), both Testcontainers; the collision `--self-test` |
| Browser and device | The headless check **HB-1** (local, puppeteer-core outside the repo; §5.2, cN2), the §7.3 manual plan with counts, and a Honeywell pass (P0, M11). **No CI e2e is claimed** |
| Observability | The audit table and the §7.4 queries (per approver, per picker, per workflow, stuck `PENDING`); one INFO line; RUM events for a policy 404 and for a policy stuck unknown |

---

## 0. Affected sites

**Method.** The analysis §0 census: a regex over the `<template>` of `components/**/*.vue`, `pages/*.vue` and `layouts/*.vue`, with comments stripped and hand classification.
- Controls: a raw `grep -c` agrees, ScanInput's inner field is found, and both commented-out tags are found.
- Blind spots: render functions (0 found), third-party components, and tap-only choices (rows 36–37).
- **P2-RAIL re-derives this census on every Jest run.**

| # | File | Field | Identifies | ScanInput | In scope | Phase |
|---|---|---|---|---|---|---|
| 1–2 | `cancellation/cancellationScan.vue`, `…/cancellationAction.vue` | `toteLabel`, `rtsDestination` | tote, lane | no, yes | yes | P9 |
| 3 / 3b | `cycleCount/bySku/scanUnitLoad.vue` | `scannedValue` / unit-load `v-select` | UL | yes / — | yes (3b is a bypass, R4) | P8 |
| 4–5 | `cycleCount/bySku/selectLocation.vue` (autocomplete), `cycleCount/single/scanUnitLoad.vue` | `currentLocation`, `scannedValue` | location, UL | no | yes | P8 |
| 6 | `lookup/search.vue` | `inputValue` | any id (read-only) | yes | **no** (R1) | — |
| 7–11 | `moveStock/scanSource.vue`, `moveStock/scanDestination.vue` ×2, `moveUnitload/{scanSource,scanDestination}.vue` | UL, UL, location (autocomplete), UL, location | — | #7 yes | yes | P5 |
| 12–15 | `palletizing/{scanParcel,scanPallet,rapidScanPallet,rapidScanParcel}.vue` | parcel, pallet | — | #12 yes | yes | P6 |
| 16 | `picking/scanSection.vue` (autocomplete) | section | — | no | **no** (R2) | — |
| 17–19, 21–23 | `picking/pick.vue` ×2, `picking/rapid/{scanPackage,scanSource,scanSourceSimple,verifyPackage}.vue` | location/UL, tote, package, source ×2, tote/package | — | no | yes | P3 |
| 20 | `picking/rapid/scanPackageType.vue` | package **type** | — | no | **no** (R3) | — |
| 24–27 | `putaway/{scanPallet,storePallet,storeBox,scanFlowBin}.vue` | pallet, location, box, flow-bin | — | #24 yes | yes | P4 |
| 28–31 | `replenish/request/scanLocation.vue`, `replenish/process/{selectSource,selectUnitLoad (autocomplete),selectDestination}.vue` | locations, UL | — | #28 yes | yes | P7 |
| 32–35 | `transferOrder/{scanUnitLoad (autocomplete),scanTransferLane}.vue`, `truckLoading/{scanGate,scanPallet}.vue` | UL, lane, gate, pallet | — | no | yes | P9 |
| 36 | 7 other `v-select`s (4 order pickers incl. replenish client, transfer order, SKU/position, `pages/index.vue` warehouse) | a *task* | — | — | **no** (R4) | — |
| 37 | `picking/rapid/scanSource.vue` `passScan`, `scanSourceSimple.vue` Return | skips a scan | — | — | **no** (R4) | — |
| 38 | 14 quantity/count/comment fields (analysis §0.2) | — | — | — | **no**, typeable | — |

**Rail arithmetic** (cH5, aM3; re-derived and passed by critic r2)

| Count | Composition |
|---|---|
| **60** tags scanned at P2 | `v-text-field` 39 (36 workflow + 3 in the dialog), `v-autocomplete` 5, `v-textarea` 1, `v-select` 8, `scan-input` 7. A tag-bounded `<input[\s>/]` matches 0, so `<input-amount>` is excluded |
| **33** PENDING | 26 plain or autocomplete identity fields (35 − 7 ScanInput − #16 − #20), plus the 6 `scan-input`s lacking `identity` (#2, #3, #7, #12, #24, #28), plus #3b |
| **27** PERMANENT | 14 quantity/comment, #16, #20, Lookup #6, the 7 task `v-select`s, and the 3 dialog fields |

Both lists add up to the scan: 33 + 27 = 60. The phases add up to the pending list: 6 + 4 + 5 + 4 + 4 + 4 + 6 = 33.

**Other sites**

| # | File | Construct | Phase |
|---|---|---|---|
| A1–A2 | `WmsConstants` | `MOBILE_UI_ACTION_MANUAL_ENTRY`; sysprop keys and defaults for `MOBILE_FORCE_SCAN_ENABLED`, `MOBILE_OVERRIDE_APPROVER_CAP`, `MOBILE_OVERRIDE_APPROVER_CAP_WINDOW_MIN`; per-pair and per-picker limits | P1 |
| A3 | `db/migration/V2.2.42__mobile_force_scan_manual_entry.sql` | table first, then function + grant, then 3 sysprops | P1 |
| A4 | `UtilRestController.initDB` | `grantFunction(MOBILE_UI_ACTION_MANUAL_ENTRY, role_outbound_manager, role_super_admin, role_inventory_manager)` | P1 |
| A5 | `controller/mobile/MobileForceScanController` (new; in `GUARDED`; **not** an `AdminController` subclass) | `GET /v3/mobile/scanPolicy`, `POST /v3/mobile/manualEntryOverride`, bespoke 403 writer | P1 |
| A6 | `ManualEntryOverrideService`, `…AuditService`, `KeycloakPasswordVerifier` (own `RestClient`, per-tenant discovery-backed decoder cache), entity, and repository (native advisory-lock + count queries; no `@RepositoryRestResource`) | — | P1 |
| A7–A8 | `GUARDED`, `EXPECTED_GUARDED`, `GOLDEN_MAP`, `UtilRestControllerSeedUnitTest`, `NameKeyedGrantSeedRailTest.ALLOW_LIST`, `SurfaceInventoryContextTest`, `FunctionGateBeanWiringContextLoadTest` | rail updates | P1 |
| A9 | `db/check-migration-version-collision.sh` (`declare -A` ×3) | rewrite for bash 3.2 + `--self-test` | P1 |
| A10 | `TokenController` (P26), `SecurityConfiguration` `restClient` (P27), `AuthzDenialWriter` | **not changed and not reused** | — |
| M1 | mobile `plugins/persistedState.client.js` reducer `({ warehouseTimezone, selectedWarehouse, warehouses, cancellation, ...persisted })` | exclude `scanPolicy`; boot reset | P2 |

---

## 1. Problem Statement

WineCo wants operators stopped from typing or pasting identity values, with an authorized override and the desktop untouched.

**Today:** All 35 free-text identity inputs accept typing; Even `ScanInput` lets paste, IME and autofill reach the parent `v-model` via `v-on="$listeners"`; `handleGlobalKeydown` treats keypad and wedge keys identically; A 365-day cookie and an `mdi-keyboard` toggle unlock typing on purpose; No sysprop, function or audit exists: both counts are 0 on dev (§2.4).

**Framing (decision 8).** This **prevents casual manual entry by restricted users and audits sanctioned exceptions**. It does **not** guarantee a physical scan, because the server receives plain strings.

**Residual risk.** None of these leaves an audit row, so zero overrides is not evidence of zero manual entry: devtools or `localStorage` edits; a keyboard programmed with the prefix; **hand-typing a printable prefix** (P0 must pick a non-typeable signal, or prefix ∧ timing; aM4); fast typing against a timing-only strategy; API replay with the user's own token; typing during the `guarded` pre-load window on a flag-on tenant (cN11, §6).

---

## 2. Current Architecture

### 2.1 Mobile (`1497c3b`)

**`ScanInput.vue`**: It wraps `v-text-field` with `v-bind="$attrs" v-on="$listeners"`, so the parent's `v-model` `input` and `change` handlers are forwarded to the inner field (aH2); **Capture.** Each instance adds a `window` keydown listener. In scanner mode, `handleGlobalKeydown` calls `event.preventDefault()` on **every** keydown, buffers it, and debounces `$emit('input', …)` (aH3, cH1); **Enter.** It emits the literal `$emit('keyup.enter', …)`, which a parent's `@keyup.enter` never matches. The real multi-fire comes from multiple mounted instances (aL7). In keyboard mode, a typed Enter goes through `handleKeydownInField` and emits that same literal (aN7); **Buffer.** `this.inputBuffer = this.localValue` after a submit, so the next scan appends.

**Persisted state.**: `functions` is not persisted: `stripAuthzState` drops it, and boot commits `home/setFunctions([])`; The reducer is a **blacklist**, so a new module is persisted unless it is excluded (aH4, cH4).

**Transport (`plugins/axios.js`, axios-retry 4.5.0)**: `retries: 3`; `retryCondition` retries a 401/403 without `x-authz-denied`. It never retries a 503 or a network error; `onError` toasts `authzDenialMessage(body)` whenever `status === 403 && body.reason`; `onMaxRetryTimesExceeded` runs once `retryCount >= retries`. It redacts the Authorization header only, then `console.error(…, error)` (which carries `config.data`), then toasts "Application will log out", then calls `app.$kc.logout()` after 3 s; `util/telemetry.js` sets `forwardErrorsToLogs: true`; **Critic r2 executed this:** a per-request `retries: 0` fires that hook on the **first** failure, with the password in `config.data` (cN1).

**Tests.**: Jest runs in jsdom (`roots: ['<rootDir>/test']`). Baseline: 58 suites, 718 tests, 3 load failures from a stale `node_modules`; re-measure; Playwright: `playwright.yml` triggers on `main`/`master`. `origin/main` **is used**: it is the release branch, last merged 2026-10-21. The lane has **0 passes in its last 31 runs** (22 failed, 9 cancelled at 60 min): The lane logs into the real `kc2.dev.sbo.li` realm as `testuser`; It mocks only `authConfig`; The r2 claim "a branch this repo does not use" was false (cN2).

### 2.2 wms2-api (`bb3e3580`)

**Gating**: `FunctionGuardInterceptor` resolves `@PublicHandler` → method → class `@RequiresFunction`; `GUARDED` (16 classes, all 11 `controller.mobile.*`) fails closed; The principal is `preferred_username`, as built by `JwtAccessTokenCustomizer.convert`; `MOBILE_UI_LOG_IN` gates no controller today, so this use is new; §2.4 supports it; 10 of the 11 mobile controllers extend `AdminController`. Its inherited handlers resolve outside `GUARDED` (cL3).

**Users**: `UserRepository.getAllRoles` is native SQL with `where u.name = :username`, which is **case-sensitive**; On dev, 44 of 100 `mywms_user.name` values contain upper case, but all 46 users in R8 roles are lowercase. No name contains `@` (critic r2 query); Keycloak usernames are lowercase (aN4, cN3).

**Sysprop**: `getSysvalue` is `@Cacheable(value="sysprops", key = TenantKeyBuilder.cacheKey(...) + ':' + #key, unless = "#result == null")`, with a 2-minute TTL (`buildCaffeineCache("sysprops", 200, Duration.ofMinutes(2))`); `getStringDefault` inserts on a miss, so it is not used.

**Keycloak**: `getCurrentTenantAuthConfig()` and `getTokenUri(config)` give a per-tenant realm; `TokenController` posts through the shared `restClient`, which trusts every certificate (`acceptingTrustStrategy = (cert, authType) -> true`, `NoopHostnameVerifier.INSTANCE`) and sets **no timeouts** (P27); `TokenController` also has the P26 flaws; `MultiTenantJwtDecoder` uses `NimbusJwtDecoder.withJwkSetUri(…).build()`: it checks the signature and timestamps, **not the issuer**. It caches decoders per tenant for 24 h.

**Issuer measured on dev (2026-10-27, aN6)**: In landlord-dev, every one of the 4 tenants has `server_url = https://kc2.dev.sbo.li`; `GET …/realms/{wineco,hydra}/.well-known/openid-configuration` returns `issuer` = `https://kc2.dev.sbo.li/realms/<realm>`, which equals the derived value **on dev**; UAT and PRD are not measured.

**Errors**: `MobileEndpointExceptionHandler` (`basePackages = "net.aim_ai.wms.controller.mobile"`) logs `ex.getMessage()` in `handleBadRequest` (cL2); `AuthzDenialWriter.write` emits a root `reason` (`problem.put("reason", …)`), sets `X-Authz-Denied` to the required function or the reason name, and increments `wms2.authz.denied`. **Not reused** (aN3, cN5).

**Precedents**: `V2.2.13` `putaway_config_audit` + `PutawayConfigAudit` (`IDENTITY`); `V2.2.38` + `CancellationRtsDestinationMigrationIT`; `V2.2.41` + `*SeedConsistencyTest`; SDR uses `RepositoryDetectionStrategies.ANNOTATED`.

### 2.3 Flyway
- The highest version is `V2.2.41`. Two sweeps agree: 476 refs (positive control 422) and 477 refs (positive control 423).
- The collision script fails on bash 3.2 at `declare -A`, and fails closed (`FATAL: found ZERO migration versions`).
- `.claude/scripts/portability-check.sh` does not cover it, because owl's `.gitignore` ignores `v2/` (cL13).

### 2.4 DB facts: wineco dev `dev_wh01_om1`, 2026-10-26
The first call dropped; one retry succeeded.

| Query | Result |
|---|---|
| force-scan sysprop · control `MOBILE_UI_URL` | **0** · 1 |
| `MANUAL_ENTRY` function · control `MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION` | **0** · 1 |
| Flyway max | `2.2.41` |
| users with `MOBILE_UI_LOG_IN` / any `MOBILE_UI_VIEW_%` / `…_VIEW_PICKING` (via group→role) | 52 / 51 / 50 |
| mobile-view users **without** `MOBILE_UI_LOG_IN` | **0**, so the gate is valid on dev |
| R8-role users / mobile-view users outside the R8 roles | 46 / **5** |
| `panderson` roles (critic r1) | `ROLE000088, super-admin` → exempt; the M4 approver |
| `Operation Options` sysprops · open unassigned `pickingorder` (state < 600) · located, labelled `unitload` | 43 · **11** · 759,943 |

PRD is not measured: `wsl-wineco-prd` got CONNECT_TIMEOUT (O2).

---

## 3. Design

### 3.1 Switch and exempt function (P1)

**`MOBILE_FORCE_SCAN_ENABLED`**: Seeded as `"false"`, group `Operation Options`, client 0, `DEFAULT`, in the V2.2.41 shape; Read with `getSysvalue` only. On = `trim().equalsIgnoreCase("true")`; Visible on the desktop Parameters screen (decision 9).

**Throttle sysprops** (§3.3), seeded at Keycloak defaults minus a margin:
- `MOBILE_OVERRIDE_APPROVER_CAP` = `25` (default `failureFactor` 30 − 5).
  > ⚠ **Amended 2026-10-28 (implementation, Nam):** default is **`10`**, not 25. A multi-facility tenant shares one realm, so the operator rule (now in the sysprop description) is cap × facilities on that realm < `failureFactor` − 5, per window; Keycloak keeps failures ~12 h, so consecutive windows add up.
- `MOBILE_OVERRIDE_APPROVER_CAP_WINDOW_MIN` = `15` (default Keycloak `maxFailureWait`, 15 min). **R10′, Nam 2026-10-27, was O5.**
- Parsed with `getIntValue(key, default)` and **clamped** (aC4): cap ∈ [1, 100], window ∈ [10, 1440] min. An unparseable or out-of-range value falls back to the seeded default, with one WARN per replica per hour. A mis-set `0` can therefore neither throttle everything nor disable the throttle.
  > ⚠ **Amended 2026-10-28:** parsed from `getSysvalue` directly, not `getIntValue`: `getIntValue` swallows a bad value, so the required WARN could never fire.
- Both rows appear on the desktop Parameters screen. An admin who raises the cap weakens the protection; that is an accepted admin power.

At release they are set per tenant from the M6 read: cap = ⌊(`failureFactor` − 5) / facilities sharing the realm⌋. ShipItEZ has 2 facilities on one realm, and the audit table is per facility DB.

**Function `MOBILE_UI_ACTION_MANUAL_ENTRY`** (R6)
- The constant, a V2.2.42 row plus grant, and the `initDB` line.
- The **R8** grant goes to `super-admin`, `outbound-manager` and `inventory-manager`. The migration's `IN (…)` must equal the `initDB` varargs.

### 3.2 `GET /v3/mobile/scanPolicy`
- **Gate:** `MobileForceScanController`, `@RequiresFunction(MOBILE_UI_LOG_IN)` at class level, in `GUARDED` and `GOLDEN_MAP`. It is not a `@PublicHandler` and not an `AdminController` subclass.
- **Response:** `{ restricted, detection }`, where `restricted = flagOn && !doesUserHaveAnyAccess(caller, MOBILE_UI_ACTION_MANUAL_ENTRY)`.
- The caller comes from the SecurityContext. No raw sysprop is returned. Read-only.
- Detection params are seeded only if P0 needs them.

### 3.3 `POST /v3/mobile/manualEntryOverride`

**Gate and request**
- Same gate; JSON only.
- Every check runs **in the service**, so every rejection is audited (cN9). There is no `@Pattern`/`@Valid` 400.
- The entered name is normalised with `trim().toLowerCase(Locale.ROOT)` **before every step and before storage** (aN4, cN3), then must match `^[a-z0-9._-]{1,64}$`. There is no `@`, so email logins are unsupported (dev has none).
- `workflow` and `field` must match `^[A-Za-z0-9_.-]{1,64}$`; `value` is 1–255 characters.
- `password` is `WRITE_ONLY` and excluded from `toString()`.

**`approve(caller, req)`**
- Not `@Transactional` (P1-A10).
- Tx1 and Tx2 are sequential, top-level, short `tenantTransactionManager` transactions on `ManualEntryOverrideAuditService`, called through the Spring proxy.
- **Lock placement (aC2):** the advisory locks, the three counts and the insert run as `@Query(nativeQuery = true)` methods on the **tenant** repository, i.e. the tenant `EntityManager`, inside Tx1. Never a context `JdbcTemplate` (landlord pool), a bare `@PersistenceContext` (landlord EM) or a bare `@Transactional` (landlord manager in `service`). Only the tenant EMF carries `LockTimeoutHibernateJpaDialect` (`TenantDatabaseConfig`), so this is also what bounds the lock wait with `SET LOCAL lock_timeout`.
- **No `REQUIRES_NEW` runs inside a lock-holding transaction** (memory trap).
- **The Keycloak call runs between Tx1 and Tx2, with no DB connection held.**

| Step | What | Outcome | Row |
|---|---|---|---|
| 0 | `workflow`/`field`/`value` outside its shape (R11) → **400**, constant body | `DENIED_INVALID` | one-shot insert, `idp_attempted=false`, `entered_value='<invalid>'` |
| 1 | name fails the regex · name == caller | `DENIED_CREDENTIALS` · `DENIED_SELF` | one-shot insert, `idp_attempted=false` |
| 2 | **Exempt pre-check** on the normalised name; non-managers never reach Keycloak | `DENIED_NOT_EXEMPT` | same |
| 3 | `authConfig` null or blank secret | `ERROR_IDP` | same |
| 4 | **Tx1, the throttle gate** (aN1, aN2, cN4): (a) `pg_advisory_xact_lock(:ns, hashtext(:approver))`, then `pg_advisory_xact_lock(:ns2, hashtext(:picker))`, always in this fixed order. Advisory locks are per database, so the key is effectively (tenant-facility, approver). (b) Count the three buckets (below). (c) Run the package-private `afterCountHook`, a no-op in production and a test seam for P1-A12 (cC1). (d) If a bucket is at its limit, insert `DENIED_THROTTLED`; otherwise insert `PENDING` (`idp_attempted=true`). (e) Commit, which releases the locks. **Any Tx1 failure** (`lock_timeout` SQLSTATE `55P03`, a connection error, anything else) → 503 with the generic body, **no IdP call**, and a best-effort one-shot `ERROR_IDP` row in a fresh short transaction. It never reaches `handleUnexpected`'s 500 (aL-a, cL4) | `DENIED_THROTTLED`, continue, or 503 | insert |
| 5 | `KeycloakPasswordVerifier`: ROPC to `getTokenUri` with the backend client over a **dedicated `RestClient`** (JVM default trust, hostname verification, connect ≤2 s, response ≤5 s, small pool; **never** `restClient`, P27). No `scope` | 400/401 → `DENIED_CREDENTIALS`; timeout, 5xx, TLS or any exception → `ERROR_IDP` | — |
> ⚠ **Amended 2026-10-28 (review C-M1/S-L3, S-N-M1):** only OAuth `invalid_grant` is a credential failure (`DENIED_CREDENTIALS`). `invalid_client`, `unauthorized_client`, `unsupported_grant_type` → new outcome **`ERROR_IDP_CONFIG`** (503, WARN with the code only, never counted, and it opens a 60 s per-tenant breaker that answers every name the same 503 without calling Keycloak). Any other or unreadable 400/401 → counted `ERROR_IDP`. The client is the JDK `HttpClient` (HTTP/1.1), not a `RestClient`; the Keycloak URL must be https and discovered endpoints must share its scheme/host/port.
| 6 | Decode with the verifier's per-tenant decoder. On a cache miss it fetches discovery (`GET {serverUrl}/realms/{realm}/.well-known/openid-configuration`) **and** the JWKS, **both over the verifying client** (aC3). The JWKS goes through `NimbusJwtDecoder.withJwkSetUri(jwksUri).restOperations(<RestTemplate over the verifying client's request factory, same timeouts>)`, because Nimbus's default `RestTemplate` has no timeout. Validators: signature, timestamps, `createDefaultWithIssuer(discovered issuer)`. The 24 h per-tenant Caffeine cache is evicted on a signature or issuer failure, **never on a `JwtTimestampValidator` failure** (a refetch cannot fix clock skew), and **at most once per tenant per 5 min**. Never through `JwtAccessTokenCustomizer`. Best-effort `logout`, **then both tokens are dropped** | missing `preferred_username` → `ERROR_IDP` | — |
| 7 | token name == caller (defence in depth) | `DENIED_SELF` | — |
| 8 | token name not exempt | `DENIED_NOT_EXEMPT` | — |
| 9 | **Tx2:** `UPDATE` the `PENDING` row to its outcome (`approver` = the token name when present). **200 only after an `APPROVED` update commits.** Any Tx2 failure → 503 and no unlock (aM5). A row left `PENDING` (hard kill only, §3.4) counts until it ages out (fail closed) | final outcome | `UPDATE` |

**Throttle buckets (aC1, cC3)**
- **What counts:** only rows Keycloak counts. The predicate is `outcome IN ('DENIED_CREDENTIALS','PENDING') AND created_at > :now - :window`.
- **What does not count:** `ERROR_IDP` (an outage Keycloak never recorded), post-token `DENIED_SELF`/`DENIED_NOT_EXEMPT` (Keycloak saw a *success*), `DENIED_THROTTLED`, the pre-check denials and `'<unrecognised>'`.
- `idp_attempted` is kept as an audit attribute only.
- **Reset on success:** each bucket counts only rows **after the most recent `APPROVED` row in its key**, mirroring Keycloak's counter reset: `created_at > coalesce((SELECT max(created_at) … WHERE <key> AND outcome='APPROVED'), :now - :window)`. The existing `(approver_entered, created_at DESC)` and `(picker, created_at DESC)` indexes serve it.
  > ⚠ **Amended 2026-10-28 (implementation D3 + Nam, decision A):** the buckets count only rows with `idp_attempted` and outcome in (`DENIED_CREDENTIALS`, `PENDING`, `ERROR_IDP`), created after `GREATEST(window start, last APPROVED in the key)` — the `coalesce` form above drops the window once any `APPROVED` exists. **Pair** resets on an `APPROVED` for the same (picker, approver); **picker** never resets (time only); **global approver** keeps the reset (mirrors Keycloak). Rows decided before Keycloak (incl. breaker answers) are capped at 30 per picker per 10 min; beyond that the response is unchanged and no row is written.
- **The clock:** `:now` is bound from an injected `java.time.Clock` (cC2), so the IT pins it exactly.

| Bucket | Key | Limit | Window |
|---|---|---|---|
| pair | (approver, picker) | 3 | 10 min |
| picker | picker | 5 | 10 min |
| approver (global; the only bucket shared across pickers) | approver | `MOBILE_OVERRIDE_APPROVER_CAP` (clamped) | `…_WINDOW_MIN` (clamped) |

- A bucket is throttled when its count is **≥ its limit**.
- The throttle cannot feed itself, because throttled rows never count.
- **Honest bound (cC3):** in a 15-min window (R10′), one picker is held to 3 per pair and 5 per picker per 10 min, so filling the cap of 25 takes about 5 pickers acting together. If they do, manager X's *overrides* are blocked for the rest of that window. That is strictly better than the realm-wide Keycloak lockout the same attempts would cause, which also locks X out of the web UI. With the 15-min window (R10′) the block lasts no longer than Keycloak's own temporary lockout. **The accepted cost:** the app cap no longer stops attempts from piling up in Keycloak's `maxDeltaTime` (12 h) counter. A single picker kept within the pair limit (3 per 10 min) can still reach `failureFactor` 30 in about 100 min and cause a realm-wide *temporary* lockout of manager X (≤`maxFailureWait`). Each of those attempts is a `DENIED_CREDENTIALS` row, visible in §7.4's per-picker query.
- **Pre-check spray (cL6):** pre-check denials (`idp_attempted=false`) are deliberately uncapped. They cost one indexed `getAllRoles` and one insert each, never reach Keycloak, and are visible in §7.4's per-picker query. Accepted.

**Denial response** (aN3, cN5)
- **Every** `DENIED_*` gets a **bespoke** 403 written by the controller, **not** `AuthzDenialWriter`.
- The body is the constant `{"errors":[{"type":"OVERRIDE_NOT_APPROVED","message":"Override not approved"}]}`, with **no root `reason` key**, so the axios toast does not fire.
- The header is the constant `X-Authz-Denied: MANUAL_ENTRY_OVERRIDE`, so `retryCondition` does not retry.
- No `wms2.authz.denied` increment.
- `ERROR_IDP` → 503 with a generic body. `APPROVED` → 200 `{ approved, overrideId, approver }`.
- Keycloak's text is never echoed.

**Latency signal (aN5): accepted.**: Pre-check denials return without network I/O. IdP-reaching ones take a Keycloak round trip. The difference reveals only *which names are managers*; It is throttled per picker, and the information has low value; Padding responses was considered and rejected: it holds a request thread or needs async completion, for no material gain.

**Logging**: One INFO line per attempt: `outcome= workflow= field= picker= approver=<token name, or ->`. The entered name is never logged (aL5, cL1); No stack trace is printed with a body; `handleBadRequest` must not quote the body (P1-A6).

**P26/P27 avoided:** gated (not `permitAll`); JSON only, 415 otherwise (no `@RequestParam`); the token is discarded and the session logged out; a constant 403 (no IdP body echoed); an advisory-locked throttle, pre-check and audit (P26 had no throttle); a null secret fails closed; a dedicated verifying client with timeouts (P27).
> ⚠ **Amended 2026-10-28 (review S-L9 → C-N-M1):** not 415. The handler takes no `@RequestBody`; it reads ≤16 KiB itself and parses JSON only for a JSON content type with a UTF-8 (or absent) charset. Anything else, including a form post or XML, gets the constant **400 + one `DENIED_INVALID` row**, so the attempt is audited.

### 3.4 Audit table (V2.2.42)

> ⚠ **Amended 2026-10-28:** `outcome` also takes **`ERROR_IDP_CONFIG`** (Keycloak rejected the backend client, or the breaker answered); there is no CHECK constraint on the column, so no DDL change was needed.
The `CREATE TABLE` comes first. The script runs as one Flyway transaction, so a failure leaves no partial seed.

```sql
CREATE TABLE IF NOT EXISTS public.mobile_manual_entry_override (
  id bigserial PRIMARY KEY, version integer NOT NULL DEFAULT 0,
  picker varchar(255) NOT NULL, approver varchar(255) NULL, approver_entered varchar(64) NOT NULL,
  workflow varchar(64) NOT NULL, field varchar(64) NOT NULL, entered_value varchar(255) NOT NULL,
  outcome varchar(32) NOT NULL, idp_attempted boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS mobile_manual_entry_override_approver_idx ON public.mobile_manual_entry_override (approver_entered, created_at DESC);
CREATE INDEX IF NOT EXISTS mobile_manual_entry_override_picker_idx ON public.mobile_manual_entry_override (picker, created_at DESC);
```

- **`approver_entered`** is the normalised name if it passes the regex **and** `UserRepository.findByName` finds it; otherwise `'<unrecognised>'` (aL5).
- **`approver`** is the token identity, or null.
- **`outcome`** is one of `PENDING`, `APPROVED`, `DENIED_{CREDENTIALS,SELF,NOT_EXEMPT,THROTTLED}` or `ERROR_IDP`.
- **Stranded `PENDING` (aL-b):** only a hard kill strands a row (OOM, SIGKILL, node loss). Graceful shutdown is the Spring Boot 3.5 default, and `src/main/resources` has no `server.shutdown` override; env overrides were not checked. Such a row's outcome is unknown, and it may hide a Keycloak session that was never logged out (bounded by SSO idle timeout). §7.4 lists them.
- The id is `bigserial` with `IDENTITY`. The repository has no `@RepositoryRestResource`.
- **No GRANT and no OWNER** (decision 4). Every statement is idempotent.
- The advisory-lock and count queries are native SQL, Postgres-only, and tested only through Testcontainers (§7B row 7).

### 3.5 ScanInput identity mode (P2)

**Props and mode**: New props: `identity`, `workflow`, `field`; The mode is a **computed** read of the store, not a value captured in `created()`. Listener filtering, `inputmode` and the toggle therefore update on a mounted instance (aN9); Non-identity fields are always `off`.

| Mode | When | Behaviour |
|---|---|---|
| `off` | exempt, flag off, or policy 404 (§3.6) | Today's behaviour. A typed value + Enter emits **one** `scan-submit` (aN7) |
| `guarded` | the policy for this username is not yet known | Blocks `paste`, `drop`, `contextmenu` and the paste/drop `beforeinput` events **only**. Detection never rejects; typed + Enter emits one `scan-submit` |
| `restricted` | the last successful load said `restricted:true` | Everything below |

In `restricted` mode:

**Listeners** (aH2): forward **none** of `input`, `change`, `keyup` or `keydown`. ScanInput is the sole emitter of `input`, and emits only a scan or an approved value. An unapproved native `input` is reset.

**Blocked input**: `paste`, `drop` and `contextmenu`; `beforeinput` with `insertFromPaste`, `insertFromDrop`, `insertReplacementText` or `insertFromYank`; Composition text is discarded; `inputmode="none"` and `autocomplete="off"`.

**Typing switches**: the toggle is hidden; `softKeyboardToggled`, the cookie and `forceKeyboardMode` are ignored; `window.sip.hide()`.

**Capture scope** (aH3, cH1). `handleGlobalKeydown` returns early, with no `preventDefault` and no buffering, when: (a) in identity mode, `event.target` is an editable element outside `this.$el`; or; (b) `$root.overrideDialogOpen` is set. **Every** ScanInput honours (b).

Only the active identity instance captures.

**Detection.** `createDetector(policy.detection)` returns `{ onKeydown, onInput, classify }`, built from P0's strategy, with a `fake` strategy for tests. An unknown strategy classifies every value as `typed`; that is reachable only after a successful restricted load. `readonly` is used only if P0 confirms it.

**Commit**: a scan emits **one** `scan-submit` and clears the buffer. A typed value is cleared, and the field shows "Scan required" plus a **Manager override** button.

### 3.6 Dialog and policy store (P2)

**`ManualEntryOverrideDialog.vue`**
- **Keyboard:** on open, set `$root.overrideDialogOpen` and call `window.sip.show()`. On close or `beforeDestroy`, clear the flag and call `sip.hide()`.
- **Fields:** the value first (R7), then a **"WMS username"** field (`autocapitalize="none" autocorrect="off" spellcheck="false"`; aN4, cN3), then the manager's password in a **masked plain-text field** (`type="text"`, `-webkit-text-security: disc`, `autocomplete="one-time-code"`, no `<form>`). *Changed 2026-10-28 by Nam (P2 security review M2): the original `type="password"` + `autocomplete="off"` pair is ignored by Chrome/Android autofill, which could save a manager's login on a shared handheld. Device check: P0 report step 11.*
- **Request:** POST JSON to `mobile/manualEntryOverride` (the `baseURL` already ends in `/v3`).
- **No axios-retry override (cN1).** The constant `X-Authz-Denied` already stops the retry, and `retryCondition` never retries a 503 or a network error. `retryCount 0 < 3`, so `onMaxRetryTimesExceeded` never runs.
- **Responses:**
  - 200 → set the value, one `scan-submit`, re-lock.
  - 403 with the override header → generic message. After **3 consecutive** ones: "Override not approved — check the manager's username, password and permission" (cL7). A gate 403 (body with `reason`) is excluded from that counter.
  - 503 → generic message.
- **The password** lives only in component `data` and is cleared on close, submit and unmount. The catch deletes `error.config.data` and `error.response?.config?.data` before rethrowing (belt-and-braces).

**`store/scanPolicy.js`**: **State:** `{ username, mode, detection, fetchedAt, consecutive404 }`; **Getter** `scanPolicy/restricted` = `mode === 'restricted'` (cN10); **Not persisted:** it is excluded in the reducer, and `scanPolicy/reset` is committed on boot (aH4, cH4); **Fetch triggers:** after `ensureRolesLoaded`; on a username change (reset to `guarded`); on workflow route entry; on `visibilitychange` → visible (EB suspends timers while backgrounded, cN7); and every 60 s while an identity ScanInput is mounted.

| Result | Mode |
|---|---|
| 200 | `off` / `restricted`; `consecutive404 = 0` |
| 404, no prior success | `off` + RUM `force-scan-policy-404` |
| 404 after a success | keep the mode until **3 consecutive interval-tick** 404s spanning ≥2 min (route-entry and `visibilitychange` 404s are not counted), then `off` + the RUM event (aN8, cL3). The branch is time-boxed (ADR follow-up 5) |
| 5xx, network, 401, 403 before any success | stays `guarded`; a RUM event after 2 min |
| any error after a success | keeps the last-known mode |

### 3.7 Workflow migration (P3–P9)
**Order:** §5.2's order, picking first. There is no PRD flip before pending reaches 0. **The later-merging PR rebases the rail literal.**

**Per PR:**
1. Write a characterization spec on the **unmigrated** component, covering a **scanned** entry **and a typed entry** (aN7, cL7), and get it green.
2. Convert fields to `<scan-input identity workflow field @scan-submit>`.
3. Preserve the `onLocationChange` / `locationChanged` lookups.
4. Validate autocompletes against their option list; hide the dropdown when restricted.
5. Gate #3b with `v-if="!$store.getters['scanPolicy/restricted']"`.
6. Lower the rail literal.

### 3.8 Collision script
1. **Characterize first** (cM6). `--self-test` passes on the **current** script under Linux bash 5 for six cases:
   - (a) the same file on many branches;
   - (b) a collision already resolved by develop;
   - (c) `TAKEN (merged)`;
   - (d) `TAKEN (in flight)`;
   - (e) `FREE (yours)`;
   - (f) zero versions → exit 2.
2. **Fixture:** a `file://` bare origin, a clone and pushes.
3. **Rewrite:** replace the three associative arrays with `version|file|branch` temp lines and `sort -u`/`awk`. Herestrings are fine on 3.2. Keep both exit-2 guards.

---

## 4. File Change Summary

| Repo | File(s) | Change | Description |
|---|---|---|---|
| api | `WmsConstants`, `UtilRestController` (`initDB`), `FunctionGuardInterceptor` (`GUARDED`) | Modify | Function constant, 3 sysprop keys/defaults, limits; one `grantFunction` line; `GUARDED` +1 |
| api | `db/migration/V2.2.42__mobile_force_scan_manual_entry.sql` | Add | Audit table + indexes; function row + R8 grant; 3 sysprop seeds |
| api | `MobileForceScanController`, `ManualEntryOverride{Request,Response}` | Add | Two endpoints; bespoke 403; `WRITE_ONLY` password |
| api | `ManualEntryOverrideService`, `…AuditService`, `KeycloakPasswordVerifier` | Add | Orchestration (no tx); Tx1 lock/count/insert + `afterCountHook`, Tx2 update; verifying client, discovery + JWKS, decoder cache, logout |
| api | `ManualEntryOverride` entity + repository | Add | Tenant-EM native lock and bucket queries; not SDR-exported |
| api | `db/check-migration-version-collision.sh`; tests (§5.2) | Modify / Add | bash 3.2 + `--self-test`; units, 2 ITs, rails |
| mobile | `ScanInput.vue`, `plugins/persistedState.client.js` | Modify | Identity modes, capture scope, `scan-submit`; exclude + reset `scanPolicy` |
| mobile | `ManualEntryOverrideDialog.vue`, `store/scanPolicy.js`, `util/scanDetection/*.js`, `test/**` | Add | Dialog; policy store + getter; detectors; Jest specs + rail |
| mobile | 30 workflow components (§0) | Modify | One workflow per PR |
| docs | `wms2-sysprop-catalog.md` §11, `wms2-keycloak-role-matrix.md` §3.8, `wms2-rest-api-reference.md` | Modify | P1 |

---

## 5. Prerequisites & Phased Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner |
|---|---|---|---|
| 1 | **DB state** | Tenants at ≥ V2.2.41. Confirm V2.2.42 is **free** with the fixed script at P1 PR open **and** before merge | P1 |
| 2 | **Feature flag** | Seeded `false`. Flip a tenant on only when: (a) devices are provisioned (P0); (b) pending = 0; (c) R8 or manager roles are assigned; (d) M11 is green. Flip and rollback take ≤3 min with no reload, for devices that reach the API | Nam / tenant admin |
| 3 | **Config** | The verifier gets its **own** `RestClient` (default trust, hostname verification, ≤2 s / ≤5 s). Never `restClient` (P27) | P1 |
| 4 | **Deploy order** | API first is preferred. Mobile first is safe, because a 404 means `off`. Merging to `develop` triggers a dev deploy and a Flyway run | — |
| 5 | **Data migration** | None beyond V2.2.42. Optionally a DBA `GRANT SELECT` to `wineco` for reporting | DBA (Joe) |
| 6 | **Keycloak: P1 PRD release gate.** P2–P9 do not wait | Every PRD realm: (i) brute-force detection ON with **temporary** lockout; (ii) direct-access grants ON for the backend client; (iii) no OTP or required actions for approvers; (iv) **on dev, UAT and PRD** (aN6), discovery `issuer` equals the token's `iss`, and the token carries `preferred_username`. Record a one-line probe per environment in the P1 PR (dev already measured, §2.2); (v) set the approver-cap sysprops from `failureFactor` / `maxDeltaTime` / the facility count (§3.1) | Keycloak admin + P1 |
| 6b | **Devices** | P0's signal provisioned per app profile; no desktop station shares it | WineCo ops |
| 7 | **Access** | R8 grant via V2.2.42 + `initDB`; further roles through the role UI | tenant admin |
| 8 | **Monitoring** | The §7.4 queries go into the WineCo runbook | P1 |

### 5.2 Phases

| Phase | Branch | Scope | Risk | Effort |
|---|---|---|---|---|
| P0 | none (report in `sbdocs/3-Resources/reports/`) | device spike | — | ½ d + device |
| P1 | wms2-api `feature/SBDEV-3132-p1-api` | §3.1–3.4, §3.8, rails, docs | High | 3 d |
| P2 | mobile `feature/SBDEV-3132-p2-scaninput` | §3.5–3.6, rail, reducer, HB-1 script | Medium | 2.5 d |
| P3 / P4 / P5 | `…-p3-picking` / `…-p4-putaway` / `…-p5-move` | 17–19, 21–23 / 24–27 / 7–11 | High / Med / Med | 1 / ½ / 1 d |
| P6 / P7 / P8 / P9 | `…-p6-palletizing` / `…-p7-replenish` / `…-p8-cyclecount` / `…-p9-transfer-truck-rts` | 12–15 / 28–31 / 3, 3b, 4, 5 / 1, 2, 32–35 | Med | ½ / 1 / 1 / 1 d |

#### P0: device spike
- **Harness:** a throwaway page in Enterprise Browser on a WineCo Honeywell. It logs `keydown`/`keypress`/`input`/`beforeinput`/`composition*` with `performance.now()`, `key`, `keyCode`, `inputType` and `isComposing`, and probes `window.sip` and any EB scan API.
- **Exit criteria, recorded as numbers:**
  1. delivery mode;
  2. native callback;
  3. whether a per-app prefix can be set, and whether it can be **non-typeable** (aM4);
  4. inter-key gap median and p95 over ≥30 scans vs ≥30 fast-typed entries;
  5. whether `readonly` still receives keydown;
  6. EB/MDM clipboard and SIP lock-down;
  7. whether desktop stations share scanners.
- **Choice:** native > per-app prefix (non-typeable, or prefix ∧ timing) > timing. If nothing works, **return to Nam**.

#### P1 acceptance criteria

**P1-A1 `MobileForceScanControllerUnitTest`** (`setupMockMvcWithGuard`)
- `"true"`, `"TRUE"` and `" true "` → on; `"yes"`, `"false"` and absent → off.
- on + not exempt → `restricted:true`; on + exempt → `false`; off + not exempt → `false`.
- No `MOBILE_UI_LOG_IN` → 403 (the gate's own `AuthzDenialWriter` body, with `reason`).
- The response keys are exactly `restricted` and `detection`.

**P1-A2** `never()` on both `getStringDefault` overloads; `getSysvalue` is called with the key.

**P1-A3 `ManualEntryOverrideServiceUnitTest`**. Stubs use full varargs; the gate result is stubbed, because A11 pins the SQL; each case writes or updates exactly one row.

| Case | Expected | IdP called? |
|---|---|---|
| body self | `DENIED_SELF` | no |
| invalid name | `DENIED_CREDENTIALS` | no |
| `"Panderson"`, with `panderson` exempt | `APPROVED`; stored `approver_entered='panderson'` | yes |
| entered name not exempt | `DENIED_NOT_EXEMPT` | **no** |
| null config / blank secret | `ERROR_IDP` | no |
| gate says limited | `DENIED_THROTTLED` | **no** |
| **Tx1 throws** (`55P03` / `CannotAcquireLockException`, or a `DataAccessException`) (aL-a) | controller 503; best-effort `ERROR_IDP` row | **no** |
| 401 | `DENIED_CREDENTIALS` | yes |
| timeout / `RuntimeException` | `ERROR_IDP` | yes |
| no `preferred_username` | `ERROR_IDP` | yes |
| alias: entered `robert`, token `bob`, `bob` not exempt | `DENIED_NOT_EXEMPT` | yes |
| happy path | `APPROVED`, `approver` = the token name | yes |
| Tx2 throws on `APPROVED` | controller 503 | yes |
| password-shaped / unknown name | `approver_entered='<unrecognised>'` | — |

**P1-A4 controller contract** (aN3, cN5)
- Every `DENIED_*` → 403 with a body byte-equal to the constant and **no `reason` key**.
- `X-Authz-Denied` is `MANUAL_ENTRY_OVERRIDE`, byte-equal across all outcomes.
- `wms2.authz.denied` is unchanged (`SimpleMeterRegistry`).
- `ERROR_IDP` and a Tx1 failure → 503; `APPROVED` → 200.
- No body anywhere has a key containing `token`.
- After `approve`, reflection finds no field on the service or verifier that holds the token literal.
- A form-urlencoded request → 415.
  > ⚠ **Amended 2026-10-28:** → 400 + `DENIED_INVALID` (see §3.3 amendment).

**P1-A5 `KeycloakPasswordVerifierUnitTest`** (a local HTTPS mock serving token, discovery, certs and logout)
- Self-signed certificate → `ERROR_IDP`. **Positive control (aN10):** the same certificate in a test truststore → `APPROVED`.
- The body sends `grant_type=password` with the backend credentials and no `scope`.
- With a real `NimbusJwtDecoder` over a test JWK set: a bad signature → `ERROR_IDP`; a wrong `iss` → `ERROR_IDP`.
- A discovery `issuer` that differs from `serverUrl` is honoured (aN6).
- **JWKS bounded (aC3):** a certs endpoint that never responds → `ERROR_IDP` within ≤6 s.
- **Eviction rate limit (aC3):** 10 sequential approvals with a wrong-`iss` token → ≤2 discovery fetches.
- **No eviction on skew (aC3):** an expired-token fixture → `ERROR_IDP` and **0** discovery refetches.
- A second approve on the same tenant does not refetch discovery.
- `logout` is posted, and a logout failure does not change the outcome.
- No dependency on `JwtAccessTokenCustomizer`. The Keycloak body is never propagated.

**P1-A6 `ManualEntryOverrideLoggingUnitTest`** (ListAppender at TRACE on the service, verifier, controller and `MobileEndpointExceptionHandler` loggers, plus root)
- No event contains the password or either token, in approve, deny, throttle, Tx1-failure and IdP-error flows.
- On denials, no event contains the entered name. On `APPROVED`, with the alias fixture, only the token name appears (cN6).
- Exactly one INFO line per attempt.
- Malformed `{"password": hunter2}` through MockMvc with the advice → `hunter2` never appears.
- `toString()` omits the password.

**P1-A7 `ManualEntryOverrideMigrationIT`** (the `CancellationRtsDestinationMigrationIT` template)
- At V2.2.41, all new objects are absent.
- At V2.2.42: the table, its columns (incl. `idp_attempted`) and both indexes; exactly one function row; grant role names exactly the R8 set; 3 sysprops at their defaults; a pre-existing `true` flag row untouched.
- After `dropUniquenessOnGrantTable`, a re-apply adds no duplicates.

**P1-A8 rails**
- Seed parity; `ALLOW_LIST` V2.2.42 → 1.
- `EXPECTED_GUARDED` and `GOLDEN_MAP` (→ `MOBILE_UI_LOG_IN`).
- Not assignable to `AdminController`; the repository has no `@RepositoryRestResource`.
- `SurfaceInventoryContextTest` and `FunctionGateBeanWiringContextLoadTest` stay green.
- **`ForceScanSeedConsistencyTest`** (aC4) pins the migration literals `'false'`, `'25'` and `'15'` against the three `WmsConstants` defaults.
- **Clamp test** (aC4): cap values `"0"`, `"-5"`, `"abc"` and `"101"`, and window values `"5"` and `"1441"`, each resolve to the default. `"1"` and `"100"` are kept.

**P1-A9 collision `--self-test`**
- Cases (a)–(f) on a bare origin.
- Green on the current script under bash 5 first; then the rewrite is green under `/bin/bash` 3.2 **and** bash 5.

**P1-A10 `ManualEntryOverrideTxBoundaryTest`**
- No `@Transactional` on `ManualEntryOverrideService` or `KeycloakPasswordVerifier` (reflection).
- In a context slice, the stub verifier asserts `!TransactionSynchronizationManager.isActualTransactionActive()`.

**P1-A11 `ManualEntryOverrideThrottleIT`** (Testcontainers `db/migration`; cN4, aN2, aC1, cC2, cC3)
- **Fixtures:** seed through a tenant-datasource `TransactionTemplate`, never the landlord-pool context `JdbcTemplate` (memory); unique picker and approver names per case; assert by seeded id; `:now` from a fixed `Clock`, with rows at **now − 9 min 30 s** (inside) and **now − 10 min 30 s** (outside) (cC2).
- **Picker bucket (limit 5):**
  - 5 `DENIED_CREDENTIALS` inside → throttled; 4 → not.
  - 5 outside → not.
  - 5 `APPROVED` → not.
  - **5 `ERROR_IDP` → not**, and **5 post-token `DENIED_NOT_EXEMPT` → not** (aC1, cC3).
  - 5 `DENIED_THROTTLED` / pre-check rows → not.
  - 5 rows for picker Q → P not throttled.
  - 1 `PENDING` + 4 `DENIED_CREDENTIALS` → throttled.
- **Pair bucket (limit 3):** 3 rows for (X, A) → A throttled for X; B not throttled for X; A not throttled for Y.
- **Global bucket, cap set to 4:**
  - 4 failures for X across pickers A–D → E throttled.
  - 3 → not.
  - **4 failures, then an `APPROVED` for X, then 1 failure → not** (the reset).

**P1-A12 concurrency** (in A11; aN1, aC2, cC1)
- Both workers set `TenantContext` and clear it in `finally`.
- Seed 4 prior failures for P.
- Thread A runs the gate and blocks in `afterCountHook` while holding Tx1. Inside the hook, on the **same tenant EntityManager**, `SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND pid = pg_backend_pid()` = **2** (aC2).
- Start thread B. Poll `pg_stat_activity` until B shows `wait_event_type='Lock' AND wait_event='advisory'` (fail after 5 s), then release A.
- Expect **exactly one** verifier call; B → `DENIED_THROTTLED`.
- After A's commit, the same `pg_locks` query on a fresh Tx1 connection, before it locks, = **0**.
- Both threads finish within 2 × `lock_timeout`. Under mutant r3-f, B never waits on the lock and both reach the verifier: a deterministic red.

#### P2 acceptance criteria
**Rules for every P2 test:**
- Every P2 test **except the P2-R9 regression guard** must fail on `1497c3b` for the stated reason (cL2).
- jsdom performs no default actions, so assert `defaultPrevented` and the parent model.

**Real-plugin harness (cC5), used by P2-O5′ and P2-O7:**
1. Do **not** `jest.mock('axios-retry')`. The 4 existing plugin specs do, so do not copy them.
2. `inst = axios.create({ adapter: mockAdapter })`.
3. Add `inst.onRequest = fn => inst.interceptors.request.use(fn)` and `inst.onError = fn => inst.interceptors.response.use(undefined, fn)`.
4. Call the real `plugins/axios.js` default export with `{ $axios: inst, app: { $kc, $toast } }`. The plugin calls `axiosRetry` itself before `onError`, so the order is the plugin's own.
5. Stub `$kc = { ready: Promise.resolve(), authenticated: true, token: 'tok', updateToken: jest.fn().mockResolvedValue(false), logout: jest.fn() }` and spy on `$toast`.
6. **Positive control first:** apply mutant r2-c (`retries: 0` on the POST); (b) and (c) must go red. Then revert.

**ScanInput**

| AC | Assertion | Fails on `1497c3b` because |
|---|---|---|
| P2-R1–R4 | `restricted`: cancelable `paste`, `drop`, `contextmenu` and `beforeinput`(insertFromPaste) on the inner input → `defaultPrevented === true`. `compositionend`+`input` and a bare `input` leave the parent `v-model` `''`. `off`: the opposite | no handler; `$listeners` forwards `input` |
| P2-R5–R6 | No toggle; `softKeyboardToggled`, the cookie and `forceKeyboardMode` do not enable typing; `inputmode === 'none'` | the `mdi-keyboard` toggle renders, and the event, cookie and prop all enable typing |
| P2-R7–R8 | fake `typed` → rejected + override button; `scan` → one `scan-submit` | no detector; no `scan-submit` event |
| P2-R9 | `move-stock-location-case.spec.js` and `cancellation-rts-destination.spec.js` unmodified | **regression guard: stays green** |
| P2-R11 | two identity instances + one Enter → exactly one `scan-submit`; unfocused Enter → one | two window listeners fire |
| P2-R12 | same-screen quantity `keydown` → `defaultPrevented === false`; no ScanInput emit | prevented and buffered |
| P2-R13 | a second scan does not append | `inputBuffer = localValue` appends |
| P2-R14 (aN7) | `off` and `guarded`, keyboard on: `setValue('LOC-1')` + Enter → exactly one `scan-submit('LOC-1')` | the `'keyup.enter'` literal is emitted instead |
| P2-D1 | `createDetector` returns the named strategy; unknown → all `typed` | the module does not exist |

**Dialog and transport**
- **P2-O1** The adapter sees `POST mobile/manualEntryOverride` with a JSON body and **no** `axios-retry` config.
- **P2-O2** After the flow, the password is in neither the store nor `localStorage['vuex-mobile']`.
- **P2-O3** The password field is empty after close and after unmount.
- **P2-O4** 200 → value set, one `scan-submit`, re-locked.
- **P2-O5** Override 403 → generic message, still locked.
  - Three in a row → the cL7 hint.
  - A gate 403 (with `reason`) does not advance the counter.
- **P2-O5′** (cN1, aN3, cN5) Through the real-plugin harness, for an override 403, a 503 and a network error:
  - (a) the POST is sent exactly once;
  - (b) `onMaxRetryTimesExceeded` does not run, and `$kc.logout` is never called, with fake timers advanced 5 s;
  - (c) no `console.error`/`warn` argument, serialised with `util.inspect` at depth 5, contains the password;
  - (d) `$toast.error` is not called for the override 403, and **is** called for a gate 403 carrying `reason`.
- **P2-O6** (cH1) Dialog open: `keydown` for each password character on its input → `defaultPrevented === false`. No ScanInput emit contains those characters, and the password is in neither the store nor `vuex-mobile`.
- **P2-O7** (aH5) The telemetry logger, spied through the P2-O5′ flows, never sees the password.

**Policy store and reducer**
- **P2-S1** With `jest.mock('vuex-persistedstate')` capturing the options:
  - `options.reducer({...fullState, scanPolicy:{mode:'off'}})` has no `scanPolicy` key;
  - boot commits `scanPolicy/reset`.
- **P2-S2** Before load → `guarded`. A 404 with no prior success → `off` + RUM.
- **P2-S3** After a success:
  - 404s from route entry or `visibilitychange` never flip the mode (cL3);
  - 3 interval-tick 404s spanning ≥2 min → `off`.
- **P2-S4**
  - An error before any success → `guarded`.
  - An error after `restricted` → stays `restricted`.
  - A username change → `guarded` + refetch.
  - The getter `restricted` = `mode === 'restricted'`.
- **P2-S5** (cH2) `guarded` + a fake wedge burst → one `scan-submit`, no rejection.
- **P2-S6** (cH3, aN9) Fake timers, **mounted** ScanInput:
  - `restricted`: the parent model stays `''` on `input`;
  - the server answers `false`, then 60 s pass → `off` with no remount, and `input` reaches the parent;
  - the reverse transition;
  - route-entry and `visibilitychange` refetches.

**P2-RAIL `test/rails/identity-fields-are-scan-input.spec.js`**
- **Scope:** tags `v-text-field|v-autocomplete|v-textarea|v-combobox|v-select|scan-input|ScanInput|<input[\s>/]`, comments stripped, excluding ScanInput's own inner field.
- **Each tag must be one of:**
  - a `scan-input` with `identity` and non-empty `workflow` and `field`;
  - a `v-select` whose `v-if` references `scanPolicy/restricted` (P8 behaviour catches an inverted condition);
  - in `PERMANENT_NON_IDENTITY`, exactly **27**, each with a reason;
  - in `PENDING_MIGRATION`, pinned at **33**, which may only decrease.
- Every list entry must match a live tag.
- **Positive-control fixtures:** a plain `v-text-field`; an `identity`-less `<scan-input>`; an `identity` scan-input without `field`; an unlisted `v-select`.
- **Non-vacuity:** ≥60 tags and >50 files.

**HB-1, browser-only checks: option (b)** (cN2, cC4). A local manual floor step, **not CI**.
- **Why not (a):** the Playwright lane has 0 passes in 31 runs and logs into a live realm. Making it pass is a separate project. Each HB-1 check also has a device scenario (M2, M12, M13, M14), and the device is the ground truth.
- **Tooling:** the memory recipe "Headless-browser recipe for wms2-web-ui dev": puppeteer-core in a scratch directory **outside the repo**, against the mobile dev server (`npm run dev`, dev API and Keycloak), as the §7.3 seeded restricted user.
- **Written in P2. Run:**
  - (a)–(c) in **P3**;
  - (d) in **P5** (`moveStock/scanDestination` comment) and **P7** (`replenish/process/selectUnitLoad` Quantity);
  - each run's output attached to that PR.
- **Each run:**
  1. Flip `MOBILE_FORCE_SCAN_ENABLED=true` on wineco dev.
  2. Run the checks.
  3. **Restore it to `false`** and confirm, as in M9. Snapshot first, using `wms-dev-probe`.
- **Checks:**
  - (a) a real clipboard paste and a drag-drop into a restricted field leave the value empty;
  - (b) with the dialog open, typed keys land only in the password input;
  - (c) an exempt logout followed by a restricted login, with `scanPolicy` held unresolved → `guarded`, never `off`;
  - (d) a same-screen quantity or comment field accepts typing.
- **Positive controls:**
  - (a): an unmigrated screen on the same build accepts the paste.
  - (b): the **P3 build with mutant 11b applied**, i.e. the `overrideDialogOpen` check removed, must fail (b).
- **CI finding:** "the Playwright lane has never passed" is a sub-T3 CI finding. It goes on SBDEV-3132 as a comment for Nam to scope.

#### P3–P9 acceptance criteria (per workflow)
`test/components/<workflow>-force-scan.spec.js`:
- Characterize the **unmigrated** component first, green, covering a scanned **and** a typed entry.
- Every migrated field is an `identity` scan-input.
- `restricted` + `paste` → `defaultPrevented`.
- A fake scan → the existing store action, once, with the characterized payload.
- `off` + typed entry → the characterized payload (aN7).
- Same-screen quantity and comment fields: `keydown` → `defaultPrevented === false`.
- The rail literal drops by the number of migrated fields.
- **P7:** `onLocationChange` fires once per scan. **P8:** #3b is absent when restricted.

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| Flag off (default) | free typing | identical once the policy loads; in the pre-load `guarded` window, paste and drop are blocked on identity fields | Negligible. No scan is ever rejected, and typed + Enter still submits (P2-R14) |
| Flag on, pre-load `guarded` (cN11) | — | a restricted picker can type until the first response arrives (normally one request) | An accepted fail-open; listed in the §1 residual risk |
| Exempt users | free typing | identical | none |
| Restricted users, flag on | type, paste, toggle | scan only; override per value | intended |
| `ScanInput` without `identity` | legacy | unchanged, except it pauses capture while the dialog is open | none in practice; no dialog on non-migrated screens |
| Migrated sites | `@keyup.enter` / `@keydown.enter` / form submit | `@scan-submit` | payload characterized for scanned and typed entries |
| API | — | 2 endpoints, 1 table, 3 seeded sysprops (the flag + 2 cap; detection params only if P0 needs them), 1 function | additive; the `{errors:[…]}` error shape is unchanged |
| Desktop web-ui | — | sysprop rows on the Parameters screen | configuration only |

- **Unchanged:** quantity, count and comment fields; Lookup; the task `v-select`s; Pass/Return; `/v3/token` (P26); `restClient` (P27); `AuthzDenialWriter`; web-ui code.
- **Residual:** exempt accounts keep a throttled, audited latency signal (aN5).

---

## 7. Testing Strategy

### 7.1 Commands
- **api** (JDK 21; baseline taken the same day in the same worktree): `mvn test -Dtest='MobileForceScanControllerUnitTest,ManualEntryOverride*Test,KeycloakPasswordVerifierUnitTest,ForceScanSeedConsistencyTest,UtilRestControllerSeedUnitTest,NameKeyedGrantSeedRailTest,FunctionGuard*Test'`; `mvn verify` (both ITs); `bash src/main/resources/db/check-migration-version-collision.sh --self-test`
- **mobile:** `nvm use 22.16.0 && node_modules/.bin/jest` after a fresh `yarn install`; HB-1 run locally (§5.2)

### 7.2 Floor and mutation table
**The floor:** a DB query (§2.4); the failing test first, failing for the stated reason; every new assertion mutation-checked with an **attributable** kill (PIT for the API; hand-breaks for Jest and HB-1); an independent review lane; the full suite compared against the baseline.

Rows 9, 13 and r2-c need the real plugin or reducer installed, not a mocked `$axios`.

| # | Mutant | Killed by | Fixture that makes it non-vacuous |
|---|---|---|---|
| 1 | Delete the body self-check | P1-A3 `DENIED_SELF`, `verify(verifier, never())` | caller == body approver |
| 2 | Step 7 `equalsIgnoreCase` → `equals` | P1-A3 | an alias: entered `robert`, token `"Bob"`, caller `"bob"` (cL5) |
| 3 | Step 8 checks the caller or body name instead of the token name | P1-A3 alias case | body exempt / token not, and the reverse |
| 4 | Step 2 or 8 checks `MOBILE_UI_LOG_IN` | P1-A3 `DENIED_NOT_EXEMPT` | `eq("mgr"), eq(MOBILE_UI_ACTION_MANUAL_ENTRY)` full varargs; an `any()` stub lets it survive |
| 5 | DTO carries `access_token`, or the verifier keeps it | P1-A4 | a distinct token literal `"tok-7f3a"` |
| 6 | `LOG.debug("req {}", req)`, or `toString()` with the password | P1-A6 | ListAppender on the **service and verifier** loggers at TRACE |
| 7 | Null `authConfig` proceeds | P1-A3 | null config, **and** a blank secret |
| 8 | `&&` → `\|\|`; `equalsIgnoreCase` → `equals` (flag) | P1-A1 | `"TRUE"`; exempt + flag off |
| 9 | Pre-load `guarded` → `off`; 404 → `restricted` | P2-S2/S3 | a store with no response; a 404 mock |
| 10 | Drop `preventDefault` in paste | P2-R1 | cancelable `paste` |
| 11a | Remove the foreign-editable early return | P2-R12 | a same-screen quantity input |
| 11b | Remove the `overrideDialogOpen` check | P2-O6 | dialog open over a **legacy** (non-identity) ScanInput, which has no foreign-target rule; keydown on the password input |
| 12 | Remove the `scan-input` enumeration | P2-RAIL | the `identity`-less `<scan-input>` fixture |
| 13 | Remove `scanPolicy` from the blacklist | P2-S1 | the real reducer on a full state |
| r2-a | Remove the throttle gate | P1-A11 / P1-A12 | 5 seeded rows; two threads |
| r2-b | Swap in the trust-all client | P1-A5 | self-signed HTTPS mock (plus the positive control) |
| r2-c | **Add** `'axios-retry': {retries: 0}` to the POST (corrected, cN1) | P2-O5′ (b) and (c) | real `plugins/axios.js`, mock adapter returns an override 403 |
| r3-a | Remove the step-2 exempt pre-check | P1-A3 "IdP never called" | entered name not exempt |
| r3-b | Remove the issuer validator | P1-A5 wrong `iss` | mock token with `iss` ≠ discovery |
| r3-c | Throttle `>=` → `>`, or the window 10 → 11 min | P1-A11 | exactly 5 rows; rows at 10 min 30 s with a fixed `Clock` (cC2) |
| r3-d | Store `approver_entered` raw | P1-A3 `'<unrecognised>'` case | a password-shaped entered name |
| r3-e | Remove the lowercasing | P1-A3 `"Panderson"` case | exempt stub only for `panderson` |
| r3-f | Remove the advisory lock | P1-A12 | A held in `afterCountHook`; B must show `wait_event='advisory'` (cC1) |
| r3-g | Count `DENIED_THROTTLED` (drop `idp_attempted`) | P1-A11 | 5 `idp_attempted=false` rows |
| r3-h | Pair bucket keyed on approver only | P1-A11 pair case | B not throttled for X |
| r3-i | Bespoke 403 replaced by `AuthzDenialWriter` | P1-A4 (`reason` absent, constant header) + P2-O5′(d) | an override 403 |
| r3-j | Bucket predicate back to `idp_attempted AND outcome <> 'APPROVED'` | P1-A11 | 5 `ERROR_IDP` rows (aC1, cC3) |
| r3-k | Drop the reset-after-`APPROVED` clause | P1-A11 global | 4 fails → `APPROVED` → 1 fail, at cap 4 |
| r3-l | Locks issued through a context `JdbcTemplate` / landlord EM | P1-A12 `pg_locks` = 2 | the same-EM probe inside the hook (aC2) |
| r3-m | Evict the decoder on a timestamp failure, or without the 5-min limit | P1-A5 | an expired token → 0 refetches; 10 wrong-`iss` → ≤2 |
| r3-n | Remove the cap clamp | P1-A8 clamp test | cap `"0"` resolves to 25 (aC4) |
| r3-o | Tx1 exception propagates (no 503 mapping) | P1-A3/A4 | stubbed `CannotAcquireLockException` (aL-a) |

### 7.3 Manual Test Plan (wineco dev, `wms-dev-probe`)
**Accounts**: **Approver:** `panderson` (exempt); **Restricted user:** seeded as a throwaway Keycloak user plus a WMS group with `MOBILE_UI_LOG_IN` and the `MOBILE_UI_VIEW_*` function for **every workflow under test** (cN8). Each is the function `GOLDEN_MAP` pins on that workflow's controller, for example `MOBILE_UI_VIEW_STOCK_TRANSFER` for move stock and `MOBILE_UI_VIEW_PICKING` / `…_PUT_AWAY` / `…_REPLENISHMENT` / `…_PALLETIZING` / `…_CYCLE_COUNT` / `…_TRUCK_LOADING` / `…_TRANSFER` / `…_CANCELLATION`. Restore it by snapshot or diff afterwards; **Lockout tests** use a second throwaway exempt user, never a real manager.

| # | Scenario | Env | Precondition → dev count | Steps | Expected | P/F |
|---|---|---|---|---|---|---|
| M1 | Flag off: no change | dev | `SELECT count(*) FROM los_sysprop WHERE syskey='MOBILE_FORCE_SCAN_ENABLED'` → **0** (1 = `false` after P1) | Restricted user pastes and types into picking location; Enter | Accepted and submitted once, as today | |
| M2 | Restricted is blocked | dev + device | restricted users → **5** (+ seeded); open, unassigned `pickingorder` → **11** | Flip on; within ≤3 min, **no reload**: paste, type, long-press paste, toggle | All rejected; a real scan proceeds | |
| M3 | Exempt is unaffected | dev | R8 users → **46** | M2 as `panderson` | Typing works | |
| M4 | Override approved | dev | audit table → **absent** today / 0 after P1 | Override → value → `Panderson` (capitalised) + password | 200; one submit; one `APPROVED` row, `approver_entered='panderson'`, `idp_attempted=true` | |
| M5 | Denials (from M4 state) | dev | as M4 | Wrong password; non-exempt name; self | One message each; correct outcomes; no Keycloak LOGIN_ERROR for the non-exempt name; **no logout toast and no session loss** | |
| M6 | Throttle + lockout | dev | Keycloak admin `GET /admin/realms/<realm>` → `bruteForceProtected`, `permanentLockout`, `failureFactor`, `maxDeltaTimeSeconds`, read **first**; second throwaway user seeded | 4 wrong attempts from one picker against one approver | 4th = `DENIED_THROTTLED` (pair limit 3), no IdP call; another picker can still attempt that approver | |
| M7 | No leaks (M4/M5) | dev | — | Inspect responses; grep API logs and OpenObserve for the password and the entered name | None | |
| M8 | Desktop unaffected | dev web-ui | `Operation Options` → **43** (46 after P1) | Parameters screen; one desktop flow | Listed; unchanged | |
| M9 | Rollback, no reload (from M2) | dev + device | — | Flip off; wait ≤3 min | Typing restored | |
| M10 | Move stock (P5) | dev | located, labelled `unitload` → **759,943** | Scan UL → destination | As before | |
| M11 | Device pass before the flip | UAT + Honeywell | **unmeasured** (O2) | Every migrated workflow, ≥30 scans | No false rejections | |
| M12 | Same-screen qty/comment | dev + device | as M2 | Qty on `replenish/process/selectUnitLoad`; comment on `moveStock/scanDestination` | Typeable | |
| M13 | Dialog on the keypad | device | as M4 | Type value, username and password on the hardware keypad | SIP shown; text only in the dialog; the username is not auto-capitalised | |
| M14 | Shared handheld | device | M2/M3 | `panderson` out → restricted user in, no reload | `guarded` then `restricted`; never `off` | |
| M15 | Policy unreachable, flag off | dev + device | M1 state | Block `scanPolicy` (proxy); scan and type + Enter in picking | Every scan and typed entry accepted | |

### 7.4 Observability (saved queries)
```sql
-- denials per approver, last hour (lockout signal)
SELECT approver_entered, outcome, count(*) FROM mobile_manual_entry_override
 WHERE created_at > now() - interval '1 hour' AND outcome <> 'APPROVED' GROUP BY 1,2 ORDER BY 3 DESC;
-- per picker: spraying = many distinct approvers
SELECT picker, count(DISTINCT approver_entered) AS approvers, count(*) AS attempts FROM mobile_manual_entry_override
 WHERE created_at > now() - interval '1 hour' AND outcome <> 'APPROVED' GROUP BY 1 ORDER BY 2 DESC, 3 DESC;
-- approvals per workflow/field per day
SELECT date_trunc('day', created_at), workflow, field, count(*) FROM mobile_manual_entry_override
 WHERE outcome='APPROVED' GROUP BY 1,2,3 ORDER BY 1 DESC, 4 DESC;
-- stranded PENDING older than 1 min: unknown outcome, possible orphaned Keycloak session (aL-b)
SELECT id, picker, approver_entered, created_at FROM mobile_manual_entry_override
 WHERE outcome='PENDING' AND created_at < now() - interval '1 minute' ORDER BY created_at DESC;
```

### 7.5 Deliberately skipped
- **No verify script.** Each invariant has a JUnit or Jest home; the cross-file invariant is P2-RAIL.
- **No CI e2e.** Browser-only checks are HB-1 (local) plus device scenarios; see cN2 for why.
- **Not covered by any automated test:** wedge behaviour on the real device (P0, M11); realm settings and issuer per environment (§5.1 row 6, a manual read); cross-replica cache lag (accepted, §7A row 9); OpenObserve sink serialisation (M7).

---

## 7A. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **Yes** (read-only) | Per-tenant decoder, discovery and eviction-stamp cache (24 h Caffeine), as in `MultiTenantJwtDecoder`. Public, derived data. A replica miss costs 2 extra Keycloak GETs (discovery + JWKS); evictions are rate-limited to one per tenant per 5 min (aL-c, aC3). Throttle and audit state live in the DB |
| 2 | Connection pool | No | Tx1: 2 advisory locks + 3 indexed counts + 1 insert, milliseconds. Tx2: 1 update. **No connection is held during the IdP call** |
| 3 | Scheduled jobs | N/A | — |
| 4 | Long transactions | No | Tx1 and Tx2 are short and sequential; verify, decode and logout run outside any transaction (P1-A10) |
| 5 | Request affinity | No | — |
| 6 | Retry / idempotency | No | No client retry (constant header). A manual retry is a new, audited, throttled attempt |
| 7 | Tenant context | No | Same thread |
| 8 | Distributed lock | **Yes** | `pg_advisory_xact_lock` on (approver), then (picker), in a fixed order, through native queries on the **tenant** EM inside Tx1 (aC2). Bounded by the tenant dialect's `SET LOCAL lock_timeout`; a timeout → 503 with no IdP call. No `REQUIRES_NEW` nesting. Pinned by P1-A12 (`pg_locks`, `pg_stat_activity`) |
| 9 | Cache invalidation | **Yes** | 2 min per-replica `sysprops` cache. Rollback within 2 min + 60 s for devices that reach the API. Accepted |
| 10 | External calls | **Yes** (Keycloak) | Between Tx1 and Tx2, no connection held. Every fetch (ROPC, discovery, JWKS, logout) goes over the dedicated client: ≤7 s each. Worst case on a cache miss ≈ **21 s** per thread (ROPC + discovery + JWKS); warm ≈ 7 s (aC3) |

## 7B. v2 constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV | flat entity |
| 2 | Tx manager | Tx1 and Tx2 on `tenantTransactionManager` + rollbackFor, called via the proxy |
| 3 | readOnly | the `scanPolicy` path |
| 4 | Caffeine | 1 new read-only cache (decoder/issuer, 24 h, tenant-keyed), mirroring `MultiTenantJwtDecoder` |
| 5 | Micrometer | none: not a hot path, and metrics are unscraped. The audit table is the record |
| 6 | Jakarta | new code only |
| 7 | H2 SQL | advisory locks and native counts are Postgres-only, tested only through Testcontainers (A11/A12); unit tests stub the gate |
| 8 | Controller tests | `setupMockMvcWithGuard` |

---

## 8. Rollout Plan
- **Merges:** one PR per phase into each repo's `develop` (release and `main` are devops), in the order P0 → P1 → P2 → P3…P9.
- **Gating and parallelism:** the P1 PRD release waits on §5.1 row 6; P2–P9 do not. P3–P9 may run in parallel; the later-merging PR rebases the literal.
- **Before P1 merges:** run the collision script at PR open and again before merge. Record the issuer probe for dev, UAT and PRD in the PR.
- **Enablement:** UAT flip + M11, then WineCo PRD once §5.1 rows 2, 6 and 6b hold. Other tenants stay off.
- **Rollback:** set the sysprop to `false`; takes ≤3 min with no reload.
- **Proposals:** P26 and P27 are out of scope and already in the register. The Playwright lane finding goes as a comment on SBDEV-3132 (sub-T3).

---

## 9. Alternatives Considered
B–E are in the RALPLAN-DR table. Also rejected:
- `/v3/token` reuse (P26) and the shared `restClient` (P27).
- `AuthzDenialWriter` for override denials: its root `reason` triggers the toast and the metric, and is an oracle risk (aN3).
- An axios-retry `retries: 0` opt-out: it fires the logout hook (cN1).
- Single-bucket throttles: DoS or race (aN1, aN2).
- A second keycloak-js session (clobbers `kcToken`); an SDR sysprop read (gated); `mywms_user.password` (dead MD5).
- Own-session supervisor approval (the SBDEV-3548 precedent): superseded by decision 3, since it means a hot-path re-login.
- A badge scan: no badge identity exists.
- Making the Playwright lane pass in P2: option (a); see HB-1.

---

## 10. Open Questions / Resolved Decisions

### Resolved (Nam, fixed; not re-opened)
1. A tenant sysprop turns it on; holders of a new exempt function are exempt and are the only approvers.
2. Only identity fields are restricted; quantity and count fields stay typeable.
3. Override: manager credentials on the picker's device → server-side ROPC with the tenant backend client; the token is discarded; identity comes from the token; the approver must be exempt; no self-approval; no body logging; lockout is Keycloak's job; the PRD realm checks are a §5.1 gate; the endpoint is gated on a function pickers hold.
4. One audit row per attempt (DENIED included) in a new tenant table, V2.2.42, re-swept before merge; no GRANT (V2.2.13 precedent).
5. P0 device spike; priority native > per-app prefix > timing; detection pluggable inside ScanInput.
6. One extended ScanInput; one workflow per PR; a Jest rail with a positive control; restricted mode blocks paste, drop, beforeinput paste/drop and IME, hides the toggle and ignores the cookie and event; the double `keyup.enter` is mitigated.
7. A server-side `GET /v3/mobile/scanPolicy`; pickers never read the sysprop.
8. Deterrent + audit framing; no per-handler server token.
9. Desktop unaffected except the Parameters screen row.
10. The collision script is made bash-3.2 safe in P1, with a self-test.
11. P26 is out of scope; the new endpoint avoids every one of its flaws (§3.3 table).

### Resolved by this plan (recommendations; Nam may override at approval)
- **R1 Lookup (#6): exclude.** Read-only; on the permanent list.
- **R2 Picking section (#16): exclude.** A work queue, not a physical identity.
- **R3 Package type (#20): exclude.** A catalog type, not an instance.
- **R4 Tap-to-pick:** the v-autocompletes (#4, #9, #30, #32) become ScanInputs with the dropdown hidden when restricted; #3b is hidden when restricted; the task `v-select`s and Pass/Return stay, because they choose or skip work.
- **R5 Policy load:** unknown → `guarded` (never rejects); once `restricted` is learned for the user, errors keep it; a 404 → `off` (after a success, only on the 3rd consecutive 404), with a RUM event; time-boxed.
- **R6 Function name:** `MOBILE_UI_ACTION_MANUAL_ENTRY`.
- **R10′ Global-cap window (Nam, 2026-10-27; was O5):** 15 min, matched to Keycloak's `maxFailureWait` scale rather than `maxDeltaTime`. A picker can block a manager's overrides for about 15 min at most. Nam accepted that a slow spray can still reach Keycloak's own temporary lockout (§3.3 honest bound).
- **R11 Malformed override request (Nam, 2026-10-27; gate review M6):** a `workflow`/`field`/`value` outside its column shape returns 400 with a constant body, checked before the throttle and before Keycloak. It is audited as `DENIED_INVALID` (`idp_attempted=false`, so it never counts toward a bucket), with the value stored as `'<invalid>'` and never logged.
- **R7 Value binding:** the picker types the value in the dialog before the manager authenticates, so the audit row holds exactly the approved value.
- **R8 Grant set (Nam, 2026-10-26; was O1):** `MOBILE_UI_ACTION_MANUAL_ENTRY` is granted to `super-admin`, `outbound-manager` and `inventory-manager` in V2.2.42 and `initDB`.
- **R9 Throttle (final):** serialised with tenant-EM advisory locks; a `PENDING` row is written before the IdP call; it counts only `DENIED_CREDENTIALS` + `PENDING` and resets on `APPROVED`; buckets are pair 3 / 10 min, picker 5 / 10 min, and the global cap (clamped sysprops); any Tx1 failure → 503 with no IdP call. A rate limit beside Keycloak's lockout, not a replacement (aC1, aC2, aC4, cC3).
  > ⚠ **Amended 2026-10-28:** superseded by the §3.3 "Reset on success" amendment (predicate, per-bucket reset, pre-check cap).
- **R10 Denial contract (revised r3):** a bespoke 403 with a constant body (no `reason`) and the constant `X-Authz-Denied: MANUAL_ENTRY_OVERRIDE`; no metric; **no** axios-retry override. `AuthzDenialWriter` is not used (aN3, cN5, cN1).
- **R11 Usernames:** lowercased on the server; the field is labelled "WMS username", with autocapitalize off; email logins are unsupported.
- **R12 Browser-only checks:** option (b), HB-1 local plus device scenarios; no CI claim.

### Open (block the noted step only)
- **O2 WineCo PRD population** under R8 (`wsl-wineco-prd` got CONNECT_TIMEOUT). Blocks the PRD flip.
- **O3 P0's outcome** (detection contract, `readonly`). Blocks P2. If no separating signal exists, the work returns to Nam.
- **O4 Keycloak realm settings and issuer on UAT/PRD** (§5.1 row 6, i–v; dev issuer measured). Blocks the P1 PRD release.

---

## ADR
- **Decision:** Option A: Client side: one extended `ScanInput` with `off` / `guarded` / `restricted` modes, driven by a non-persisted, refreshed `scanPolicy`; Server side: one override endpoint. Before ROPC it normalises the name and runs the self check, the exempt pre-check and the advisory-locked, IdP-attempt-only throttle, writing a `PENDING` row. ROPC uses a dedicated verifying client and a decode with signature, timestamp and issuer checks, the issuer taken from discovery. The token is then discarded and the session logged out; Every attempt is audited. 200 is returned only after the `APPROVED` update commits. Denials use a bespoke constant 403. Default off, per tenant.
- **Drivers:** stop casual typing and pasting without slowing scans; no new oracle, no token/log/RUM leak, and no lockout amplifier beyond Keycloak's; a reversible rollout that never rejects a real scan.
- **Alternatives considered:** B, a per-handler token: proves nothing, at ~40–60 signatures (an estimate, not enumerated); C, a PIN: a new secret store and lockout; D, a directive: no home for state; E, device-only: no per-user exemption or audit; plus the §9 list.
- **Why chosen:** it reuses existing seams and adds no mutable JVM state. The only server enforcement sits on the approver's credential and function, and it is honest about the client's limits.
- **Consequences:** SSO passwords are typed on shared devices; Lockout depends on realm settings plus a DB throttle whose global cap must be set per tenant; 33 sites migrate across 7 PRs; Only sanctioned overrides are audited; A flip takes ≤3 min for devices that reach the API; Exempt accounts keep a throttled latency signal; Browser-only behaviour is checked locally and on the device, not in CI.
- **Follow-ups (owner → tracker):**
  1. Option C, if SSO passwords on devices are rejected: Nam → P1 review.
  2. An optional `X-Entry-Mode` header: Nam → a new proposal.
  3. P26: Nam → register.
  4. P27: Nam / Joe → register.
  5. Remove the 404 → `off` branch once P1 is on PRD everywhere: P2 author → this ticket.
  6. Role matrix §3.8: P1 author → P1 docs.
  7. EB/MDM supplement: WineCo ops → P0 report.
  8. The Playwright lane: Nam → SBDEV-3132 comment (sub-T3).

---

## Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | Callsites | ✓ §0: 60 = 33 + 27; P2-RAIL |
| 2 | Adjacent shapes | ✓ `v-select`s, autocompletes, Pass, same-screen qty, multi-instance, legacy ScanInputs, typed Enter in `off`/`guarded` |
| 3 | Backward compatibility | ✓ §6, with Impact |
| 4 | Concurrency | ✓ advisory locks + `PENDING` (P1-A12); no double submit; no client retry |
| 5 | Multi-tenant | ✓ tenant-keyed caches; per-tenant realm, issuer and JWKS; per-facility-DB throttle with the cap divided by facilities |
| 6 | Error handling | ✓ §3.3 step table; 503 on a Tx2 failure; catch-all → `ERROR_IDP`; stuck `PENDING` fails closed |
| 7 | DB verified | ✓ §2.4 + the dev issuer probe (§2.2); PRD open (O2, O4) |
| 7b | Observability | ✓ §7.4 (4 queries); INFO line; RUM events |
| 8 | Rollout | ✓ V2.2.42 re-sweep, flag, ≤3 min |
| 9 | Tests | ✓ named JUnit/Jest tests; 2 ITs; HB-1; 32 mutants (§7.2: 26 in r3 + 6 r3-final); 15 manual scenarios with counts |
| 10 | Cross-version | no: v1 is reference-only (memory) |
| 11 | Alternatives | ✓ B–E + §9 table |

## 9.2 Recommended OMC composition
T3. Plan review: critic (ralplan, approved r3 with conditions applied). Implementation: ralph per phase; P3–P9 may run as a team in separate worktrees. Verification: the floor + §7.2 + a `verifier` lane + HB-1; no verify script. Code review: P1 4 lanes (conformance · review · **security** · re-review); P2 2 + security; P3–P9 2 each. Commit: git-master.

---

## Revision log r1 → r2 (condensed)
- **Highs:** aH1–aH5 and cH1–cH5 → §2.1, §3.3, §3.5, §3.6, §0 rail, P2-R/O/S ACs, and the pre-mortem.
- **Mediums:** aM1–aM5 and cM1–cM10 → the throttle and pre-check, refetch, prefix, audit failure, issuer, tx AC, migration IT, self-test, pre-mortem recoveries, manual plan.
- **Lows:** aL1–aL9 and cL1–cL13 → wording, rails, fixtures and the ADR.
- **Tests:** the critic r1 mutant table was added.

## Revision log r2 → r3 (condensed)
- **Throttle (aN1, aN2, cN4, cN12):** advisory locks, a `PENDING` row before the IdP call, pair/picker/global buckets, `ManualEntryOverrideThrottleIT`.
- **No retry override (cN1):** removed, plus real-plugin tests. **Bespoke 403 (aN3, cN5).**
- **Name normalisation (aN4, cN3).** Issuer from discovery (aN6). Typed Enter (aN7). Playwright → HB-1 option (b) (cN2).
- **Lows:** aN5, aN8–aN10, cN6–cN11, cN13. **Mutants:** r3-a…r3-i.

## Revision log r3 → final

| Finding | Section(s) changed |
|---|---|
| aC1 = cC3: count only `DENIED_CREDENTIALS` + `PENDING`; reset on `APPROVED`; 12 h window | §3.3 throttle buckets (predicate, reset, honest bound), R9, P1-A11 (`ERROR_IDP`, post-token, reset cases), mutants r3-j/r3-k, **O5 (Nam)** |
| aC2 lock on the tenant EM inside Tx1 | §3.3 `approve` (lock placement), §7A row 8, P1-A12 `pg_locks` = 2, then 0; mutant r3-l |
| aC3 JWKS over the verifying client; no eviction on skew; eviction rate-limited | §3.3 step 6, §7A rows 1 and 10 (≈21 s cache-miss bound), P1-A5 (JWKS hang, eviction rate, skew cases), mutant r3-m |
| aC4 clamp and default the cap sysprops; seed-pin them | §3.1, P1-A8 (`ForceScanSeedConsistencyTest` with 3 literals, clamp test), mutant r3-n |
| aL-a + cL4 Tx1 failure / `55P03` → 503, no IdP call | §3.3 step 4, P1-A3, P1-A4, P1-A6, mutant r3-o |
| aL-b stranded `PENDING` | §3.4 (hard kill only; graceful shutdown default), §7.4 saved query |
| aL-c replica miss costs 2 GETs | §7A row 1 |
| cC1 deterministic race IT; `TenantContext` | §3.3 step 4 `afterCountHook`, P1-A12 (`pg_stat_activity` poll, `TenantContext` per worker, vacuous deadlock clause replaced), mutant r3-f fixture |
| cC2 boundary flake | §3.3 injected `Clock`; P1-A11 at 9:30 / 10:30; mutant r3-c fixture |
| cC4 HB-1 scheduling | HB-1: written in P2, run at P3/P5/P7; mutant 11b is the control for (b); dev flag flipped and restored |
| cC5 real-plugin harness | P2 "Real-plugin harness" steps 1–6, with mutant r2-c as the positive control |
| cL1 mutant-count claim | completeness checklist: the r3 table had 26 rows; 32 now |
| cL2 "every P2 test fails" | P2 rules (R9 exempt); the "fails because" cells filled in |
| cL3 404 counting | §3.6 results table, P2-S3 |
| cL5 mutant 2 fixture | §7.2 row 2 (an alias) |
| cL6 pre-check spray | §3.3 throttle buckets (accepted, with reasons) |
| cL7 hint wording | §3.6 dialog, P2-O5 |
| cL8 run-on ACs | P1/P2/P3–P9 ACs, §3.3 and §3.6 unfolded to one criterion per line |
| R10′ (Nam, 2026-10-27) | O5 resolved: global-cap window 15 min; default seeded as `15`; honest bound rewritten | §3.1 throttle sysprops, §3.3 honest bound, ForceScanSeedConsistencyTest literals, §10 R10′; status → approved |
| R11 (Nam, 2026-10-27) | Gate review M6: malformed request → 400 + `DENIED_INVALID` audit row | §3.3 step 0, §10 R11; deferred-tests R-M6 |
