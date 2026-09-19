---
name: archunit-call-site-rules-have-five-blind-spots
description: An ArchUnit rule over getMethods()+getMethodCallsFromSelf() misses constructors, static init, method references, subtype receivers and field writes — measured, 5 escapes survived 5673 tests
metadata:
  type: reference
---

**A "only X may call Y" ArchUnit rule is far narrower than it reads.** Measured on wms2-api 2026-08-27
(SBDEV-3017 R8-10): a rule guarding `Itemdata.setPutawaylocationId` had **six** escapes, **five of which
survived all 5673 tests**. The naive form —
`getMethods() → getMethodCallsFromSelf()` filtered on `getTargetOwner().getName().equals(T)` — sees only
*invokevirtual-shaped calls, named exactly Y, from a non-constructor method body, through a reference
statically typed T*. Each clause is a hole:

| Blind spot | Fix |
|---|---|
| **constructors and static initializers** — `getMethods()` excludes both | `getCodeUnits()` |
| **method references** (`x::setFoo`) — `invokedynamic`; the target is only in the constant pool | union `getMethodReferencesFromSelf()` |
| **subtype-typed receiver** — `getTargetOwner()` is the *static receiver type*, not the declaring class | `getTargetOwner().isAssignableTo(T.class)` |
| **direct field writes** — watching a setter is not watching a column; an *alias* setter (`setPutawayLocationId`, one capital L) writing `this.putawaylocationid` escapes entirely | a second assertion over `getCodeUnits() → getFieldAccesses()` filtered on `AccessType.SET` |
| **Jackson binding** — `@RequestBody <Entity>` sets fields by reflection: **zero** static call sites, then `save()` flushes | a separate rule forbidding the entity as an `@RequestBody` parameter **type** |
| **`@Modifying`/native SQL** — a query string is opaque to bytecode | a separate rule pinning the repository's `@Modifying` method set |

The last two are **structurally unreachable** by any call-site rule. Never let a rule's javadoc claim
"no Java code bypasses X" — that exact sentence was measurably false.

**API trap:** on `JavaCodeUnit` it is `getFieldAccesses()`; `getFieldAccessesFromSelf()` is on `JavaClass`.
(ArchUnit 1.3.0, the version in wms2-api.)

**GRANULARITY: split it by what the assertion is for.** Asserting `Class#method` on *calls* produces a
**false positive** — moving the legitimate call into a lambda or anonymous inner class reds the rule against
CORRECT code, with the diagnostic `["#run"]`: empty simple name, no package, nothing to grep. That is the
*correct code reds the rule → rule gets deleted* failure mode. So:
- **calls → CLASS granularity** (any lambda/inner/helper inside the legitimate writer is fine); carry the
  offending code units into the failure *message* so a red still says where to look;
- **field writes → METHOD granularity**, because the alias-setter escape lives inside the entity itself and
  a class-level check would accept it.

⚠ **Normalizing the origin label is not the fix.** Normalizing to the enclosing top-level class fixes the
*message* while the assertion still pins `#legitMethod` → still red. **A better diagnostic is not a fix.**

Cost of class granularity, worth stating wherever it is used: a *new* method on the legitimate writer class
could bypass validation. Narrower than the false positive it removes.

Related: [[mutation-harness-traps]],
[[green-tests-that-prove-nothing]],
[[wms2-admincontroller-is-a-base-class-for-43-controllers]] (why `getDeclaredMethods()` also needs
`getMethods()` unioned for inherited mappings).
