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

## ⚠ CORRECTION (2026-09-22, SBDEV-3418): a different worktree is NOT harmless

The last line above said a sibling session's `mvn` in a *different* worktree "was harmless and had to
be left alone." **That is wrong when the ITs run.** `~/.testcontainers.properties` sets
`testcontainers.reuse.enable=true`, so every worktree's failsafe lane binds to the **same reusable
`postgres:14-alpine` container**. `target/` isolation buys nothing there — the database is global.

**Measured:** a full `clean verify` on SBDEV-3418 reported **5 IT failures** while a peer session ran
its own suite in `SBDEV-3410-p5-suite`. The same tree, run alone, was clean. Signatures, in the order
they mislead you:

- `FATAL: sorry, too many clients already` — the root cause. Two suites exceed `max_connections`.
- **`Failed to load ApplicationContext`** on three unrelated IT classes — this is the *downstream*
  effect of a context that cannot get a connection at startup, and it reads exactly like a DI defect
  in whatever you just changed. It names your build, not the peer's.
- `duplicate key value violates unique constraint` on a fixture prefix owned by the failing class
  itself (`PARCELMON-ORD-1`) — leftover committed rows, because the peer's run killed the container
  mid-cleanup.

**The peer may also delete your container out from under you.** That session's command began
`docker ps -aq --filter "label=org.testcontainers=true" | xargs -r docker rm -f` — a *global* force-remove,
not scoped to its own worktree. So "I removed the stale container to get a clean run" is not a fix;
either party can do it to the other at any moment.

**Detection, before debugging anything:** `pgrep -fl "maven|surefire|failsafe"`. The full command line
shows the peer's worktree path. ⚠ `pgrep -f SBDEV-3418` substring-matches `SBDEV-3418-run` and
`-verify` too, so read the paths rather than trusting a count.

**What to do:** queue rather than race —
`while kill -0 <peer-pid> 2>/dev/null; do sleep 30; done` then start, and let it settle ~60s so the
peer's Ryuk finishes reaping. Unit-only lanes (`mvn test`) stay safely parallel across worktrees; it
is only `verify` that contends. See [[wms2-concurrency-it-fixture-traps]] and
[[outbox-concurrent-enqueue-it-is-timing-flaky]] for the failures that look identical but are real.
