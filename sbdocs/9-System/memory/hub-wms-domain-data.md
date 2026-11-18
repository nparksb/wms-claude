---
name: hub-wms-domain-data
description: Business-flow and production-data facts: OMS notifications, transfers, returns, locks, stock records, sysprops. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **WMS domain & live-data facts**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [WineCo prd replenishorder needs a state index](wineco-prod-autovacuum-off-and-replenishorder-no-state-index.md) — partial index `(state) WHERE
- [wms2 outbox dispatcher is Status-blind → silent OMS loss](wms2-outbox-dispatcher-status-blind-silent-loss.md) — Phase 2 NOT started; THREE envelope
- [Hydra UAT outbound pallet label patterns](wms2-uat-outbound-pallet-label-patterns.md) — "String is not valid" = label matched neither sysprop regex
- [v1 afterCommit Message rows silently lost](wms1-aftercommit-message-rows-silently-lost.md) — createServiceLog has no REQUIRES_NEW; 3 notifications dead since 2026-03-05
- [The v1 OMS-notification plan's "implemented" is false](wms1-oms-notification-plan-claims-a-fix-that-never-existed.md) — OmsNotificationHelper is in no commit on any ref
- [v2 sendAfterCommit guard is inverted](wms2-sendaftercommit-guard-is-inverted.md) — SBDEV-3267; isActualTransactionActive() TRUE in afterCommit; 139 totes / 0 notifications
- [Tote reuse breaks every Optional<> finder](tote-reuse-nonunique-optional-finders.md) — SBDEV-3287; only a PK on the table; v2 unpatched at 3 sites
- [v2 transfer completion round trip never fired](wms2-transfer-completion-roundtrip-never-fired.md) — 0 rows prd+UAT ever; the signal fires at the DESTINATION; rides a REGULAR BOL
- [Hydra PRD notifies the UAT OMS](wms2-hydra-prd-notifies-uat-oms.md) — 3 sysprops pointed at api-oms-uat; FIXED 2026-09-11; never read SENT as delivery
- [Transfer orders get no intermediate OMS status](wms-transfer-orders-get-no-intermediate-oms-status.md) — IMPORT then SHIPPED only; 588 prd batches; diff any under-notified flow against CLUB
- [RTS completeReversal moves NO stock](wms2-rts-completereversal-moves-no-stock.md) — picktounitload_id FKs pickingorder_unitload, not unitload; 0/16 PRD rows
- [OMS readytopick/picking DO resolve a transfer's unique_id](oms-readytopick-picking-resolve-transfer-unique-id.md) — SETTLED on dev 2026-09-11; `processed:1` not the 200; both of the 3311 gate's stated blockers now discharged
- [wms2 outbox latency baseline 2026-09-13](wms2-outbox-latency-baseline-2026-09-13.md) — PRD RELEASED phase-locked at a full 15s tick (stddev 0.20s); measure from the table, no metric needed
- [wms2 RECONCILE_CRON owns second 50](wms2-reconcile-cron-second-50-constrains-cadences.md) — sub-minute job cadences must avoid it; */2 and */1 illegal, */3 fine
- [CANCELED is not "beyond PACKED" in wms2](wms2-canceled-is-not-beyond-packed.md) — 4 cancel guards, 2 wrong; fixing only the predicate throws
- [SBDEV-1512 damaged returns: D1–D8](sbdev-1512-damaged-returns-decisions.md) — "damaged" is entity_lock 103 NOT the location; E7 was inverted, real defect was OMS netting (fixed by SBDEV-3897, on prod; 3366 superseded)
- [Order "On Hold" state 55 = fragmented, not short](wms-on-hold-55-is-fragmentation-not-shortage.md) — SBDEV-2512 guard; needs ONE covering unit; label lies; merge units to unblock
- [v1 WineCo timestamps are warehouse-LOCAL](wms1-timestamps-are-warehouse-local-not-utc.md) — `now()` is UTC; filters are off 7-8h and read as a dead cron; code comment claims UTC and is wrong
- [An order number is not an identity](wms-order-number-is-not-an-identity.md) — `number` is per-tenant sequential so dev collides with prod; check `externalnumber` before claiming impact
- [stockrecord staging-scan traps](stockrecord-staging-scan-traps.md) — 2 rows per event + MANUAL_SPLIT has a serial BULK producer; both inflate concurrency scans
- [v2 never short-picks](wms2-no-short-picks-confirmpick-callers-pass-ordered-amount.md) — both confirmPick callers pass getAmount(); a guard that permits ≠ a path that produces
- [unitload_record CREATED ≠ mint census](unitload-record-created-is-not-a-mint-census.md) — closeBOL batch writes CREATED on shipping; system locs typed overstock pallet
- [Replen Monitor "0/Unassigned" = misreading](replen-monitor-empty-cells-are-not-data-defects.md) — ⓘ=no RO, Unassigned=no FLA, Qty Req=demand; filed 3x; PR web-ui #151
- [Held-share model overstates other holders on PRD](held-share-model-overstates-other-holders-on-prd.md) — 23 PRD orders hold < requested; a release followed by a move needs held + what the move needs
- [Adjust Reserved Amount = release-replen-hold button](adjust-reserved-amount-is-the-release-replen-hold-button.md) — PRD: 330/330 cuts to 0, 96% on an SU with a live replen order; attribute, don't refuse
- [seqentities dual-island id space](wms2-seqentities-dual-island-id-space.md) — migrated DBs: check the next seqentities value lands in a free gap before cutover
- [SBDEV-3325 OMS egress watchdog](sbdev-3325-oms-egress-watchdog.md)
- OMS↔WMS data gaps: [Empty BOL notify always rejected by OMS](wms-empty-bol-oms-notification-rejected.md) · [OMS v2 picking_date is UTC (Future Picking)](oms-v2-picking-date-utc-future-picking.md) · [stock_view exports every itemdata row](wms-stock-view-exports-every-itemdata-row.md)
- wms2 config traps: [Client w/o section stalls Pick & Pack at RAW](wms2-client-without-section-silently-stalls-pickpack.md) · [Putaway config is sb_admin-only](wms2-putaway-config-is-sb-admin-only.md) · [146 live sysprop keys vs 124 constants](wms2-sysprop-live-keys-exceed-code-constants.md)
- UTC migration: [V1.2.05 hard-codes 3 functions](wms2-utc-v1205-hardcoded-function-list.md) · [UI tz from stale persistedState](wms2-ui-warehouse-timezone-stale-persistedstate.md)
- [OMS transfer replay safety = createTransfer dup check](oms-shiptransfer-replay-safety-rests-on-createtransfer-duplicate-check.md) — cross-repo contract
- [UL relabel -X- + RETURN record-shape drift](wms-unitload-relabel-and-return-record-shape-traps.md) — join by id
- [RETURN advices allow over-delivery](wms2-return-advices-allow-overdelivery.md) — all PRD; guard never fires
- [SBDEV-1581 job ships OFF](sbdev-1581-empty-pallet-cleanup-activation-pending.md) — flip ACTIVATED per tenant
- [All transfers ride REGULAR BOLs on WineCo PRD](offsite-transfers-ride-regular-bols.md) — 305 intra + 325 offsite; never refuse it; census PRD before any transfer rule (SBDEV-1564)
- [message.redeliver_id = manual resend only](message-redeliver-id-is-manual-resend-only.md) — null ≠ undelivered; match md5(message)
