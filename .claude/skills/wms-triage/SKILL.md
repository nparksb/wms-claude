---
name: wms-triage
description: FIRST STEP for every WMS task, before wms-bugfix-plan / wms-feature-plan / wms-v2-migrate / wms-tdd-gate / wms-plan-executor. Run it on a stack trace, an HTTP 500, an SBDEV ticket, a stuck workflow, a feature or refactor request, a v1->v2 port, or an investigation — including anything that looks like a one-liner. Answers: is it already fixed on origin/develop? does it reproduce? is the reported cause the real cause? is it one line? — then assigns an effort tier T0-T3 on execution risk. Single source of truth for the tier router, the five-item floor that never scales, the ticket-filing policy, and verify-script row hygiene; every other WMS skill defers here. Output is a five-line triage block on the ticket, never a file.
---

# WMS Triage & Tier Router

**Single source of truth** for: how much process a WMS task gets, what never scales, and when a finding becomes a ticket. `wms-bugfix-plan`, `wms-feature-plan`, `wms-tdd-gate`, `wms-plan-executor`, `wms-investigation-report`, `wms-v2-migrate`, `wms-architecture-doc` and `wms-design-doc` all defer here. This file is authoritative: where a sibling restates a rule (the executor's per-tier phase table, the feature skill's tier modifiers) it must agree with this one — change the rule **here** first, then reconcile the restatement.

Run this before choosing any other skill. Two of the four probe questions routinely end the task outright, which is the intended outcome.

**Scope — what applies to what.** For a **change to product code** (bug fix · feature · refactor · v1→v2 port), everything below applies: probe, tier router, floor, ticket policy. For a **doc, report, or architecture/design task**, the router does not apply — there is no fix to tier, and the probe's four questions do not parse. What still binds is the floor's evidence discipline (ground every non-obvious claim in a `file:line` or a DB query; one independent review pass) and the ticket policy for defects the work surfaces. Say which of the two you are in before proceeding.

## Phase 0 — TRIAGE PROBE (20 minutes, before the tier router)

**Run this before classifying anything. Its job is to make the heavy planning skills unnecessary.**

Measured on this backlog: a meaningful share of tickets do not need a plan at all — they are already
fixed, already on prod, one line, or a defect in a *different* place than the ticket says. Every one of
those consumed a full planning pass before anyone noticed. Four questions, in order, and **stop at the
first one that resolves the ticket**:

| # | Question | How to answer it — cheaply |
|---|---|---|
| 1 | **Is it already fixed?** | `git -C <repo> fetch` then look at `origin/develop`. Do **not** trust a local checkout — measured: four checkouts up to 13 commits behind, which turned a fully-shipped fix into a wall of honest-looking reds. Also check the ClickUp status of every ticket the description names |
| 2 | **Does it reproduce?** | one DB query or one API call against DEV. If it does not reproduce, say so and stop — the ticket needs a reporter conversation, not a plan |
| 3 | **Is the reported cause the real cause?** | the symptom is often a different defect. On SBDEV-1615 the reported "no warning" was a scalar-subquery crash in the guard that *should* have warned — found in 30 minutes, no plan, one-word fix |
| 4 | **Is it one line?** | if the fix is one line and reversible, it is **T0/T1**. Write the failing test, fix it, done. Do not open a document |

**Output: five lines as a ticket comment. Never a file.**

```
TRIAGE <TICKET>
  reproduces:     yes / no / not-checked-because-<reason>
  already fixed:  no / yes -> <commit or ticket>
  real cause:     <file:line>  (or: as reported / unknown, needs investigation)
  tier:           T0 / T1 / T2 / T3
  needs a plan:   no / yes -> <the one thing a plan buys that bullets do not>
```

**If "needs a plan" is `no`, stop here — do not invoke `wms-bugfix-plan` or `wms-feature-plan`.**
Hand off to the floor (below) and implement. That is the intended outcome, not a failure to engage.

