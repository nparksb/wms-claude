---
name: annotation-census-by-grep-is-wrong-by-default
description: "Counting annotations or markers with grep fails in at least three distinct ways; use bytecode or an AST, and always reconcile against a second instrument"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e0db50f0-d3fb-4886-b7a5-0bbddec5af16
  modified: 2026-09-17T20:38:24.451Z
---

**Never report an annotation/marker population from a grep alone.** On SBDEV-3241/3242 (2026-09-06/07)
the same class of error produced three confident wrong answers in one ticket, each of which reached a
filed ticket, a commit message, or a peer before being caught:

1. **The pattern matched prose.** `grep "@Disabled.*SBDEV-2099"` counted a *comment* discussing the
   marker as a marker: 28 reported, 27 real. Fix: anchor the position —
   `grep -E ':[0-9]+:[[:space:]]*@Disabled'`.
2. **The anchor assumed a spelling.** `grep -E '^@Transactional'` missed
   `@org.springframework.transaction.annotation.Transactional("tenantTransactionManager")` — **five**
   classes, written fully qualified. This inverted a scope decision: I reported that almost nothing
   would exercise a base-class fix, when in fact 6 of 13 subclasses already override it.
3. **The report shape was misread.** Per-class surefire `Tests run: 0` from an *outer* report file
   looked like "class disabled"; the tests were in `$Nested` report files. I told a peer 38 assertions
   were dormant when they run and pass every build.
4. **The qualifier lives on the ADJACENT line.** (SBDEV-3398, 2026-09-17.) Grepping
   `OptimisticLockRetry` matched the field declaration on line 79 and *not* the `@Spy` on line 78. I
   read "field present, never stubbed" as "`@Mock`, so the lambda never runs" and published
   *"`scanPallet`'s state write has never executed in this 1400-line class"* to a ticket, a plan and
   the user. It is a **`@Spy`** — a real instance — so the lambda runs every time. **A grep hit tells
   you where a token is, never what it means: read the whole declaration, annotations included.**

**The same trip produced three more of these in one session**, which is why this is a family and not
bad luck: `git grep -c` reported 5 `findByIdForUpdate` in `BillofladingService` (it counts matching
**lines**; 3 were comments, the real count is 2, and 1 in `closeBOL`); a single
`findByIdForUpdate` token in `MobileTransferOrderService` was a **comment saying the code
deliberately does NOT use it**, and I published the inverted claim; and `generatePositionNumber` was
asserted to reach a `REQUIRES_NEW` sequence when it is pure `String.format`. Each was caught only by
an independent review lane, never by me re-reading my own work.

**The tell they share: I never opened the file.** Every one of the four would have been caught by
`sed -n 'N-3,N+3p'` on the hit.

**Why it keeps happening:** all three fail *silently and plausibly*, and twice the wrong answer pointed
at the conclusion I already expected. See [[a-zero-scan-needs-a-positive-control]] — a positive control
catches (1) and (3), but not (2), because the scan does return results, just not all of them.

**How to apply:** for anything annotation-shaped, prefer ArchUnit / `javap` / an AST — they read
bytecode and are immune to spelling and formatting. Where grep is the only option, match **both** the
simple and fully-qualified forms, anchor to the annotation's position rather than the line, and
reconcile the count against a second instrument before it leaves your hands. A number in a ticket is a
claim; `git grep` is not enough support for one. Related: [[failed-regex-resolution-must-not-become-a-verdict]],
[[claim-discipline-two-instruments]], [[grep-is-ugrep-skips-binary-without-dash-a]].
