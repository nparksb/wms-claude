---
title: "Symptom Index — WMS v2 Debug Jump Table"
type: index
status: active
version: v2
scope: symptom-lookup
updated: 2026-04-19
tags: [index, symptom, debug, wms2]
---

# Symptom Index — WMS v2 Debug Jump Table

**One-stop lookup:** error / anomaly you're seeing → canonical doc + section. Aggregated from every WMS v2 doc's "How to debug" / "How to use" table. Always current; re-verify when you add a new doc with debug entries.

This is the **authoritative** version. The per-doc "How to debug" sections are summaries for local navigation — if they drift from this file, this file is right.

- 📘 Architecture — `3-Resources/architecture/`
- 📕 Workflows — `3-Resources/workflows/`
- 📗 Data dictionary — `3-Resources/data-dictionary/`

---

## 1. Authentication / tenant / routing

| Symptom | Start at |
|---|---|
| Login succeeds but first API call returns 401 | 📘 [end-to-end-request-journey §3.3](3-Resources/architecture/wms2-end-to-end-request-journey.md) (axios header injection) |
| Infinite redirect to Keycloak on page load | 📘 [end-to-end-request-journey §3.2](3-Resources/architecture/wms2-end-to-end-request-journey.md) (`window.__keycloakState`) |
| "Tenant not found" on backend | 📘 [end-to-end-request-journey §3.1 + §4.1](3-Resources/architecture/wms2-end-to-end-request-journey.md) |
| Data from the wrong tenant is showing up | 📘 [tenant-routing §10 item 2](3-Resources/architecture/wms2-tenant-routing-datasource-topology.md) + [transaction §5 Rule 1](3-Resources/architecture/wms2-transaction-osiv-boundary-map.md) — bare `@Transactional` landlord fallback |
| Token refresh stops mid-session | 📘 [end-to-end-request-journey §6](3-Resources/architecture/wms2-end-to-end-request-journey.md) (`onAuthRefreshError`, cleared interval) |
| New tenant added but not routable yet | 📘 [tenant-routing §7](3-Resources/architecture/wms2-tenant-routing-datasource-topology.md) (5-min config refresh) |
| Mobile UI loops re-initialising Keycloak | 📘 [end-to-end-request-journey §3.2](3-Resources/architecture/wms2-end-to-end-request-journey.md) |
| User can't see a web/mobile page | 📘 [keycloak-role-matrix §9](3-Resources/architecture/wms2-keycloak-role-matrix.md) |
| User can hit an API endpoint they shouldn't | 📘 [keycloak-role-matrix §8 item 1](3-Resources/architecture/wms2-keycloak-role-matrix.md) — mobile gating is UI-only |
| "Why did this write go to the wrong DB?" | 📘 [transaction §5 Rule 7](3-Resources/architecture/wms2-transaction-osiv-boundary-map.md) — `@Primary` landmine |
| "Entity not managed for persistence unit X" | 📗 [landlord-vs-tenant-entity-map §3 vs §2](3-Resources/data-dictionary/wms2-landlord-vs-tenant-entity-map.md) |

---

## 2. State machine / stuck state

