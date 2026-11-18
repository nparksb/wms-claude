---
name: hub-evidence-discipline
description: Measured ways a claim, count, enumeration or review verdict was wrong, and the method that fixed it. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Evidence & claim discipline (how a claim/count/review goes wrong)**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [Negative-test verify scripts](negative-test-verify-scripts-before-trusting-them.md) — must FAIL on pre-fix file
- [Verify-script traps: every way a row lies](verify-script-traps.md) — false GREENs and false REDs; always prefer a JUnit/Jest test to a row
- [Advertised capability ≠ exploitable](advertised-capability-is-not-exploitable-capability.md) — test the write; OPTIONS Allow proves nothing
- [Retitling a section leaves the rule asserted below it](retitling-a-section-leaves-the-rule-asserted-below-it.md) — grep the RULE, never the section
- [AC-2′: count USERS, not roles](ac2-role-count-is-not-the-unit-user-population-is.md) — 1-role constant = 38 users; 2 of 3 role-name verdicts wrong,
- [A guard fences the mechanism you aimed at](a-guard-fences-the-mechanism-you-aimed-at.md) — enumerate every producer of the outcome; 3 mechanisms,
- [Derive cross-repo claims from origin/develop](derive-cross-repo-claims-from-origin-develop.md) — checkouts lag unmeasured (mobile-ui now 77); a `find` miss is a FALSE ABSENCE that licenses deleting a correct claim
- [A failed regex must not become a verdict](failed-regex-resolution-must-not-become-a-verdict.md) — None short-circuited into the DELETE bucket,
- [Absence of a path ≠ absence of the guarantee](absence-of-a-path-is-not-absence-of-the-guarantee.md) — renames defeat ref sweeps; SBDEV-3156 nearly re-landed a withdrawn, weaker test
- [Auditing ticket status against git](ticket-status-vs-git-audit-method.md) — body-grep false-positives, branches with no ticket ID, and "a merge exists" ≠ scope shipped
- [Annotation census by grep is wrong by default](annotation-census-by-grep-is-wrong-by-default.md) — use javap/ArchUnit, match FQN, reconcile with a 2nd instrument
- [Prose enumerations rot — state the rule](prose-enumerations-rot-state-the-rule.md) — 4 incomplete lists on one ticket; derive with a script, pin with a rail
- [Fixing a false claim tends to produce a new one](fixing-a-false-claim-tends-to-produce-a-new-one.md) — 6 rounds; it's SIBLING COPIES (PR body + comments); a token grep isn't a sweep
- [A control on a literal can't detect a narrowed pattern](a-control-on-a-literal-cannot-detect-a-narrowed-pattern.md) — 0-across-0 with every control green; assert at the REPORTING stage
- [Burned sequence numbers prove a code path ran](burned-sequence-numbers-prove-a-code-path-ran.md) — REQUIRES_NEW counter commits alone; gaps date the regression
- [Enhancement paths must fail open on missing config](enhancement-paths-must-fail-open-on-missing-config.md) — a guard copied from an action-selecting switch is wrong on a yes/no question; 3x in one ticket
- [A test can pass for the wrong reason](a-test-can-pass-for-the-wrong-reason-vary-the-fixture.md) — 2 routes to the same outcome; shrink the fixture so the guard is the only one
- [Census the predicate, not the symptom](blast-radius-is-the-predicate-not-the-symptom.md) — symptom-shaped filters miss the orders that work today
- [Review lanes skip prerequisite tables](review-lanes-under-audit-prerequisite-tables.md) — a false claim survived 3 revisions + 2 lanes in §5.1; measure env claims, never reason them
- [Verify a contract against the wire](verify-a-contract-against-the-wire-not-the-comment.md) — a comment describing what a CALLER sends is a claim, not docs; cost a reversed decision
- [A broad guard before a narrower one shadows it](broader-guard-before-narrower-one-shadows-its-diagnosis.md) — 96/114 cases lost the specific diagnosis; tests stayed green, both throw
- [Derive the bound constant from the call site](derive-the-bound-constant-from-the-call-site.md) — a ticket's literal matched 0 rows; the filter was inert and the clean number agreed with me
- [Review rounds leave their own fix commits unreviewed](review-rounds-leave-their-own-fix-commits-unreviewed.md) — fix commits AND the PR body/commit msg/ticket text ship unreviewed; gate the push on a pass over both
- [Exposure counts must filter to the path's precondition](population-query-must-filter-to-the-paths-precondition.md) — SBDEV-3470 "~142 locks" was inbound pallets scanGate rejects; real max 28
- [is-ancestor ≠ fix shipped](is-ancestor-does-not-prove-a-fix-shipped.md) — revert-on-release; git grep at deployed sha
