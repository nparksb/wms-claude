---
name: race-it-worker-needs-tenantcontext-or-pin-is-vacuous
description: "A wms2 race IT whose worker thread runs closeBOL/runShippingPhase needs the caller's TenantContext copied in, or it dies on TimezoneService and a \"must fail\" pin passes for the wrong reason"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 602069ff-723f-49f9-b608-a82222bf9314
  modified: 2026-10-31T04:00:13.556Z
---

`TenantContext` is a ThreadLocal. A race IT that sets it on the test thread and then runs the service on an `ExecutorService` worker leaves the worker with none. closeBOL's shipping phase (`runShippingPhase`, which `finishTransfer` also runs below TRANSFER) stamps a ship date through `TimezoneService.getWarehouseZoneId()`. Without a tenant that throws `IllegalStateException: ... called without TenantContext`.

Measured on SBDEV-3491, 2026-10-31. A pin asserting "this call must fail" (an optimistic-lock rollback) passed on the fix. A mutant that removed the failure ALSO went red only by dying on the timezone call, which was the wrong reason. The pin had been vacuous until the worker copied the caller's `TenantContext` in and cleared it in `finally`.

**Why:** a "must throw" assertion is satisfied by ANY exception, so a missing ThreadLocal reads as a pass.

**How to apply:** in any cross-thread IT, capture `TenantContext.getCurrentTenant()` on the caller and set it inside the worker. Assert the failure's cause chain (class name AND message), not just that something was thrown, and mutation-check it. Related: [[hub-wms2-test-harness]], [[hub-mutation-testing]].
