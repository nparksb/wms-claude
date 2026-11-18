---
lane: code-reviewer round 3 (code e60a10c4..1114fa26 + sbdocs pending-merge text); saved by main session 2026-11-06
verdict: APPROVE (0 High, 0 Medium; code 3 Low, docs 4 Low, 1 open question)
---

# Round-2 fixes
L-1, L-2, L-3 (deletion correct; dependency gone), L-4 (2 lines), Q-1 and the conformance gap all landed.
The re-check is a plain projection after lockById(L′) and before the order locks, so it adds no lock edge.
The arch bump 2→3 is justified (anyBoolean on a primitive `ignoreLock`).
Run on a git-archive copy, JDK 21: 4 classes, 341 tests, 0 failures.

# Reviewer mutation probes (all killed)
- M1: re-check above lockById
- M2: UL check hoisted
- M3: FLA check hoisted
- M4: early check removed
- M5: stale branch aligns anyway (`expected null but was 55L`)

# Code findings
| ID | Sev | Site | Fix |
|---|---|---|---|
| A-1 | Low/HIGH | ReplenishOrderJob ~:759 `LOG.warn("end   working on fixedLocationAssignmentId={} lock conflict occurred: ", ..., e)` still logs the full throwable (a catch this ticket added) | Log the class at WARN, the throwable at DEBUG |
| A-2 | Low/MED | move re-check comment names the multi-UL confirm as the racing writer | The confirm cannot target L′ (it refuses "wrong location!"). The writer that can race is an operator create (C5/C6), which takes neither F nor L′. The re-check narrows the window; it does not serialise. Reword. |
| A-3 | Low/HIGH | move javadoc says "the two destination checks" under L′ | It is now three (FLA, UL, order already at L′) |

# Doc findings
| ID | Sev | Site | Fix |
|---|---|---|---|
| B-1 | Low/HIGH | osiv map §8.5: "a waiter whose FLA was deleted/moved gets empty" | Only C0 (keyed on location) sees a moved FLA as empty; the id- and item-keyed locks see the moved row |
| B-2 | Low/HIGH | design delete(Long) row: "gone/moved under the lock → skip" | Gone → "Can't find fix assignment" BusinessException, which the cron logs before continuing. A moved FLA is re-judged at its new location. |
| B-3 | Low/HIGH | design repo row: "single lock object for every destination decision" | Overstated. Operator creates and the multi-UL confirm take no FLA lock. Scope it to decisions made *from a FLA*. |
| B-4 | Low/HIGH | design move bullet | FLA/UL checks run once under L′; only "order targeting L′" is re-checked. It locks all open orders (<FINISHED) to the old location, refuses if one is past PROCESSABLE, and re-points the rest. |

Nit: the osiv log row names only "10 s"; the body also corrected a "5 s" figure.

# Completeness check
"No path locks the FLA after an order" verified TRUE: 6 locker call sites enumerated by grep, plus a second grep showing no native FOR UPDATE on the FLA table.

# Disposition
Fix all (A-1..A-3 in code, B-1..B-4 + the nit in docs).
