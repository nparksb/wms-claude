---
ticket: SBDEV-3470
pr: SiteBossInc/wms2-api#406
commit: c96d3225a02d33f28d6b8943ad61636b906809cc (pushed; on origin/bugfix/SBDEV-3470-correct-truck-loading-fanout-figure; amends 0422d123)
parent: 7a71fba8
reviewer: independent code-reviewer lane (read-only; no tests run; `mvn -o -q test-compile` exit 0)
date: 2026-09-23
subject: fourth re-review. Covers only the M-A / L-A fixes from probe-race-rereview-3.md, and the commit message's R-1 bullet
---

# Re-review 4: SBDEV-3470, `c96d3225` versus `0422d123`

## (4) Scope: nothing else changed

- `c96d3225` and `0422d123` have the same parent, `7a71fba8`.
- `git diff 0422d123 c96d3225 --stat`: one file, `BlockedBackendReads.java`, 4+/4-. The only changed lines are the four lines of the `LEFT_WAIT_BEFORE_CONFIRMED` string literal. The javadoc, the SQL, and the three probe classes are unchanged.
- `mvn -o -q test-compile` exits 0.

**Result: clean.**

## (1) M-A and L-A, and the text in all three probes

New text:

> a backend was seen blocked by this test's holder, but on every sighting it was no longer blocked by it when re-read, so no blocked statement was ever confirmed. The poll does not check that the blocked backend was the worker; a stray waiter on the fixture rows would look the same

- **M-A is resolved.** The text no longer tells the reader to "check the worker's outcome", or to check anything else. It states what was observed and what the poll cannot tell apart. That holds for Closebol (`ClosebolLockOrderProbeIT.java:428`) and Mobile (`MobileTruckLoadingLockOrderProbeIT.java:433`), which throw the bare constant and print no worker outcome.
- **L-A is resolved.** "On every sighting it was no longer blocked by it when re-read" ties "it" to each sighting. It no longer implies one persistent backend. This is essentially the wording rereview-3 proposed.
- **Palletize** (`PalletizeLockOrderProbeIT.java:471-472`) appends `" " + workerOutcome(worker)`. I read the combined message for each of the four `workerOutcome` branches (`:494-507`):
  - "...would look the same  The worker has NOT finished — it is still running or still blocked elsewhere."
  - "...would look the same  The worker COMPLETED with no error, so it ran the whole of scanPallet without ever reaching the held row."
  - "...would look the same  The worker FAILED FIRST and this is very likely the real cause: <t>"
  - "...would look the same  The worker's outcome could not be read: <e>"

  None of these contradicts the constant. The constant names no cause and warns that the sighted backend may not be the worker. `workerOutcome` then adds observed evidence about the worker, which is exactly the complement the constant leaves open. The "COMPLETED ... without ever reaching the held row" branch is consistent with the stray-waiter case the constant names. The javadoc's "a worker timing out is an unlikely explanation" is a prior, and "FAILED FIRST ... very likely the real cause" is an observation, so they do not conflict.
  - Cosmetic, pre-existing, not blocking: the constant has no closing period, and every `workerOutcome` string starts with a space while the call site adds another. The joined message therefore reads "look the same  The worker ..." (a double space and no sentence break). It reads fine and is not misleading. Neither this commit nor 0422d123 introduced it.

## (2) The javadoc still matches

`BlockedBackendReads.java:15-22`:
- "was no longer blocked by it at `confirmedBlockedStatement`'s re-read, on every sighting until the deadline" matches the text's "on every sighting ... when re-read".
- "It deliberately names no cause: the poll does not check that the blocked backend is the worker" matches the text, which names no cause and states the same caveat.
- The javadoc never mentioned the removed "check the worker's outcome" clause, so nothing in it went stale.

**Result: accurate.**

## (3) The commit message's R-1 bullet: WRONG VERSION NAMED

The text went through these versions (checked with `git grep` on each commit):

| Commit | Text | Defect |
|---|---|---|
| `7a71fba8` (original, per probe) | "...most likely on lock_timeout. Check the worker's outcome, not the fixture" | R-1: points at output that no probe printed on that path |
| `1a14be66` (1st rewrite, now the shared constant) | "...most likely because the worker hit lock_timeout. The fixture reached the held row; the worker, not the fixture, is what failed" | M-1 (rereview-2): overclaims the cause |
| `0422d123` (2nd rewrite) | "...The poll does not check that this backend was the worker ..., so check the worker's outcome and any other session touching the fixture rows" | M-A (rereview-3): still says "check the worker's outcome" |
| `c96d3225` (final) | as quoted in (1) | none |

The bullet says:

> ...no longer points the reader at output that two of the three probes do not print (a third review, M-A, caught that **the first rewrite** still did). A second review of this round (M-1) caught that **the first replacement text** ("most likely because the worker hit lock_timeout ... ") was an overclaim...

- "The first replacement text" correctly identifies `1a14be66`. The quote matches.
- **"The first rewrite" is wrong.** M-A was raised against `0422d123`, which is the **second** rewrite. `1a14be66` did not say "check the worker's outcome". Its defect was the overclaim, M-1.
- The wording is also confusing. "The first rewrite" and "the first replacement text" read as synonyms, but the bullet gives them different defects. It also tells the history out of order: it mentions M-A before M-1.

- **[MEDIUM] M-B: the R-1 bullet in `c96d3225`'s message attributes M-A to the wrong version**
  - **Confidence:** HIGH
  - **Fix:** the commit is pushed, so correct it in the PR #406 description. Suggested replacement for the R-1 bullet:

    > - R-1: the "left the wait before it could be confirmed" timeout (7a71fba8) blamed lock_timeout and told the reader to check the worker's outcome, which no probe reported on that path. The first rewrite (1a14be66) overclaimed instead: "most likely because the worker hit lock_timeout ... the worker, not the fixture, is what failed". A second review (M-1) caught that the poll never checks that the blocked backend is the worker, and that with a 10 s lock timeout against a 100 ms poll a worker timeout is the unlikely explanation. The second rewrite (0422d123) named no cause but still said "check the worker's outcome", which Closebol and Mobile do not print; a third review (M-A) caught that. The final text (c96d3225) states only what was observed and names no cause. Palletize appends workerOutcome(worker), as its sibling message does.

  - Note: the SHAs `1a14be66` and `0422d123` were never pushed. They are unreachable from the remote, so readers cannot look them up. If that matters, drop the SHAs and keep "first rewrite" / "second rewrite".

The rest of the message is unchanged from 0422d123 and was verified accurate in rereview-3: R-2 through R-7, "Test-only", and the Palletize `workerOutcome` claim.

## Findings

| ID | Severity | Confidence | Where | Status |
|---|---|---|---|---|
| M-A | MEDIUM | HIGH | `BlockedBackendReads.java:23-27` | Resolved |
| L-A | LOW | MEDIUM | `BlockedBackendReads.java:24-25` | Resolved |
| M-B | MEDIUM | HIGH | `c96d3225` commit message, R-1 bullet | Open. Fix in the PR description (wording above) |

The code itself (the constant, its javadoc, and all three call sites) is accurate and needs no further change. The only open item is the commit message's history note, and it can only be fixed in the PR description, not in the code.

## Positive observations

- The final text is the minimal correct statement: observation plus the one caveat, with no instruction that any probe could fail to back up.
- The amend touched exactly the four string lines. No collateral edits.

Verdict scope: the change needed is to the PR description wording only. No code change is needed.

CHANGES REQUESTED
