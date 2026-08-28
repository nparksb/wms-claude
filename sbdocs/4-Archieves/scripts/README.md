---
title: "Archives — Retired Plan Verification Scripts"
type: index
status: active
version: both
scope: archives
tags: [moc, index, archive, scripts]
---

# Archives — Retired Plan Verification Scripts

Acceptance / verification harnesses (`verify-<plan-id>.sh`) whose paired plan has been **archived**. When a plan is archived, its verify script is retired here alongside it (see the [`archive-plan` skill](../../../.claude/skills/archive-plan/SKILL.md), step 5e).

**Active** scripts — those paired with a plan still in [`../../1-Projects/`](../../1-Projects/) — live in [`../../9-System/scripts/`](../../9-System/scripts/). Durable regression protection belongs in each repo's JUnit/CI suite; these shell harnesses are pre-merge acceptance gates kept here for reference and reproduction.

> These are retired gates, not live CI. They may reference code paths, tenants, or line numbers that have since moved. Re-read the paired plan before trusting one.

---

## Script → archived plan

| Verification script | Archived plan |
|---|---|
| `verify-260520-content-derived-idempotency-key.sh` | [260520-content-derived-idempotency-key](../wms2/plan/260520-content-derived-idempotency-key.md) |
| `verify-260520-picking-finished-oms-notification-fix.sh` | [260520-picking-finished-oms-notification-fix](../wms2/plan/260520-picking-finished-oms-notification-fix.md) |
| `verify-260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.sh` | [260521-customerorderbatchservice-runclubline-self-invocation-tx-fix](../wms2/plan/260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.md) |
| `verify-260604-cancelorder-club-batch-state-guard.sh` | [260604-cancelorder-club-batch-state-guard](../wms2/plan/260604-cancelorder-club-batch-state-guard.md) |
| `verify-260604-club-line-rerun-idempotency-fix.sh` | [260604-club-line-rerun-idempotency-fix](../wms2/plan/260604-club-line-rerun-idempotency-fix.md) |
| `verify-260609-oms-transfer-id-wrong-source-fix.sh` | [260609-oms-transfer-id-wrong-source-fix](../wms2/plan/260609-oms-transfer-id-wrong-source-fix.md) |
| `verify-260610-excel-export-localdatetime-unsupported-type.sh` | [260610-excel-export-localdatetime-unsupported-type](../wms2/plan/260610-excel-export-localdatetime-unsupported-type.md) |
| `verify-260610-wms2-multi-replica-hardening.sh` | [260610-wms2-multi-replica-hardening](../wms2/plan/260610-wms2-multi-replica-hardening.md) |
| `verify-260610-wms2-sku-trim-normalization.sh` | [260610-wms2-sku-trim-normalization](../wms2/plan/260610-wms2-sku-trim-normalization.md) |
| `verify-260614-outbox-stuck-aggregate-metric.sh` | [260614-outbox-stuck-aggregate-metric](../wms2/plan/260614-outbox-stuck-aggregate-metric.md) |
| `verify-260624-stock-unit-history-on-unitload-relocation.sh` | [260624-stock-unit-history-on-unitload-relocation](../wms1/plan/260624-stock-unit-history-on-unitload-relocation.md) |
| `verify-SBDEV-2727-landlord-tenant-active-flag.sh` | [SBDEV-2727-landlord-tenant-active-flag](../wms2/plan/SBDEV-2727-landlord-tenant-active-flag.md) |
| `verify-260626-restore-replenishment-triggers-on-lock-state-changes.sh` | [260626-restore-replenishment-triggers-on-lock-state-changes](../wms1/plan/260626-restore-replenishment-triggers-on-lock-state-changes.md) |
| `verify-260629-activate-transfer-atomicity.sh` | [260629-activate-transfer-atomicity](../wms2/plan/260629-activate-transfer-atomicity.md) |
| `verify-260629-transfer-lane-leak-on-cancel.sh` | [260629-transfer-lane-leak-on-cancel](../wms2/plan/260629-transfer-lane-leak-on-cancel.md) |
| `verify-260629-transfers-available-lanes-orderbatchid-mislabel.sh` | [260629-transfers-available-lanes-orderbatchid-mislabel](../wms2/plan/260629-transfers-available-lanes-orderbatchid-mislabel.md) |
| `verify-260709-duplicate-replenishment-orders-concurrent-generation.sh` | [260709-duplicate-replenishment-orders-concurrent-generation](../wms1/plan/260709-duplicate-replenishment-orders-concurrent-generation.md) |
| `verify-260709-duplicate-replenishment-orders-concurrent-generation-v2.sh` | [260709-duplicate-replenishment-orders-concurrent-generation](../wms1/plan/260709-duplicate-replenishment-orders-concurrent-generation.md) |
| `verify-260709-picking-nirvana-guard-blocks-self-depleting-pick.sh` | [260709-picking-nirvana-guard-blocks-self-depleting-pick](../wms1/plan/260709-picking-nirvana-guard-blocks-self-depleting-pick.md) |
| `verify-260709-putaway-blank-screen-stale-persisted-state.sh` | [260709-putaway-blank-screen-stale-persisted-state](../wms1/plan/260709-putaway-blank-screen-stale-persisted-state.md) |
| `verify-SBDEV-1666-staging-transfer-lane-replenish-source-exclusion.sh` | [SBDEV-1666-staging-transfer-lane-replenish-source-exclusion](../wms2/plan/SBDEV-1666-staging-transfer-lane-replenish-source-exclusion.md) |
| `verify-SBDEV-1714-replenishment-finish-audit-snapshot.sh` | [SBDEV-1714-replenishment-finish-audit-snapshot](../wms2/plan/SBDEV-1714-replenishment-finish-audit-snapshot.md) |
| `verify-SBDEV-1762-transfer-lane-club-like-depletion.sh` | [SBDEV-1762-transfer-lane-club-like-depletion](../wms2/plan/SBDEV-1762-transfer-lane-club-like-depletion.md) |
| `verify-SBDEV-1921-order-cancellation-reversal-workflow.sh` | [SBDEV-1921-order-cancellation-reversal-workflow](../wms2/plan/SBDEV-1921-order-cancellation-reversal-workflow.md) |
| `verify-SBDEV-2001-empty-pallet-misrouted-to-nirvana.sh` | [SBDEV-2001-empty-pallet-misrouted-to-nirvana](../wms2/plan/SBDEV-2001-empty-pallet-misrouted-to-nirvana.md) |
| `verify-SBDEV-2070-replenish-heldup-unreachable-message-fix.sh` | [SBDEV-2070-replenish-heldup-unreachable-message-fix](../wms2/plan/SBDEV-2070-replenish-heldup-unreachable-message-fix.md) |
| `verify-SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.sh` | [SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move](../wms2/plan/SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.md) |
| `verify-SBDEV-2214-oms-http-post-inside-class-level-transactional.sh` | [SBDEV-2214-oms-http-post-inside-class-level-transactional](../wms2/plan/SBDEV-2214-oms-http-post-inside-class-level-transactional.md) |
| `verify-SBDEV-2215-adviceservice-no-transaction-wrapping.sh` | [SBDEV-2215-adviceservice-no-transaction-wrapping](../wms2/plan/SBDEV-2215-adviceservice-no-transaction-wrapping.md) |
| `verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh` | [SBDEV-2216-finishtransfer-bulk-bol-close-perf](../wms2/plan/SBDEV-2216-finishtransfer-bulk-bol-close-perf.md) |
| `verify-SBDEV-2217-sequence-number-silent-minus-one.sh` | [SBDEV-2217-sequence-number-silent-minus-one](../wms2/plan/SBDEV-2217-sequence-number-silent-minus-one.md) |
| `verify-SBDEV-2218-parallelstream-against-hibernate-session.sh` | [SBDEV-2218-parallelstream-against-hibernate-session](../wms2/plan/SBDEV-2218-parallelstream-against-hibernate-session.md) |
| `verify-SBDEV-2219-warehouse-stock-report-unbounded-findall.sh` | [SBDEV-2219-warehouse-stock-report-unbounded-findall](../wms2/plan/SBDEV-2219-warehouse-stock-report-unbounded-findall.md) |
| `verify-SBDEV-2220-cleanup-old-messages-batch-cap-and-tx.sh` | [SBDEV-2220-cleanup-old-messages-batch-cap-and-tx](../wms2/plan/SBDEV-2220-cleanup-old-messages-batch-cap-and-tx.md) |
| `verify-SBDEV-2221-transactional-outbox-pilot.sh` | [SBDEV-2221-transactional-outbox-pilot](../wms2/plan/SBDEV-2221-transactional-outbox-pilot.md) |
| `verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh` | [SBDEV-2222-rest-inbound-no-idempotency-contract](../wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md) |
| `verify-SBDEV-2223-confirmPick-last-pick-detection-race.sh` | [SBDEV-2223-confirmPick-last-pick-detection-race](../wms2/plan/SBDEV-2223-confirmPick-last-pick-detection-race.md) |
| `verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh` | [SBDEV-2228-cron-jobs-unbounded-resultsets](../wms2/plan/SBDEV-2228-cron-jobs-unbounded-resultsets.md) |
| `verify-SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.sh` | [SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix](../wms2/plan/SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.md) |
| `verify-SBDEV-2230-rest-exception-handler-retryable-differentiation.sh` | [SBDEV-2230-rest-exception-handler-retryable-differentiation](../wms2/plan/SBDEV-2230-rest-exception-handler-retryable-differentiation.md) |
| `verify-SBDEV-2231-order-rest-create-partial-batch-atomicity.sh` | [SBDEV-2231-order-rest-create-partial-batch-atomicity](../wms2/plan/SBDEV-2231-order-rest-create-partial-batch-atomicity.md) |
| `verify-SBDEV-2232-parcelmonitorview-palletise-toctou-lock-fix.sh` | [SBDEV-2232-parcelmonitorview-palletise-toctou-lock-fix](../wms2/plan/SBDEV-2232-parcelmonitorview-palletise-toctou-lock-fix.md) |
| `verify-SBDEV-2233-nametypeservice-date-format-pattern-fix.sh` | [SBDEV-2233-nametypeservice-date-format-pattern-fix](../wms2/plan/SBDEV-2233-nametypeservice-date-format-pattern-fix.md) |
| `verify-SBDEV-2234-replenishment-maintenance-tx-and-lock.sh` | [SBDEV-2234-replenishment-maintenance-tx-and-lock](../wms2/plan/SBDEV-2234-replenishment-maintenance-tx-and-lock.md) |
| `verify-SBDEV-2235-sku-rest-partial-batch-atomicity.sh` | [SBDEV-2235-sku-rest-partial-batch-atomicity](../wms2/plan/SBDEV-2235-sku-rest-partial-batch-atomicity.md) |
| `verify-SBDEV-2236-return-advice-auto-receive-fix.sh` | [SBDEV-2236-return-advice-auto-receive-fix](../wms2/plan/SBDEV-2236-return-advice-auto-receive-fix.md) |
| `verify-SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.sh` | [SBDEV-2237-mobilepickingservice-selectandreserve-lock-split](../wms2/plan/SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.md) |
| `verify-SBDEV-2238-4.1-bol-closeBOL-outbox-migration.sh` | [SBDEV-2238-4.1-bol-closeBOL-outbox-migration](../wms2/plan/SBDEV-2238-4.1-bol-closeBOL-outbox-migration.md) |
| `verify-SBDEV-2238-4.2-rest-controller-pii-log-reduction.sh` | [SBDEV-2238-4.2-rest-controller-pii-log-reduction](../wms2/plan/SBDEV-2238-4.2-rest-controller-pii-log-reduction.md) |
| `verify-SBDEV-2238-4.5-cron-job-micrometer-metrics.sh` | [SBDEV-2238-4.5-cron-job-micrometer-metrics](../wms2/plan/SBDEV-2238-4.5-cron-job-micrometer-metrics.md) |
| `verify-SBDEV-2238-outbox-phase2-remaining-services.sh` | [SBDEV-2238-outbox-phase2-remaining-services](../wms2/plan/SBDEV-2238-outbox-phase2-remaining-services.md) |
| `verify-SBDEV-2381-wms-parcel-status-out-of-order.sh` | [SBDEV-2381-wms-parcel-status-out-of-order](../wms2/plan/SBDEV-2381-wms-parcel-status-out-of-order.md) |
| `verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix.sh` | [SBDEV-2384-replenishment-monitor-pickpack-classification-fix](../wms1/plan/SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md) |
| `verify-SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.sh` | [SBDEV-2390-mobile-pickpack-keycloak-refresh-loop](../wms2/plan/SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md) |
| `verify-SBDEV-2390-web-pickpack-keycloak-refresh-loop.sh` | [SBDEV-2390-web-pickpack-keycloak-refresh-loop](../wms2/plan/SBDEV-2390-web-pickpack-keycloak-refresh-loop.md) |
| `verify-SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.sh` | [SBDEV-2391-mobile-wms-refresh-tenant-not-recognized](../wms2/plan/SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.md) |
| `verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh` | [SBDEV-2391-wms-refresh-tenant-not-recognized](../wms2/plan/SBDEV-2391-wms-refresh-tenant-not-recognized.md) |
| `verify-SBDEV-2474-exclude-shipped-locks-from-lock-report.sh` | [SBDEV-2474-exclude-shipped-locks-from-lock-report](../wms2/plan/SBDEV-2474-exclude-shipped-locks-from-lock-report.md) |
| `verify-SBDEV-2474-lock-report-exclude-shipped-locks.sh` | [SBDEV-2474-lock-report-exclude-shipped-locks](../wms2/plan/SBDEV-2474-lock-report-exclude-shipped-locks.md) |
| `verify-SBDEV-2481-stale-pick-line-realignment-on-stock-move.sh` | [SBDEV-2481-stale-pick-line-realignment-on-stock-move](../wms1/plan/SBDEV-2481-stale-pick-line-realignment-on-stock-move.md) |
| `verify-SBDEV-2485-club-split-unitload-reprint-label-v2.sh` | [SBDEV-2485-club-split-unitload-reprint-label](../wms2/plan/SBDEV-2485-club-split-unitload-reprint-label.md) |
| `verify-SBDEV-2486-club-lane-blank-screen-split-adjust.sh` | [SBDEV-2486-club-lane-blank-screen-split-adjust](../wms1/plan/SBDEV-2486-club-lane-blank-screen-split-adjust.md) |
| `verify-SBDEV-2492-replen-order-source-sync-on-unitload-move.sh` | [SBDEV-2492-replen-order-source-sync-on-unitload-move](../wms1/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md) |
| `verify-SBDEV-2496-prshw222-trailing-space-sku-duplication.sh` | [SBDEV-2496-prshw222-trailing-space-sku-duplication](../wms1/plan/SBDEV-2496-prshw222-trailing-space-sku-duplication.md) |
| `verify-SBDEV-2496-trailing-space-sku-duplication-v2.sh` | [SBDEV-2496-prshw222-trailing-space-sku-duplication](../wms1/plan/SBDEV-2496-prshw222-trailing-space-sku-duplication.md) |
| `verify-SBDEV-2507-web-palletize-already-truckloaded-guard.sh` | [SBDEV-2507-web-palletize-already-truckloaded-guard](../wms1/plan/SBDEV-2507-web-palletize-already-truckloaded-guard.md) |
| `verify-SBDEV-2507-web-palletize-already-truckloaded-guard-v2.sh` | [SBDEV-2507-web-palletize-already-truckloaded-guard](../wms1/plan/SBDEV-2507-web-palletize-already-truckloaded-guard.md) |
| `verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard.sh` | [SBDEV-2512-partitionallowed-split-pick-overstock-guard](../wms1/plan/SBDEV-2512-partitionallowed-split-pick-overstock-guard.md) |
| `verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard-v2.sh` | [SBDEV-2512-partitionallowed-split-pick-overstock-guard](../wms1/plan/SBDEV-2512-partitionallowed-split-pick-overstock-guard.md) |
| `verify-SBDEV-2554-mobile-keycloak-reload-logout-regression.sh` | [SBDEV-2554-mobile-keycloak-reload-logout-regression](../wms2/plan/SBDEV-2554-mobile-keycloak-reload-logout-regression.md) |
| `verify-SBDEV-2554-web-keycloak-reload-logout-regression.sh` | [SBDEV-2554-web-keycloak-reload-logout-regression](../wms2/plan/SBDEV-2554-web-keycloak-reload-logout-regression.md) |
| `verify-SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.sh` | [SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock](../wms2/plan/SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.md) |
| `verify-SBDEV-2608-tenant-db-switch-stale-connection-pool-refresh.sh` | [SBDEV-2608-tenant-db-switch-stale-connection-pool-refresh](../wms2/plan/SBDEV-2608-tenant-db-switch-stale-connection-pool-refresh.md) |
| `verify-SBDEV-2610-move-unitload-false-reserved-block-v2.sh` | [SBDEV-2610-move-unitload-false-reserved-block](../wms2/plan/SBDEV-2610-move-unitload-false-reserved-block.md) |
| `verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh` | [SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500](../wms2/plan/SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.md) |
| `verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh` | [SBDEV-2778-return-to-inventory-not-received-bol-not-closed](../wms2/plan/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md) |
| `verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh` | [SBDEV-3003-move-stock-lost-update-inventory-inflation](../wms1/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation.md) (v1) · [same base](../wms2/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation.md) (v2) · [SBDEV-3003-slice2-transfer-stock-idempotency](../wms2/plan/SBDEV-3003-slice2-transfer-stock-idempotency.md) |
| [verify-SBDEV-3013-role-function-write-surface-gating.sh](verify-SBDEV-3013-role-function-write-surface-gating.sh) | [SBDEV-3013](../wms2/plan/SBDEV-3013-role-function-write-surface-gating.md) | v2 | 2026-08-21 | Door ② only (controller gates). Door ① shipped after the script was written and has no rows here — it is covered by `SdrWriteExposureUnitTest` instead. |
| `verify-SBDEV-2821-tier1-direct-placement-onto-pick-face.sh` | [SBDEV-2821-tier1-direct-placement-onto-pick-face.md](../wms2/plan/SBDEV-2821-tier1-direct-placement-onto-pick-face.md) | 2026-08-28 |
| `verify-SBDEV-2951-transfer-club-available-counts-lane-only.sh` | [SBDEV-2951-transfer-club-available-counts-lane-only.md](../wms2/plan/SBDEV-2951-transfer-club-available-counts-lane-only.md) | 2026-08-28 |
| `verify-SBDEV-2968-mobile-ui-function-gating-enforcement.sh` | [SBDEV-2968-mobile-ui-function-gating-enforcement.md](../wms2/plan/SBDEV-2968-mobile-ui-function-gating-enforcement.md) | 2026-08-28 |

_77 rows, matching 77 `verify-*.sh` files (re-counted 2026-08-21 after SBDEV-3003 was retired here). Regenerate after a backfill sweep; single archivals append one row via the archive-plan skill._

_Note: the SBDEV-3003 row maps to **three** plans — a v1/v2 pair sharing a base name plus the v2 Slice 2 plan — because one script graded all three (49 rows). Its final grading against `origin/develop` was 49 pass / 0 fail / 3 skip; graded against local checkouts that were behind origin it read 5 pass / 44 fail, so re-grade in a detached worktree at `origin/develop`, never in a main checkout._
