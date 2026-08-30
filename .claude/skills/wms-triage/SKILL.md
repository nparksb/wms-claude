---
name: wms-triage
description: FIRST STEP for every WMS task, before wms-bugfix-plan / wms-feature-plan / wms-v2-migrate / wms-tdd-gate / wms-plan-executor. Run it on a stack trace, an HTTP 500, an SBDEV ticket, a stuck workflow, a feature or refactor request, a v1->v2 port, or an investigation — including anything that looks like a one-liner. Answers: is it already fixed on origin/develop? does it reproduce? is the reported cause the real cause? is it one line? — then assigns an effort tier T0-T3 on execution risk. Single source of truth for the tier router, the five-item floor that never scales, fix discipline (sibling sweep, invariant-over-instance, citation form), claim discipline (completeness words, two instruments), the ticket-filing policy, and verify-script row hygiene; every other WMS skill defers here. Output is a five-line triage block on the ticket, never a file.
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

   ⚠️ **The kill must be ATTRIBUTABLE: the failure message has to name the thing you broke.** A red that arrives as `NoSuchMethodException`, an NPE in setup, or a diagnostic quoting a *different* constant is a red, not a kill — it proves the test noticed something, not that it is guarding what you think. Measured twice: SBDEV-3169's structural pin first "killed" via `NoSuchMethodException` because it looked the method up by signature, and an earlier hand-rolled harness reported 4/4 KILLED where only one mutant was real — the tell was M2's diagnostic quoting M1's constant. If the message does not name the mutant, rewrite the assertion until it does.

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

---

## Fix discipline — three habits that cost seconds and repeatedly paid

Not part of the floor (the floor is about *evidence*); these are about *the change itself*. All three are
measured on this repo, not borrowed advice.

### 1. Sweep for siblings of the LITERAL you changed, not the symbol

**The single most repeated defect in this workspace is "fixed one copy of a pattern, missed the others."**
Measured on SBDEV-3157 alone, in one day: a javadoc count corrected while both `@DisplayName` copies of the
same number were missed (so the PR whose purpose was fixing that number shipped it still wrong); a reviewed
allow-list that exists in **four** places, one of which spells its elements in a different order so a
string-replace over three looked complete; and earlier, 33 stale rationale comments and a sentinel fixed
once when three existed.

**The step:** after changing a literal — a count, a constant, a message, a path — grep the repo for the
**old value**. Not the symbol, not the new value. Ten seconds, and it is the only thing that finds a copy
you did not know about. `git grep -n '<old literal>'` before you commit.

### 2. Fix the RULE, not the instance you were handed

When a finding names one site, ask what invariant that site violates and assert **the invariant**. A pin on
the reported instance ships, looks complete, and leaves the siblings.

Measured, SBDEV-3169: an enumeration lane reported **one** exported Spring Data REST search taking a
`PESSIMISTIC_WRITE` lock. Written as *"no exported SDR search resolves to a `@Lock` method"*, the same test
found **ten, across nine repositories**, on the hottest entities in the product. A path pin would have
closed one tenth of it and read as done.

This is the same lesson as *a guard fences the mechanism you aimed at* — applied before the fact instead of
after.

### 3. Cite a quoted string, not a line number

`file:line` decays on every merge. Measured on one SBDEV-3169 plan review: **six** citations had drifted by
1–3 lines, and one pointed at a **comment block** rather than the code it claimed — inside the very
paragraph warning about stale citations.

Prefer `file` plus a short distinctive quoted snippet: a reader can grep it, and it relocates itself. Keep
line numbers only where they are cheap to re-derive and add real precision, and never treat one copied from
an older document as current.

---

## Claim discipline — the asymmetry to internalise

Measured on SBDEV-3169's adversarial review: the fact-check lane **reproduced every quantitative claim
exactly** — surface counts, row counts, population figures, percentages — and **broke every completeness
claim**: *"every caller"*, *"exactly six"*, *"the six paths"*, *"no controller at all"*, *"two independent
corroborations"*, *"v1 has none"*. Eleven false claims, and not one of them was a number.

That is not luck. Counting is cheap and checkable; asserting a closed set means proving a negative.

**So: any sentence containing *every · only · all · no · exactly · none* must name the method that derived
it and that method's blind spots, inline.** Two examples of the same author getting this right and wrong on
the same day:

- *Right* — a test whose javadoc says it detects `@Lock` **only** (a native `SELECT … FOR UPDATE` inside
  `@Query` is invisible to it), **searches only**, and says nothing about authorization.
- *Wrong* — *"there are exactly six SDR controller classes"*, written as the justification for a rule whose
  stated rationale is **do not assert closed sets**. There were seven, one in a sub-package, and one of the
  six was an annotation rather than a controller.

