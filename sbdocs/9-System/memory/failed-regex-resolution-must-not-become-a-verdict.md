---
name: failed-regex-resolution-must-not-become-a-verdict
description: A regex that returns None silently collapsed into a wrong bucket and produced two false verdicts
metadata:
  type: feedback
---

Measured twice in one session (2026-08-29, SBDEV-3136 Phase 2). I classified test sites with
`mock_type = <regex> or None`, then wrote `wired = bool(mock_type and re.search(...))`. When the type
regex missed, `mock_type` was `None`, both downstream probes short-circuited to `False`, and the site
landed in the **NOISE** bucket — the most destructive verdict available, meaning "delete this test
assertion". `CycleCountControllerUnitTest` was called noise that way; it is a live guard with passing
positive assertions. The regex missed only because the mock was declared bare (`private FooService
fileExportService;`) and assigned separately (`fileExportService = mock(FooService.class);`).

**Why:** an unresolved input is not a negative result, but `and`-chaining makes it look like one.
The failure is silent and reads exactly like a confident finding.

**How to apply:** give "could not resolve" its own bucket and print it — never let it fall through to
a substantive verdict. Assert the resolution rate up front (`unresolved: N`) and treat a non-zero N as
a blocker for any completeness claim, not a footnote. And when a classifier's verdict would cause
deletion, hand-verify before publishing — mine was wrong twice before review caught it.

Related: [[never-audit-check-a-does-not-find-vacuity]], [[advertised-capability-is-not-exploitable]].
