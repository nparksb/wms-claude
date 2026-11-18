---
name: hub-flaky-its
description: Integration tests known to be timing/order flaky; rerun before investigating. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Known flaky ITs (rerun first)**. Moved out of MEMORY.md on 2026-10-15 to keep the index under its size limit; each line links the member memory.

- [[outbox-concurrent-enqueue-it-is-timing-flaky]]: OutboxConcurrentEnqueueIT flaky
- [[replenish-dup-concurrency-slice-it-is-timing-flaky]]: ReplenishDupConcurrencySliceIT flaky
- [[outbox-lane-claim-it-order-flaky]]: OutboxLaneClaimIT reds in full run
- [[wms2-testcontainers-reuse-breaks-an-it]]: TC reuse breaks ParcelMonitor IT
- [[wms2-web-ui-returnsaudit-export-test-timing-flaky]]: web-ui returnsAudit export case times out under full-suite load, on develop too; passes alone
- [[keycloak-password-verifier-teardown-is-timing-flaky]]: KeycloakPasswordVerifierUnitTest teardown "logouts still running" flake (unit lane, CI)
- [[closebol-unitload-row-order-it-layout-flaky]]: ClosebolUnitloadRowOrderIT ctid layout precondition ERROR in CI; rerun first
- [[manual-entry-override-logging-unit-test-cme-flaky]]: ManualEntryOverrideLoggingUnitTest CME on a ListAppender list in a full unit run; passes alone
- [[pick-line-realignment-it-seed-fk-crosstalk]]: PickLineRealignmentIT ac6 seed FK (unitload 98306) ERROR in full verify; passes alone