| Symptom | Start at |
|---|---|
| Order stuck in an intermediate state, not progressing | 📘 [state-machine-catalog §8](3-Resources/architecture/wms2-state-machine-catalog.md) |
| Pickingorder stuck in `PICKED`, never reaches `FINISHED` | 📕 [picking-workflow §10 item 3](3-Resources/workflows/wms2-picking-workflow.md) — only mobile writes terminal state |
| Order cancelled but Pickingorder still live | 📕 [cancel-cascade-workflow §7](3-Resources/workflows/wms2-cancel-cascade-workflow.md) — rapid-pick side-door |
| `.equals("CANCELED")` always false for Advice/BOL/Cyclecount | 📘 [state-machine-catalog §2.2](3-Resources/architecture/wms2-state-machine-catalog.md) + 📗 [domain-glossary §9](3-Resources/data-dictionary/wms2-domain-glossary.md) — `CANCELLED` vs `CANCELED` spelling |
| Advice stuck in `OPEN`, won't close | 📕 [receiving-putaway-workflow §10](3-Resources/workflows/wms2-receiving-putaway-workflow.md) |
| BOL stuck in `TRUCK_LOADING`, close rejects | 📕 [bol-truck-loading-workflow §12](3-Resources/workflows/wms2-bol-truck-loading-workflow.md) — `bolToClose` set poisoned? |
| BOL stuck in `TRANSFER` after intracompany ship | 📕 [bol-truck-loading-workflow §12](3-Resources/workflows/wms2-bol-truck-loading-workflow.md) — `finishTransfer` not invoked |
| Club run stuck in `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` | 📕 [club-run-workflow §10](3-Resources/workflows/wms2-club-run-workflow.md) — Phase 2/3 exception + rollbackClubLineState |
| Cancel hangs on a running batch | 📕 [club-run-workflow §10](3-Resources/workflows/wms2-club-run-workflow.md) — pessimistic lock held by `runClubLine` |
| Batch `FINISHED` but one child order still `LOADED_TO_TRUCK` | 📕 [club-run-workflow §10](3-Resources/workflows/wms2-club-run-workflow.md) — `closeBOL` partial commit |
| Pack refuses — "order in PACKED state" | 📕 [cancel-cascade-workflow §11](3-Resources/workflows/wms2-cancel-cascade-workflow.md) — §4 guard + forceCancelOrder |
| Batch partially cancelled, children inconsistent | 📕 [cancel-cascade-workflow §11](3-Resources/workflows/wms2-cancel-cascade-workflow.md) — check for mid-cascade exception |

---

## 3. Concurrency / optimistic lock / performance

| Symptom | Start at |
|---|---|
| Optimistic-lock storm during replenish / picking burst | 📕 [picking-workflow §11](3-Resources/workflows/wms2-picking-workflow.md) + 📘 [transaction §8](3-Resources/architecture/wms2-transaction-osiv-boundary-map.md) |
| Optimistic lock during cancel | 📕 [cancel-cascade-workflow §11](3-Resources/workflows/wms2-cancel-cascade-workflow.md) — no automatic retry in cancel path |
| Connection-pool exhaustion | 📘 [transaction §7 + §10 items 4–5](3-Resources/architecture/wms2-transaction-osiv-boundary-map.md) + [tenant-routing §4](3-Resources/architecture/wms2-tenant-routing-datasource-topology.md) |
| `closeBOL` performance regression | 📕 [bol-truck-loading-workflow §12](3-Resources/workflows/wms2-bol-truck-loading-workflow.md) — confirm bulk JPQL paths still active |
| Replica A fires cron, replica B fires it too | 📕 [picking-workflow §11](3-Resources/workflows/wms2-picking-workflow.md) + 📘 [scheduled-jobs §2](3-Resources/architecture/wms2-scheduled-jobs-catalog.md) — advisory lock state |
| Concurrent `closeBOL` produced partial state | 📕 [bol-truck-loading-workflow §12](3-Resources/workflows/wms2-bol-truck-loading-workflow.md) — dual-layer guard (in-memory set + DB pessimistic) |
| Request-path TX hung / long optimistic-lock retry | 📘 [transaction §8.3](3-Resources/architecture/wms2-transaction-osiv-boundary-map.md) — `OptimisticLockRetry` utility, not `@Retryable` |

---

## 4. Cron / scheduling / replica coordination

