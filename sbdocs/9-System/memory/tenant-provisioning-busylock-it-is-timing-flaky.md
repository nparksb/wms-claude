---
name: tenant-provisioning-busylock-it-is-timing-flaky
description: wms2-api TenantWarehouseProvisioningIntegrationTest.busyLockIsRefused flakes on CI (advisory-lock release race); rerun the failed job before investigating
metadata:
  node_type: memory
  type: project
  originSessionId: 08b12365-5b84-4ee2-a0af-159734d3cd55
  modified: 2026-10-28T13:30:20.094Z
---

`TenantWarehouseProvisioningIntegrationTest.busyLockIsRefused` (wms2-api) can error with
"Another warehouse provisioning or demo reset is running" at its LAST line, the `provision(...)`
called right after the try-with-resources closes the holder connection. A session advisory lock is
released only once PostgreSQL has processed the disconnect, so the next attempt can still see it held.

Seen 2026-10-28 on PR #580 (SBDEV-3440) run 40687477654: failed once, passed locally on the same
merge, and `gh run rerun <id> --failed` went green on the same head. Not related to the PR.

**Why:** a red PR check blocks `merge-one.sh`; knowing this one is a known race saves an investigation.
**How to apply:** if it is the ONLY red, rerun the failed job on the same head before digging; if it
reds twice, investigate (or fix the test: release with `pg_advisory_unlock` before closing). Sibling
flakes: [[outbox-concurrent-enqueue-it-is-timing-flaky]], [[replenish-dup-concurrency-slice-it-is-timing-flaky]].