**If the probe cannot answer question 1 or 2**, say which and why, and treat the tier as one higher —
an unreproducible defect is not a T1.

---

## Tier router — RUN THIS FIRST, before anything else

**Why this exists.** Every skip condition in the WMS plan skills used to be a variant of *"is it a one-liner?"* — a cliff, not a gradient. Anything non-trivial fell into the full lane. Measured on SBDEV-3011: a fix with **under 100 lines of real logic** produced a **1142-line plan**, a 483-line verify script and **10 subagent passes**, and then generated its own maintenance (several rounds of correcting over-specified counts and citations that only existed because the document was detailed enough to be wrong about). Meanwhile **every actual defect** was found by something cheap — one `pg_constraint` query, one `count(*)`, mutation-testing the new assertions, and a single independent review. **Scale the artifacts. Never scale the floor.**

Answer three questions. They take a minute and they route on *execution risk*, not on ClickUp priority (which tracks business urgency, a different axis):

1. **Reversible?** Can a bad merge be undone by a revert — or does it write/destroy data, change a published contract, or run a migration?
2. **Is the fix predictable from the symptom** — or must you first investigate *why*?
3. **How many files / repos?**

| | **T0 Trivial** | **T1 Contained** | **T2 Standard** | **T3 Full** |
|---|---|---|---|---|
| Shape | one-liner, mechanical: typo, constant, log string, missing null check, `.get()` → `.orElseThrow()` | one file, fix obvious from the symptom, reversible | multi-file, or a contract/error-shape change, still predictable | authorization · data integrity · Flyway migration · multi-repo · irreversible · root cause genuinely unknown |
| Ticket | required for **product** work at every tier — but a defect in tooling, templates or skills gets **no ticket at all**, it gets fixed directly (see *Where each kind of finding goes*) | ← | ← | ← |
| DB verification | **required** | **required** | **required** | **required** |
| Pre-draft questions | no | only if a user-visible contract changes | yes | yes |
| Pre-investigation agents | no | no | one `architect` **consult** (a single question, not a loop) | `tracer` and/or `architect` |
| Plan artifact | **none** — a 2-line note on the ticket | **3 bullets on the ticket**: root cause (file:line), the change, how it is proven | **bullets on the ticket + a design note ONLY if a user-visible contract changes.** A *document* at T2 needs Nam's explicit yes — measured, 85% of archived v2 plans blew the old ≤200-line cap, and SBDEV-3003 Slice 2 overrode the cap inside the very document the cap governed | full doc, all sections |
| ralplan consensus | no | no | **no** — the architect consult replaces it | **one** round; a second only if the Critic returns a **High** |
| Verify script | none | none | **none** — put the assertions in JUnit/Jest, which run in CI and survive refactors | **opt-in, ≤15 rows.** See *Row hygiene* below before writing one |
| TDD gate | inline: write the failing test yourself | inline | run the gate | run the gate |
| Review lanes | 1 (`code-reviewer`) | 1 | 2 (+ `security-reviewer` **only** if it touches authz/SQL/secrets) | 4 (conformance · review · security · re-review) |
| Budget | 15 min | ~1 hr | ~½ day | open-ended |

**When in doubt, go one tier DOWN and rely on the escalation triggers below.** Over-tiering is the failure mode this router exists to fix; under-tiering self-corrects in ten minutes.

State the tier and the deciding factor in your first message, so the user can override before any effort is spent.

### Escalate mid-flight — do not try to pre-classify perfectly

Any ONE of these bumps the ticket up a tier, immediately, wherever you are:

1. **The DB query contradicts the ticket.** (SBDEV-3011: the ticket said "deleting an assigned role fails"; the query said `roles_deletable_today = 0` — *every* role. That is a severity reframe, not a detail.)
2. **The fix needs a new repository method, service method, or projection** you had not anticipated. A new persistence surface means the blast radius was mis-estimated.
3. **A review finding disputes the design**, not the code.