| Symptom | Start at |
|---|---|
| Cron job on replica A works, replica B never fires | 📘 [scheduled-jobs §3.3](3-Resources/architecture/wms2-scheduled-jobs-catalog.md) — 60 s startup gate timeout |
| Cron should fire every minute but fires erratically | 📘 [scheduled-jobs §7 item 2](3-Resources/architecture/wms2-scheduled-jobs-catalog.md) — pool size 10 starvation |
| OMS didn't get stock summary at 3am | 📘 [scheduled-jobs §4.3](3-Resources/architecture/wms2-scheduled-jobs-catalog.md) — `WEBSERVICE_STOCK_COUNT_URL` + activation sysprop |
| Picking orders stay locked after operator crash | 📘 [scheduled-jobs §4.5](3-Resources/architecture/wms2-scheduled-jobs-catalog.md) — `PICK_TIME_OUT_SYSTEM_ACTIVATED=false` by default |
| "Tenant not found" during a cron run | 📘 [scheduled-jobs §4 skeleton + §7 item 5](3-Resources/architecture/wms2-scheduled-jobs-catalog.md) — `TenantContext` not set |
| New scheduled job needs tenant data but gets `BOOTSTRAP` | 📘 [tenant-routing §10 item 2 + §6.1](3-Resources/architecture/wms2-tenant-routing-datasource-topology.md) — iterate tenants manually |

---

## 5. OMS callbacks (notifications to / from OMS)

| Symptom | Start at |
|---|---|
| OMS never received picking notification | 📕 [picking-workflow §11](3-Resources/workflows/wms2-picking-workflow.md) + `message` / `message_archived` tables |
| OMS never received cancel notification | 📕 [cancel-cascade-workflow §6](3-Resources/workflows/wms2-cancel-cascade-workflow.md) — check `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` (default `false`) |
| OMS got "cancel" before it actually persisted | 📕 [cancel-cascade-workflow §11 item 6 / archive](3-Resources/workflows/wms2-cancel-cascade-workflow.md) — use `registerSynchronization`, never sync callback in `@Transactional` |
| OMS never got `SHIPPED` after BOL close | 📕 [bol-truck-loading-workflow §12](3-Resources/workflows/wms2-bol-truck-loading-workflow.md) — check for rollback between write and commit |
| OMS didn't get stock update on regular receive | 📕 [receiving-putaway-workflow §10](3-Resources/workflows/wms2-receiving-putaway-workflow.md) — `INBOUND_UPDATE_STOCK_IMMEDIATELY` gate |
| OMS never received any club-run notifications | 📕 [club-run-workflow §10](3-Resources/workflows/wms2-club-run-workflow.md) + sysprop activation flags |

---

## 6. Receiving / putaway

| Symptom | Start at |
|---|---|
| Advice stuck in `OPEN`, close rejects | 📕 [receiving-putaway-workflow §10](3-Resources/workflows/wms2-receiving-putaway-workflow.md) + `AdviceService.close:290-294` |
| Stock shows up at wrong location after receive | 📕 [receiving-putaway-workflow §4.2](3-Resources/workflows/wms2-receiving-putaway-workflow.md) — one Unitload per case |
| Mobile putaway refuses scanned location | 📕 [receiving-putaway-workflow §5.3](3-Resources/workflows/wms2-receiving-putaway-workflow.md) — `FixLocationAssignment` mismatch |
| Two operators ended up with the same pallet on putaway | 📕 [receiving-putaway-workflow §9 item 2](3-Resources/workflows/wms2-receiving-putaway-workflow.md) — SBDEV-2102 guard |
| Label didn't print after receive | 📕 [receiving-putaway-workflow §9 item 10](3-Resources/workflows/wms2-receiving-putaway-workflow.md) — post-commit, no retry |
| `/rest/advice/reopen` throws `RuntimeException` | 📕 [receiving-putaway-workflow §9 item 3](3-Resources/workflows/wms2-receiving-putaway-workflow.md) — intentional stub |

---

## 7. Picking

