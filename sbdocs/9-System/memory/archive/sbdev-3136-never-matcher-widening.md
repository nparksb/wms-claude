---
name: sbdev-3136-never-matcher-widening
description: PR #230 widened 240 reference sites; 0 currently disarmed but 1 proven disarmed against a guard reversion; 194 boxed sites left
metadata:
  type: project
---

**SBDEV-3136** (wms2-api, test-only). PR **#230** → develop, commit `035e9392`, base `2358e66d`.
Status `pr submitted` as of 2026-08-28. Widened **398 reference-typed matchers / 276 `never()`
sites / 72 files**. Decomposition: **240 `[B]` + 36 `[A]`** (matcher width and target
reachability are orthogonal, so `[A]` sites were folded in; it cannot prejudge their Phase-2
delete/retarget/keep triage). Suite 5690/0/0/67, identical to base.

**The number that decided the scope: 0 disarmed out of 328** against the *current* code — i.e.
widening exposed no guard that is broken today. That killed the ticket's proposed 64-class
per-site-mutant programme. **But "just hygiene" was too weak a framing:** one mutation proved a
real disarm. `OmsNotificationService.sendAfterCommit` returns early when `urlPath` is null;
delete that `return;` and a null URL reaches `httpRestService.post` — with the original
`anyString(), anyString()` the suite is **11/11 GREEN**, with `any(), any()` it is **RED**
(`NeverWantedButInvoked`). So the value is **prospective**, and one demonstration covers the
whole class of change.

**Remaining: 194 `[B?]` sites** (boxed-vs-primitive, needs signature resolution — see
[[mockito-never-any-primitive-unboxing-trap]]) and the **36 `[A]` sites** enumerated on the
ticket as the Phase-2 worklist (line numbers are against `2358e66d` and shifted by this PR —
regenerate).

**`never-audit.py` had FOUR defects, all now fixed** (tooling → fixed directly, never filed).
Two were pre-existing; two I introduced/found this session: it advised widening primitive
matchers, and it scanned **per-line**, so a `never()` whose `.method(` wrapped onto the next
line was invisible to *every* check — **28 of 824 sites**, and the old "796" denominator was
itself that blind count. Now whole-text with paren-balanced spans. Two shapes remain blind by
design and are documented in its docstring: fully-qualified `org.mockito.Mockito.never()` and
`MockedStatic.verify(lambda, never())`.

⚠️ Every count posted on this ticket before the scan fix is LOW. Authoritative on `2358e66d`:
`[B]` 240 · `[B?]` 194 · `[A]` 95.