Say which trigger fired and re-state the new tier. Escalation is cheap; discovering at PR time that a T1 was really a T3 is not.

## Row hygiene — read before writing a single verify row

**Verify scripts have been a net-negative layer in this repo.** The evidence, all measured:

- On SBDEV-3003 Slice 2, **12 of 16 deliberately-broken implementations scored a FULL GREEN** against
  the original rows. The row layer needed its own adversarial review lane, and three more row defects
  were still found while implementing.
- **51** scripts inherited a `file_not_contains` that returned PASS for a file that does not exist, and
  **38** inherited an `mvn` row that could never go green. Fixed 2026-08-21; the template now has a
  mutation-checked guard test at `sbdocs/9-System/templates/test-verify-plan-template-helpers.sh`.
- **12 of 52** active scripts had roots pointing at a laptop that no longer exists, so their negative
  rows passed silently for months.

So: **prefer a JUnit/Jest test to a row, every time.** A test runs in CI, survives a refactor, and can
be mutation-checked. Write a row only for something a test genuinely cannot see — a cross-file or
cross-repo invariant such as *"no call site anywhere passes an entity"*.

If you do write rows, these five rules come from rows that lied:

1. **Assert behaviour, never implementation shape.** Measured today: a row demanding
   `int finalizeBatchesByIds(` failed because the real method returns `void` — the work was done and
   three sibling rows proved it. Another demanded a `chunked()` helper; the implementation inlined the
   chunking with a `chunk` variable. Both rows were red against correct code. **Never assert a return
   type, a helper's name, or which file a symbol lives in.**
2. **Every negative row must fail closed.** `! grep` on a missing file is a PASS. Guard with
   `[ -f "$2" ] || return 1`. Same for any `perl -0777` helper — perl exits **0** when it cannot open
   the file. `grep`- and `tr`-based helpers fail closed naturally and need no guard.
3. **Never grade a local checkout.** Run against a detached worktree at `origin/develop`, or you will
   get a wall of credible reds that means only "stale tree".
4. **A row that is green must be shown to go red.** Replay the pre-fix file, or the row proves nothing.
   A `Result: N pass, 0 fail` line is not evidence until you have seen it fail.
5. **A permanently-red row is worse than no row**, because it is indistinguishable from unfinished
   work. If a row cannot go green against correct code, delete it.

---

## The floor — applies at EVERY tier, including T0

These are the five cheapest things in the whole process and they are where the defects actually come from. Roughly 20 minutes total. **Nothing here is ever skipped, traded, or deferred — not for a one-liner, not for a hotfix.**

