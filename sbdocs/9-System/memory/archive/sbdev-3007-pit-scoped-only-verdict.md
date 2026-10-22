---
name: sbdev-3007-pit-scoped-only-verdict
description: SBDEV-3007 (adopt PIT mutation testing in wms2-api) re-scoped 2026-08-25 to scoped-only — its verify-script premise expired; the real driver is replacing the hand-rolled mutation harness that has lied 5 times
metadata: 
  node_type: memory
  type: project
  originSessionId: 78c04646-5d53-4cbe-b65e-a6164954b5d0
  modified: 2026-08-25T16:05:53.648Z
---

Re-evaluated 2026-08-25 against `origin/develop` @ `0d1e3e51` in a throwaway worktree. Ticket
description rewritten and the measurements posted as its first comment.

**Verdict: adopt, but scoped-only — ~15% of the filed scope, and for a different reason than filed.**

**The filed premise expired.** "Every plan ships a `verify-<plan-id>.sh`" stopped being true two days
after the ticket was written: `wms-triage` + `wms-plan-template.md` (2026-08-21) demote verify scripts
to T3-opt-in ≤15 rows, T0/T1/T2 ship none, and **no verify script has been written since 2026-08-22**.
Filed item 6 (rewrite the template's §Acceptance) was therefore already mostly done.

**The real driver.** The five-item floor mandates *"mutation-check every new assertion"* at every tier
including T0, and the tool used for it is a hand-rolled Python patch-and-recompile harness with five
measured false results across three sessions — see
[[mutation-harness-traps]] and [[mutation-harness-traps]].
PIT structurally cannot hit any of those modes: bytecode mutation in memory, no source write, no anchor
match, no recompile, no cross-lane race, and it names mutator + method + line.

**What was measured:**
- Scoped run works unchanged on today's develop — `DestinationEligibilityService` → **KILLED 29,
  NO_COVERAGE 1 in 12.2s** (`mvn -o test-compile` ~34s cold first). Reproduces the original 29/30.
- **83 of 86** top-level `*Service` classes have a matching `*Test` class, so scoped is broadly usable.
- Package-wide (`net.aim_ai.wms.service.*`) **fails in 1m39s** on PIT's green-suite requirement — see
  [[wms2-develop-preexisting-test-failures]], those two reds gate everything non-scoped.
- With them excluded: 136 mutation units, **4× `Minion exited abnormally due to TIMED_OUT`** in 8 min,
  unfinished at 10. No stable package-wide figure exists to set a threshold against.
- Filed items 2/3/4 (CI mode, threshold, package scope) are **undoable or premature** — chiefly because
  wms2-api runs zero tests in any CI lane, see
  [[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]].

**DONE 2026-08-25.** Pom block → **PR #197** (`feature/SBDEV-3007-pitest-plugin`, `c194a25c`), ticket
flipped to `pr submitted`. `wms-triage` floor item 3 now names the scoped PIT command as the default,
and `mutation-testing-recipe.md` records scoped-only as a hard constraint. Prerequisite for the two
baseline reds filed as **SBDEV-3089**.

**⚠ Trap found while landing it:** an XML comment documenting the block contained `--add-opens`, and
**XML forbids `--` inside a comment** — the pom stopped parsing and *every* Maven goal died with
`ModelParseException`, `mvn validate` included, which reads as a broken toolchain rather than a typo.
Write "add-opens" without the dashes in any pom prose. Caught only because verification ran `validate`
before trusting the edit; recorded as gotcha #4 in the recipe.
