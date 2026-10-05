---
name: mockito-varargs-captor-needs-array-class
description: "A single ArgumentCaptor.forClass(X.class) against a varargs call matches only arity-1 and reads as \"never called\""
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d37a5874-0f95-4a8f-ae4e-8144de30c0e8
  modified: 2026-09-21T12:47:07.480Z
---

Capturing a varargs argument with `ArgumentCaptor.forClass(X.class)` + one `captor.capture()` does
**not** capture every vararg. Under Mockito 5.17 it matches **only an arity-1 invocation**, so a real
57-argument call fails `verify(...)` with *"Argument(s) are different! Wanted: … Actual invocations
have different arguments"* — and the actual-invocation dump is long enough that the call you wanted
scrolls past. **The failure reads as "the production code never called this method" when it called it
correctly.**

Correct form — capture the array:

```java
ArgumentCaptor<Class<?>[]> captor = ArgumentCaptor.forClass(Class[].class);
verify(config).exposeIdsFor(captor.capture());
List<Class<?>> all = List.of(captor.getValue());   // getValue(), not getAllValues()
```

**Why:** measured 2026-09-21 at the SBDEV-3410 P2 TDD gate, against
`RestConfiguration.configureRepositoryRestConfiguration` → `config.exposeIdsFor(<57 types>)`. The
wrong form produced a red that pointed at the wrong subject entirely.

**How to apply:** whenever a gate test verifies a varargs call, use the array captor and
`getValue()`. And before believing a "was never called" verdict, grep the actual-invocation dump for
the method name — if it is in there, the matcher is wrong, not the code. Same family as
[[mockito-never-any-primitive-unboxing-trap]] and [[a-zero-scan-needs-a-positive-control]]: the
instrument fails in the direction that agrees with the hypothesis.
