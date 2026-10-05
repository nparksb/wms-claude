---
name: reused-container-accumulates-sequences-not-just-rows
description: "A reused Testcontainers postgres accumulates SEQUENCE values, which no row cleanup reclaims — a heavy review/mutation session pushes seqentities past 9000 and reds OrderReleaseSectionQueryIT for everyone"
metadata: 
  node_type: memory
  type: project
  originSessionId: fa3a1397-756c-4c22-a3bc-ca1190e2307b
  modified: 2026-09-22T22:48:02.791Z
---

Measured 2026-09-23 on SBDEV-3465. A full suite came back with 4 IT failures, all
`OrderReleaseSectionQueryIT`, all its own guard:

```
seqentities has climbed into the reserved fixed-id band (9001-9983) used by sibling ITs
Expecting actual: 10829L to be less than: 9000L
```

**Nothing about the change caused it.** `seqentities` is a global sequence in the shared
Testcontainers postgres, advanced by every insert any IT makes. The previous full suite on the
previous commit was `502 / 0 failures`, so the crossing happened between two runs of the *same*
branch — a window in which I ran the IT lane about a dozen times (4 mutants, 3 targeted runs, 3 full
suites). It stood at **11902** an hour later.

**The part that is easy to get wrong: a fixture that deletes every row it commits does NOT prevent
this.** `DELETE` never rolls a sequence back. So the careful cleanup that solves the *row* residue
problem (see [[wms2-concurrency-it-fixture-traps]]) buys nothing here, and a class can be a perfect
citizen on rows while still pushing the shared sequence past a band other tests reserve.

**Why it matters beyond one red:** the guard fires for **everyone** on that container afterwards, on
any branch, until someone resets it. It is a cross-session, cross-branch break produced by ordinary
review discipline — the more mutation rounds and full suites a ticket gets, the likelier it is.

**How to apply.**
- When a full suite reds **only** in `OrderReleaseSectionQueryIT` (or any fixed-id-band guard), read
  the assertion message before debugging anything: it names the cause and the remedy itself. Do not
  hunt it in your diff.
- The remedy is `docker rm -f` the container (or unset `testcontainers.reuse.enable`), then re-run.
- ⚠ **Check `pgrep -fl maven` first.** The container is shared across worktrees AND sessions;
  removing it mid-build hands a peer a wall of `Connection to localhost:PORT refused` that reads
  exactly like their own defect. That is the same hazard as
  [[concurrent-maven-one-worktree-false-reds]], from the causing end rather than the receiving end.
- Expect to pay this once per heavy ticket. Budget the container rebuild into the last full suite
  rather than discovering it when the run you needed to be clean is not.

Related: [[wms2-concurrency-it-fixture-traps]], [[concurrent-maven-one-worktree-false-reds]],
[[wms2-test-suite-baseline-and-h2-verdict]].