**Corollary — two instruments, always, for any count that drives a decision.** grep and runtime disagree on
this codebase; the runtime SDR inventory both *under*-reports (association paths absent) and *over*-reports
(an MVC mapping can shadow an exported SDR route); and an HTTP-derived population count silently used the
join table as its denominator, hiding the 44 users who hold no group — a factor-of-3.5 error in the
direction that understated the exposure. **When two instruments disagree, that disagreement IS the
finding**, not an inconvenience to resolve by picking one.


## Ticket policy — findings go on the ticket you are already in

**Revised 2026-08-28 (Nam). This is the primary rule and it supersedes the older search-then-widen default:**

> **A new fix discovered during analysis or implementation goes onto the EXISTING ticket when its own tier is below T3. If it is T3, PROPOSE a new ticket — do not file one.**

That is the whole rule. Everything below is how to apply it, not additional hurdles.

- **"The existing ticket" means the one you are working in.** You no longer have to find a code-path sibling before a finding has somewhere to go. Add it to the ticket that surfaced it, as a comment naming `file:line`, the tier of the added scope, and what a fix would involve.
- **Tier the ADDED scope on its own** — not the combined ticket, and not the host's existing tier. Ten more endpoints on a gating ticket is T3 work whether or not the host already says T3.
- **T3 additions are proposed, never filed.** Authorization · data integrity · a Flyway migration · multi-repo · irreversible · root cause unknown. A T3 addition is not an addendum, it is a second project wearing the first one's number, and it silently re-tiers a ticket someone picked up as an afternoon's work. State the finding, say it is T3 and why, and let Nam decide. Hard cap of **one proposed ticket per fix visit**.
- **The filing test still applies to the T3 branch: would you accept a standalone PR for it?** If no, it is a comment, not a ticket — even at T3.
- **Never drop a finding to stay tidy.** A finding recorded only in a plan **dies when that plan is archived**; that is why findings belong on tickets. The lever is fewer *tickets* per finding, not fewer findings.
- Correcting a stale citation or line number in an existing ticket is always free — do it.

### The one carve-out: a sibling at `on dev` or later

Adding scope to a ticket whose code is already **deployed** corrupts the deployment ladder — in this workspace the status ladder *is* the tracker (`on dev` → `on qa` → `ready for deployment` → `on prod` → `Closed`). A widened ticket either stalls the promotion of code that already shipped, or gets promoted carrying scope that was never built.

| sibling status | sub-T3 finding goes |
|---|---|
| `Open` · `pending` · `ready for sprint` · `blocked` · `in development` · `comitted local` | **onto that ticket** |
| `on dev` · `on qa` · `ready for deployment` · `on prod` · `Closed` | **propose a new ticket** — say why, and name the sibling in Related |

Nam specified `on dev` and confirmed 2026-08-28 that "at or past `on dev`" is the intended reading. Settled; do not re-litigate.

⚠ **This carve-out is the only thing that turns a sub-T3 finding into a new ticket.** If the ticket you are in has not shipped, the finding goes on it — do not invent other reasons to split.

**When you cannot add to the existing ticket, say so explicitly and propose the new one** — never widen quietly, never drop the finding. Name the sibling in the new ticket's Related, and comment on the sibling pointing at the new one, so the code-path link survives the split.

**Status and acceptance criteria must move together.** The status gate above assumes a ticket's status
describes what is actually built. Measured on SBDEV-3157: it sat at **`on dev` with five of its six ACs
unticked**, because only one of its two halves had shipped. The board said deployed; most of the work did
not exist. Nothing detected that — the ladder tracks deployment, and no one had told it the scope had
shrunk.

**So: when you move a ticket to `on dev`, tick or strike its acceptance criteria in the same action.**

- Every AC met → tick it.
- An AC that is **out of scope now** → strike it and name the ticket that carries it, in the same edit.
- If you cannot do either for an AC, the ticket is not `on dev` — it is a split waiting to happen, and the
  file-don't-widen rule above tells you which way it goes.

**A ticket at `on dev` or later with mostly-unticked ACs is a reliable signal that scope was split or
quietly abandoned.** Treat finding one as a triage result in its own right, not as paperwork: it means the
next reader — and the status gate — is working from a false picture of what shipped.

**Where each kind of finding goes.** Getting this wrong is what produced the backlog:

| Finding | Destination |
|---|---|
| Defect in the code being changed | fix it in the same PR; no ticket |
| Defect in **tooling, templates or skills** | **fix it directly** — do not file, do not merely write a memory. `.claude/**` and `sbdocs/9-System/**` are editable. Eight memories recorded ways verify scripts lie while the template that generates them stayed broken and 51 scripts inherited the fault |
| Defect in adjacent product code | sub-T3 → onto the ticket you are in; T3 → propose one. Per above |
| Environment / data finding | attach to the ticket that caused the discovery, with a named owner |
