---
name: negative-test-verify-scripts-before-trusting-them
description: "A verify-script `Result: N pass, 0 fail` is meaningless until you've shown it FAILS on the broken version — replay the pre-fix file and confirm a non-zero fail count."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b569dc6d-2bf6-4ec2-b56e-388516b2932c
  modified: 2026-08-11T19:14:22.823Z
---

Before quoting a `verify-SBDEV-XXXX.sh` score as evidence, **prove the script can fail**:

```bash
cp src/.../Foo.java /tmp/foo.current
git show <pre-fix-sha>:src/.../Foo.java > src/.../Foo.java
bash sbdocs/9-System/scripts/verify-SBDEV-XXXX.sh | grep -E 'FAIL|Result:'   # expect FAILs
cp /tmp/foo.current src/.../Foo.java                                          # RESTORE
```

**Why:** on SBDEV-2736 the script reported `57 pass, 0 fail` on an implementation that classified live
partial failures as ACCEPTED — the exact defect the ticket existed to catch. It scored **identically** on
the buggy and the fixed build, because no check named the new behaviour. Two review passes were needed to
notice, and the same pattern had already appeared in r1 (a unit test and a verify check that *pinned the
bug as intended behaviour*). A green gate authored alongside the fix tends to encode what the fix happens
to do, not what it must do.

**How to apply:**
- After adding a fix, add the check that would have caught its absence, then replay the pre-fix file and
  confirm the count drops. Record both numbers in the plan (`70/0 fixed, 65/5 on <sha>`).
- Watch for proxy checks that measure the wrong thing: `grep -c '@Test'` misses `@ParameterizedTest`;
  escaped-JSON regexes rarely match real Java string literals. A check that *cannot* fail is worse than a
  missing one — it reads as coverage.
- Same discipline for unit tests: `@InjectMocks` silently injects **null** for a newly added constructor
  arg, so a `try/catch` around the new code makes the whole feature a no-op while tests stay green. If a
  new dependency is added, assert it was actually exercised.

- **Mutate by INFIX, never by suffix.** Negative-testing a grep row by renaming `getUseforgoodsin` →
  `getUseforgoodsinXX` leaves the pattern matching as a **substring**, so the row passes and you conclude
  it asserts nothing. `getUseforXXgoodsin` is the only form that breaks it. On SBDEV-2732 this produced a
  clean sweep of ten false "ASSERTS NOTHING" verdicts in a row — a uniform result across every row is the
  tell that the harness, not the script, is broken.
- **Read the FAIL rows, never just the `Result:` line.** Also on SBDEV-2732, `PHASE=1 220 pass, 6 fail` was
  reported as `220 pass / 0 fail` because the six were assumed to be the `U-*` UI rows — which that very
  phase filter *excludes*. If you can't name each failing row, you don't have a verdict.

Related: [[verify-script-traps]],
[[feedback_plan_status_after_implementation]],
[[wms2-outbox-dispatcher-status-blind-silent-loss]], [[wms2-develop-preexisting-test-failures]].