1. **One DB query confirming the symptom** before writing anything. Record it and its result. If the MCP is unavailable, say so explicitly and name the query the implementer must run.
2. **One failing test before the fix**, and it must fail for the *right* reason — an assertion, not a compile error or an NPE in setup.
3. **Mutation-check every new assertion.** Break the thing it protects; confirm the test goes red; restore. An assertion never observed failing is not evidence. This single habit found **five** defects on SBDEV-3011 that four review lanes and two consensus rounds had missed, including a regression pin that passed while the fix it guarded was deleted wholesale.

   **Use PIT, not a hand-rolled harness** (`wms2-api` only; landed on develop 2026-08-25):

   ```bash
   export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"
   cd <worktree> && mvn -o test-compile -q
   mvn -o org.pitest:pitest-maven:mutationCoverage \
     -DtargetClasses=net.aim_ai.wms.service.YourService \
     -DtargetTests='net.aim_ai.wms.unit.service.YourServiceUnitTest'
   ```

   Read the survivors — the actionable half — with the XML snippet in
   `sbdocs/9-System/mutation-testing-recipe.md`. Roughly 12s scoped to one class after a
   ~35s cold `test-compile`. A `SURVIVED` line is an assertion gap; `NO_COVERAGE` may just
   be unreachable code, and PIT distinguishing the two is the point.

   **Always scope it to the class you changed.** Not because of a red baseline any more —
   **SBDEV-3089 cleared both develop reds on 2026-08-26** (`OptionalSafetyArchTest`,
   `MobilePalletizingServiceTest`), so develop now runs at **0 failures** and a wider run does
   clear PIT's green-suite abort. ⚠ Do not hardcode the test COUNT from any doc — it moves with
   every merge (5620 at the clearing, 5635 after SBDEV-3103). Measure the baseline fresh and
   compare failures, not totals. Scope it because wider runs are still slow and
   hit `Minion exited abnormally due to TIMED_OUT` — that half is unchanged and is SBDEV-3007's
   problem, not yours. **Do not treat a red full suite as expected.** If `mvn test` shows any
   failure, that is now a signal, not the baseline — which is the whole point of having cleared it.

   **Why the tool and not a script:** hand-rolled patch-and-recompile harnesses produced
   *measured false results at least five times across three sessions* — an mtime-preserving
   restore let mutant bytecode leak into a fabricated 17/17; a patch silently never applied;
   an anchor hit the wrong occurrence for 6 false greens; two lanes raced the same worktree;
   a greedy `re.S` regex ate six store actions and reported success. PIT mutates bytecode in
   memory, so it writes no source file, matches no anchor, triggers no recompile, and cannot
   be raced. Hand-roll only where PIT cannot reach (Jest/Vue, SQL, config).
4. **One independent review pass.** Never self-approve in the authoring context.
5. **Full suite compared against the known baseline** — not "did it pass", but "are the failures the same ones".

A tier decides how much *planning and documentation* you do. It never decides whether you do these.


## Ticket policy — one ticket per FIX VISIT, and ask first

**Revised 2026-08-21. This supersedes the older "record the finding in the plan by default, file by exception" rule** — a finding recorded only in a plan or a ticket comment **dies when that plan is archived**, so findings *do* belong in tickets. The lever is not *fewer findings filed*, it is **fewer tickets per finding**.

What the old rule got right and this one keeps: discovery outruns implementation here (**43 plans in flight, 12 of them unimplemented as of 2026-08-20**), and an unactionable backlog is **worse** than a note, because it looks tracked. So:

- **One ticket per FIX VISIT** — one code path plus one owner — never one per symptom. Two symptoms in the same method are one ticket. (Worked example: SBDEV-1615, the picking-started guard 500s, and SBDEV-2473, the same method deferring replenishment re-sync, are one `adjustReservedAmount` visit — not two tickets.)
- **Search before filing, then widen.** Search the backlog for a ticket sharing the code path; if one exists, widen it and add your evidence there. File only when no code-path sibling exists. (SBDEV-3011 → widening SBDEV-3012 was right; a separate ticket for the same non-atomic pattern in the same controller would have split one piece of work in two.)
- **The filing test: would you accept a standalone PR for it?** If the answer is no, it is not a ticket — it is a line in the plan or a comment on the ticket you are already in. This is the sharpest of the filing criteria; apply it before the two below.
- **Ask before filing.** Hard cap of **one new ticket per fix**, and Nam confirms it. 68 of 94 assigned tickets are already high-or-urgent, so the priority signal is saturated — adding to it costs more than it records.
- Correcting a stale citation or line number in an *existing* ticket is always free — do it; it costs a comment and saves someone landing in the wrong method.

**Where each kind of finding goes.** Getting this wrong is what produced the backlog:

| Finding | Destination |
|---|---|
| Defect in the code being changed | fix it in the same PR; no ticket |
| Defect in **tooling, templates or skills** | **fix it directly** — do not file, do not merely write a memory. `.claude/**` and `sbdocs/9-System/**` are editable. Eight memories recorded ways verify scripts lie while the template that generates them stayed broken and 51 scripts inherited the fault |
| Defect in adjacent product code | search-then-widen per above |
| Environment / data finding | attach to the ticket that caused the discovery, with a named owner |
