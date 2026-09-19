---
name: derive-the-bound-constant-from-the-call-site
description: "A state literal copied from a ticket into a DB query can match ZERO rows — making the filter a no-op and the result agree with you; derive it from the call site's constant instead"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 803f22f3-5f65-4b04-8c3a-792d96e3fe07
  modified: 2026-09-18T14:05:23.403Z
---

**When a DB query is your evidence for a predicate's behaviour, derive the bound value from the CALL SITE, never from the ticket's prose.** A wrong literal does not error — it silently filters nothing, and the resulting clean number looks like confirmation.

Measured on SBDEV-3428 (2026-09-18). The ticket justified withdrawing an SDR route with:

> Hydra PRD, `customerorder`, 200 rows: `state != 900` → **200**, `state != NULL` → **0**

I re-ran it, got the same numbers, and wrote them into three files. A review lane then checked what the code actually binds: `MobilePickingService` passes `WmsConstants.State.CANCELED`, and `service/WmsConstants.java:128` says **`CANCELED = 800`**, not 900.

| predicate | rows |
|---|---|
| `state <> 800` ← the real predicate | 192 |
| `state = 800` | **8** |
| `state <> 900` ← the ticket's literal | 200 |
| `state = 900` | **0** |
| `state IS NOT NULL` ← positive control | 200 |

**No row is at 900.** So `!= 900` excluded nothing, returned the whole table, and produced a tidy 200-vs-0 contrast that *agreed with the verdict for the wrong reason*. My positive control (`IS NOT NULL` = 200) was live and passed — it proved the table had rows, which was never in doubt. **It could not see that the filter was a no-op**, because that is a different failure.

**Why this is not merely cosmetic:** the corrected figure is *stronger*. 8 of 200 PRD rows really are cancelled, so the rejected remedy (boxing to `Integer`) would have changed live results, not hypothetical ones. Being wrong about the literal understated my own case.

**The step, and it is ten seconds:** before quoting a query as evidence, grep the constant the code passes and bind that. Then add the two diagnostics that catch a no-op filter — `count(*) FILTER (WHERE col = <literal>)` alongside the `<>` form. If the `=` count is 0, your filter is inert and the `<>` count is just `count(*)`.

This is [[a-control-on-a-literal-cannot-detect-a-narrowed-pattern]] in a new place: there the pattern was narrowed, here the literal was never in the data. Same signature — a control that is genuinely live while the measurement is still meaningless. See also [[a-zero-scan-needs-a-positive-control]] for the inverse, and [[green-tests-that-prove-nothing]].
