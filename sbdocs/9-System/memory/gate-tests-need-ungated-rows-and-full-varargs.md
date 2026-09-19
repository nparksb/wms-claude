---
name: gate-tests-need-ungated-rows-and-full-varargs
description: "Two measured ways an authz gate test passes while the gate is wrong: a pin with only GATED rows cannot see a class-level collapse, and a Mockito recorder reading args[1] drops expanded varargs so a WIDENED gate looks single"
metadata:
  node_type: memory
  type: feedback
---

Both found on SBDEV-3154, both **survived the first mutation round**, both invisible in a green suite.

**1. A gating pin needs rows that assert routes stay UNGATED.** `Sbdev3017TrancheGateContextTest`
compares each expected route against the `@RequiresFunction` resolved method-then-class. With only
**gated** rows, replacing every method-level annotation with **one class-level
`@RequiresFunction`** left that class *and* the request-level denial test **entirely GREEN** — a
class annotation resolves identically for every gated row. Nothing detected a change that silently
swept in four unrelated handlers, one of them already `@PreAuthorize(IS_SB_ADMIN)`.

The fix is two `row(class, path)` calls with **no** function, meaning "expects NO GATE". Those rows,
not the gated ones, are what fail. ⚠ An empty-value row *also* asserts the absence of method
security, so you cannot write one for a handler that legitimately carries `@PreAuthorize` — that
handler stays uncovered and you should say so rather than imply otherwise.

**Generalises:** a pin over "these things are gated" cannot see over-gating. If a prohibition matters
("never put a class-level annotation here"), something must assert the thing that would break.

**2. Mockito EXPANDS varargs into `getArguments()`.** For
`checkAnyAccess(String username, String... functions)` the live shape is
`[username, f1, f2, …]`, **not** `[username, String[]]`. A recorder like

```java
if (all[1] instanceof String[] arr) { ...ideal path, DEAD... }
else { requested.add(String.valueOf(all[1])); }   // drops f2..fn
```

records only the first function, so an assertion that the gate requires **exactly one** function
passes against a gate widened to a set. `any(String[].class)` is `VarArgAware`, so the stub still
matches and nothing errors. Walk `all[1..n]` and handle both shapes.

**Mutation set for any function-gate change** (all 9 killed on SBDEV-3154 only after the two fixes):
drop each annotation · wire one to a **different** constant (still 403 — needs a recorded-function
assertion to catch) · **widen** one to two functions · collapse to a class-level default · drop a pin
row · add the class to `GUARDED` (context refuses to boot, by design) · swap
`setupMockMvcWithGuard` for guardless `standaloneSetup` (must FAIL — if it passes, the test never
exercised the interceptor). Related: [[green-tests-that-prove-nothing]],
[[wms2-function-gate-anti-drift-only-covers-guarded-classes]], [[mutation-harness-traps]].
