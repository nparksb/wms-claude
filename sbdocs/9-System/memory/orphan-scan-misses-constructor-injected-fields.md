---
name: orphan-scan-misses-constructor-injected-fields
description: A dead-code scan keyed on "symbol occurs <=1 time" cannot see an unused constructor-injected Spring field, which sits at 3 occurrences.
metadata:
  type: feedback
---

When deleting a method and sweeping for state it was the last reader of, an occurrence-count
scan with the threshold at `<=1` reports **nothing** — a constructor-injected field always has
**three** occurrences with zero readers: the `private final` declaration, the constructor
parameter, and the `this.x = x;` assignment. A `@Mock` in the matching unit test bottoms out at
**1**, but must be KEPT while it is still a ctor param (removing it makes `@InjectMocks` pass
null); it only becomes removable once the param goes.

Measured on SBDEV-3354: my scan said "no fields become unused". A review lane found **five**
(`meterRegistry`, `stockunitBusinessService`, `pickingorderUnitloadRepository`, plus
`httpRestService` and `omsNotificationService` that were already dead on `origin/develop`).

**Why:** the threshold encodes an assumption about how a symbol is declared, and Spring
constructor injection breaks it. Same shape as [[a-zero-scan-needs-a-positive-control]] — the
instrument fails silently in the direction that agrees with you.

**How to apply:** set the threshold per declaration style, not globally — `<=1` for locals and
imports, `<=3` for a `private final` field on a class with a ctor. Better: confirm with a second
instrument that reads semantics rather than counting text (IDE "safe delete", or compile after
removing). Gate any ctor-param removal on a Spring **context load**, not just unit tests
(see [[verify-spring-bean-changes-clean-compile-and-context-load]]).