| Symptom | Start at |
|---|---|
| Unexpected pick order appeared | 📕 [picking-workflow §7](3-Resources/workflows/wms2-picking-workflow.md) — merge pass (`ReplenishOrderJob.mergePickingOrders`) |
| Operator can't finish pick — validation error | 📕 [picking-workflow §5](3-Resources/workflows/wms2-picking-workflow.md) — guard table at MobilePickingService lines 222–340 |
| `Pickingorder=FINISHED` but `Customerorder=STARTED` | 📕 [picking-workflow §4](3-Resources/workflows/wms2-picking-workflow.md) + 📘 [state-machine §5.5](3-Resources/architecture/wms2-state-machine-catalog.md) — missed branch in `finalizePicking` |
| Rapid-pick cancel left `Pickingorder` in `PROCESSABLE` | 📕 [picking-workflow §6](3-Resources/workflows/wms2-picking-workflow.md) — expected rapid-pick side-door |
| Club-order cancel didn't cascade to Pickingorder | 📕 [club-run-workflow §6.1](3-Resources/workflows/wms2-club-run-workflow.md) + [cancel §7](3-Resources/workflows/wms2-cancel-cascade-workflow.md) — UUID `historytote` semantics |

---

## 8. BOL / truck loading / shipping

| Symptom | Start at |
|---|---|
| Mobile operator scanned wrong gate — no error | 📕 [bol-truck-loading-workflow §5](3-Resources/workflows/wms2-bol-truck-loading-workflow.md) — open TODOs |
| BOL close performance regressed | 📕 [bol-truck-loading-workflow §6.3](3-Resources/workflows/wms2-bol-truck-loading-workflow.md) — verify bulk JPQL paths |
| Transfer lane reassignment changed batch state silently | 📕 [club-run-workflow §5 + §9](3-Resources/workflows/wms2-club-run-workflow.md) — `transferOrder` writes `CLUB_RUN_FINISHED` intentionally |

---

## 9. Configuration (sysprops)

| Symptom | Start at |
|---|---|
| Sysprop change not taking effect | 📗 [sysprop-catalog §2](3-Resources/data-dictionary/wms2-sysprop-catalog.md) — `@Cacheable` on `SyspropService` |
| New tenant missing config rows | 📗 [sysprop-catalog §11](3-Resources/data-dictionary/wms2-sysprop-catalog.md) — missing `_DEFAULT_VALUE` audit |
| OMS callback URL pointing at `oms-XXXXX.siteboss.net` placeholder | 📗 [sysprop-catalog §5](3-Resources/data-dictionary/wms2-sysprop-catalog.md) — every `WEBSERVICE_*` must be overridden |
| Keycloak auth fails on first request | 📗 [sysprop-catalog §9](3-Resources/data-dictionary/wms2-sysprop-catalog.md) — all 8 KEYCLOAK_* keys mandatory, no defaults |

---

## 10. Entity / package / documentation lookup

| Task | Start at |
|---|---|
| Which DB holds entity X? | 📗 [landlord-vs-tenant-entity-map §3](3-Resources/data-dictionary/wms2-landlord-vs-tenant-entity-map.md) |
| What does term "tote" / "flowbin" / "staging lane" mean? | 📗 [domain-glossary §2–§5](3-Resources/data-dictionary/wms2-domain-glossary.md) |
| Auditing PgBouncer routing | 📘 [tenant-routing §11](3-Resources/architecture/wms2-tenant-routing-datasource-topology.md) |
| Planning a schema migration | 📗 [landlord-vs-tenant-entity-map §8](3-Resources/data-dictionary/wms2-landlord-vs-tenant-entity-map.md) |
| Security audit / who can do what | 📘 [keycloak-role-matrix §9](3-Resources/architecture/wms2-keycloak-role-matrix.md) |
| What cron jobs exist + their schedules | 📘 [scheduled-jobs §6](3-Resources/architecture/wms2-scheduled-jobs-catalog.md) |

---

## Meta — keeping this index current

- When you add a new doc with a "How to debug" / "How to use" section, **add its entries here** before considering the work done.
- If a debug line in a per-doc section and this index disagree, this index wins; update the per-doc section.
- Re-verify every 60 days alongside the architecture docs.

**Next re-verify:** 2026-06-18.
