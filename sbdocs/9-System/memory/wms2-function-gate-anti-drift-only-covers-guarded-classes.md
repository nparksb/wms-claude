---
name: wms2-function-gate-anti-drift-only-covers-guarded-classes
description: wms2's @RequiresFunction works on any controller, but the fail-closed and bean-init anti-drift protections only cover classes in FunctionGuardInterceptor.GUARDED — and shared controllers must never join it
metadata:
  type: reference
---

Measured on `develop` `d70204c`, 2026-08-22, reviewing SBDEV-2967-C.

Two separate mechanisms, and it is easy to assume one implies the other:

1. **Enforcement** — `FunctionGuardInterceptor` resolves a **method-level** `@RequiresFunction` *before* it
   consults `GUARDED` (`:119-122`). So a method-level annotation is honoured on **any** controller, in or out
   of the set. This is why `StockUnitController.transferStock` is genuinely gated today.
2. **Anti-drift** — both fail-closed behaviour (`:124-133`) and
   `FunctionGuardStartupAssertion.findUnannotatedGuardedHandlers(handlers, guarded)` key on **`GUARDED`
   membership**. A class outside the set gets **no** protection against a future unannotated handler, and no
   bean-init failure.

**The trap:** the obvious way to get protection 2 is to add the controller to `GUARDED` — which fail-closes
**every** unannotated handler on it. `StockUnitController:69-73` records the SBDEV-2968 decision in the code:
adding it "would fail closed on all ~40 of its endpoints, several of which serve the web UI." Same for
`UnitLoadController` (6 read GETs). `GUARDED` works for the 11 mobile controllers only because each carries a
**class-level** `@RequiresFunction` default, so every handler resolves something.

**So for a shared controller you cannot have both.** Gate the methods you need, keep the class out of
`GUARDED`, and carry the anti-drift burden in an ArchUnit rule that **enumerates the endpoints by name +
parameter arity**. Arity is not optional: `StockUnitController` declares
`getStorageLocationsForStockMovement` **twice** (`:598` no-arg, `:608` `@PathVariable labelId` serving
`/isUnitLoadIdValid/{labelId}`), so a name-keyed pin can match the wrong overload and pass.
See [[green-tests-that-prove-nothing]].

**Testing a gate at all requires the right helper.** `BaseControllerUnitTest.setupMockMvc` installs **no
interceptor**, so `@RequiresFunction` is completely inert under it and a deny/allow pair written with it
passes on an ungated controller. Only `setupMockMvcWithGuard(controller, interceptor)` (`:95`) exercises a
gate — documented there as "the one MockMvc mode in which authorization can actually be exercised in this
repository", because `standaloneSetup` installs no method-security advisor (that is how SBDEV-2863 shipped a
broken `@PreAuthorize` SpEL for nine months) and the `@SpringBootTest` lane is down (SBDEV-2217). It is
**strictly additive**, so adding gates does not break existing controller tests — which also means nothing
tells you that you used the wrong helper. Reference impl: `unit/controller/mobile/FunctionGuardMockMvcUnitTest`.
See [[wms2-only-one-of-80-functions-is-enforced]], [[verify-script-traps]].
