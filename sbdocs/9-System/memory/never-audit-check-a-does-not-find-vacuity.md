---
name: never-audit-check-a-does-not-find-vacuity
description: "[A] unreachable-target is NOT a defect signal; the vacuous never()s sit in the unexamined [?] bucket"
metadata:
  type: reference
---

`never-audit.py`'s CHECK A flags a `never()` whose method the class under test does not call. That
was assumed to mean "vacuous assertion". **It does not.** Measured 2026-08-29 across 104 `[A]` sites
on wms2-api develop: **0 were noise.** For a *prohibition* test, "the CUT never calls this" is
**the property being asserted**, not evidence of vacuity. CHECK A finds assertions that are
*unprovable by mutation* (no operator ADDS a call) — unprovable ≠ worthless. Sharpest case:
`PickingorderBusinessService` holds `ManageOrderService` and never calls `customerOrderPicked`
because it is retired (`LOG.warn("customerOrderPicked is retired (SBDEV-2381 Fix E)")`); the
`never()` pins that it stays retired.

**The real vacuity signal is different: a mock the CUT does not HOLD at all** (no field, no ctor
param) — `@InjectMocks` cannot wire it, so every implementation satisfies the assertion. The tool
reports exactly those as **`[?] CHECK A SKIPPED`**, not `[A]`. So the bucket everyone reads is the
wrong one. Confirmed instance: `PutawayDestinationResolverUnitTest`'s three `syspropService` sites —
the resolver's ctor takes `SyspropRepository`, and `SyspropService` appears only in a javadoc; a
standalone Mockito 5.17 reproduction had production call the method while both the `never()` and
`verifyNoInteractions` PASSED.

**Before calling any such site noise, check two things** — both produced false verdicts for me:
the test may construct a **real intermediate** holding the mock (`CycleCountControllerUnitTest`
builds a real `CyclecountService`, and has *passing positive* verifies on the same mock), and
`@Transactional` is **declarative** so a `never()` on a transaction manager can never fire either way.

Also: domination requires a positive verify on the **same mock AND same method in the same test**.
"Same mock, different method" does not dominate — `verify(repo).streamAllBy()` stays green when code
starts calling `count()`. Getting this wrong is dangerous because "dominated but harmless" is the
bucket a later cleanup deletes from.

See [[sbdev-3136-never-matcher-widening]] and [[mockito-never-any-primitive-unboxing-trap]].
