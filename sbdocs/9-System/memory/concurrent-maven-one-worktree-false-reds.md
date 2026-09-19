---
name: concurrent-maven-one-worktree-false-reds
description: Two Maven runs in one worktree produce a wall of credible reds; one clean run of the same tree is 0/0
metadata:
  type: reference
---

**Never run two Maven invocations in the same worktree at once, and never grade a suite that shared
its `target/` with another build.**

Measured 2026-09-01 on SBDEV-3169: a backgrounded `mvn clean test` racing a PIT run and a foreground
`mvn test -Dtest=...` in the same worktree reported **21 failures / 238 errors**. The identical tree,
run alone, reported **0 failures / 0 errors**. `clean` deletes `target/` out from under the others, so
the failures are plausible-looking classloading and missing-class errors spread across unrelated
packages — indistinguishable from a real regression.

**How to keep parallelism:** give each lane its own worktree
(`git worktree add --detach <path> <sha>`), which is the same rule as
[[review-lanes-must-not-share-a-worktree]] applied to build lanes rather than agents. `~/.m2` is
shared and safe; only `target/` is contended.

**Why it matters beyond the wasted run:** this is a false-RED generator, so the failure mode is
distrusting correct work — the mirror of [[verify-script-traps]]. If a suite result surprises you,
check what else was running before you debug the code.

## The commonest way to cause it by accident (added 2026-09-07, SBDEV-3195)

**A `&`-backgrounded subshell inside a Bash tool call does NOT die when the call returns — the `mvn`
child keeps running, detached, for the rest of the session.** I launched
`( mvn clean verify > log; touch done ) &`, saw the tool return, saw no `done` sentinel and a log that
stopped mid-stream, and concluded *"the background process was killed"*. It was not. It ran for another
six minutes while I started a second `mvn clean verify` in the same worktree.

So the inference **"no sentinel file + truncated log ⇒ the run died"** is wrong, and it is dangerous
precisely because it invites you to relaunch. **Check `ps` before relaunching, never the log.**
Use the harness's own `run_in_background`, which tracks the process and notifies on real exit; if you
must use `&`, `wait` on it or record `$!` so you can actually kill it.

**Detection signature, when you have already done it:** the same `target/surefire-reports/*.xml`
tallied **twice a minute apart gave 3 errors, then 0**. A result that changes while nothing changed is
a contended `target/`, full stop. The reds themselves read as real — `NoClassDefFound
net/aim_ai/wms/landlord/config/IdempotencyFilter$1` (an inner class, deleted mid-read), `[projection
package must be on the classpath]`, and one `ApplicationContext failure threshold (1) exceeded`.
Anonymous/inner-class `NoClassDefFound` plus "not on the classpath" in unrelated packages is close to
diagnostic.

**`ps` is also how you avoid killing someone else's build:** filter the kill list by worktree path
(`ps -eo pid,args | grep SBDEV-XXXX`) — a sibling session had its own `mvn` running in a *different*
worktree at the same time, which was harmless and had to be left alone.
