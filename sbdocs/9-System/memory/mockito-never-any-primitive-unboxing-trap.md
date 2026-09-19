---
name: mockito-never-any-primitive-unboxing-trap
description: Widening anyLong()/anyBoolean() to bare any() in a never() NPEs at unboxing; primitives are not a blind spot at all
metadata:
  type: reference
---

`verify(mock, never()).m(anyString(), ...)` is null-blind — Mockito's type-specific matchers
exclude nulls (`any(Foo.class)` too, since Mockito 2). Widening to bare `any()` is strictly
stronger for a `never()`. **But the blanket rule "widen everything to any()" is wrong twice:**

**1. Primitive parameters must NOT be widened.** `anyInt/anyLong/anyDouble/anyFloat/anyShort/
anyByte/anyChar/anyBoolean` match the primitive OR the boxed form. Where the parameter is the
**primitive**, a null can never be passed — there is nothing to be blind to — and bare `any()`
returns `null`, which NPEs at the unboxing site:
`Cannot invoke "java.lang.Long.longValue()" because the return value of "any()" is null`.
Measured 2026-08-28 on wms2-api develop: a blind widen of all 328 flagged sites produced
**42 NPEs + 100 cascade errors** (`InvalidUseOfMatchers` / `UnfinishedVerification` from the
matcher left on the stack) across 58 classes. Deciding these needs **signature resolution**,
not name matching. Safe-to-widen set is reference-only: `anyString/anyList/anySet/anyMap/
anyCollection/anyIterable/any(X.class)`.

**2. Overloaded methods need `nullable(X.class)`, not `any()`** — bare `any()` erases the type
overload resolution needs. Measured: 1 site in 328 (`ParcelMonitorViewServiceUnitTest:674`,
`UnitloadService.createUnitload` has two 5-arg overloads).

Also: `anyString()` returns `""` and `anyLong()` returns `0L`, but `any(X.class)` returns
**null** — so a currently-green `any(X.class)` site proves its parameter is a reference type.

**3. Adding ANY `never()` span with a primitive-capable matcher turns the build RED** until you
update `NeverMatcherNullBlindnessArchTest.PRIMITIVE_MATCHER_INVENTORY` — a per-class **exact-equality**
list (not a budget: it fails in both directions, so a count that SHRANK is also red). A class absent
from the list is expected to be 0. Hit on SBDEV-3341 (2026-09-14): 5 new spans → `BUILD FAILURE`,
and since wms2-api gates its deploy on tests, a red develop stops deploying silently.

The rail's failure text tells you the procedure and it is the right one: **read the DECLARED
PARAMETER TYPE, then decide** — primitive → keep `anyBoolean()`/`anyLong()` and ADD an inventory
entry quoting the signature; boxed → **widen to `any()`** and add nothing. Both happened on one
ticket: `transferUnitLoadToLocation(..., boolean ignoreLock, ...)` is primitive (entry added), while
`StockunitRepository.findByUnitloadId(Long)` is boxed (`anyLong()` → `any()`, inventory untouched).
Never edit a count to make a build green.

See [[sbdev-3136-never-matcher-widening]] for the ticket, [[green-tests-that-prove-nothing]]
and [[mutation-harness-traps]] for the neighbouring failure modes.
