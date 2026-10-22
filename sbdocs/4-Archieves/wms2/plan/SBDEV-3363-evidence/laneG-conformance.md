# Lane G — Phase 3a conformance check, SBDEV-3363 **Fix A only**

## Provenance of everything below

- **Worktree graded:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3363`
- **Branch:** `bugfix/SBDEV-3363-deferred-cancel-terminal-path` · **HEAD** `2a80ed7f`
  ("SBDEV-3363: let an already-CANCELED position stop blocking the order cancel")
- **`git merge-base HEAD origin/develop`** → `9e294d4b7fa1a1ce41eca69a6987a5fffa0f2bcc` — matches the brief.
- **Working tree clean** (`git status --short` → empty output). Nothing graded here came from an
  uncommitted edit, so the commit and the tree say the same thing.
- **The stale copy `/home/nampark/dev/wms-claude/v2/wms2-api` was never opened.** Every path below is
  relative to the worktree above.
- **Instruments used:** `git diff origin/develop...HEAD`, `git status`, `grep -n` on HEAD content,
  full reads of the changed hunks and the whole test file, and a **fresh Maven compile + targeted
  test run** (see §Build, and the note on where it was run and why).

---

## Criterion-by-criterion

### 1. §0.1 Group A rows

| Row | Plan says | Found | Verdict |
|---|---|---|---|
| **A0** — both `cancelOrder` loops | "this is where the fix goes" | Both loops carry `if (customerOrderPosition.getState() == WmsConstants.State.CANCELED) { continue; }` — guard loop at `CustomerorderService.java:820`, cancel loop at `:890` | **VERIFIED** |
| **A1** — `canOrderPositionBeCancelled` `>= PACKED` | in scope **no**, "not modified" | `git diff origin/develop...HEAD -- .../CustomerorderPositionService.java` → **0 lines**. Band still `getState() >= WmsConstants.State.PACKED` at `CustomerorderPositionService.java:61` | **VERIFIED (genuinely untouched)** |
| **A2** — `cancelOrderPosition` entry throw | in scope **no**, "not modified" | Same zero-line diff. Entry guard + throw intact at `:120–121`; its `< PACKED` work bound intact at `:141` — i.e. the hazard §3.1.1 names is still there, which is *correct*, because Fix A routes around it instead of through it | **VERIFIED (genuinely untouched)** |
| **A3** — `>= PACKED && < CANCELED` half-open band | "already correct", out of scope | Unchanged at `CustomerorderService.java:798`; not present in the diff | **VERIFIED** |
| **A4** — `isShippedOrPastCancellationBoundary` | "already correct", out of scope | Not present in the diff | **VERIFIED** |
| **A5** — `BillofladingService` | "different question", out of scope | `git diff` for that file → **0 lines** | **VERIFIED** |
| **A6** — RAPID `pickingPositions.get(0)` | in scope, one-line guard | `if (!pickingPositions.isEmpty()) { … }` wraps the whole RAPID release block; the diff is a pure re-indent of the existing body plus the guard, with a closing-brace comment | **VERIFIED** |

**The plan does say A3/A4/A5 are out of scope**, in the §0.1 table's "In scope?" column, each with a
stated reason (A3/A4 "already correct, the precedent"; A5 "different question … its own comment says
so"). So the untouched state is conformance, not omission.

**Whole-diff scope check:** `git diff origin/develop...HEAD --name-only` returns exactly two paths —
`src/main/java/net/aim_ai/wms/service/CustomerorderService.java` and
`src/test/java/net/aim_ai/wms/integration/CancelOrderAlreadyCancelledPositionIntegrationTest.java`.
**One main-source file, as the brief predicted.** Nothing from Fix B/C/D/E leaked in.

### 2. §3.1's design as written — caller-side skip, `coPositions` not filtered

**VERIFIED**, and this is the row I checked hardest because §3.1 flags it with a ⚠.

- The skip is a `continue` **in place** in each loop. `coPositions` is never reassigned, never
  `.filter(...)`-ed, never shadowed by a narrowed local.
- I enumerated every use of the identifier in the file (`grep -n "coPositions"`): within `cancelOrder`
  it is assigned once at `:797`, read by the `anyMatch` at `:798` (A3), the guard loop at `:804`, the
  RAPID `get(0)` at `:842`, the cancel loop at `:886`, and the **OMS payload builder at `:987`**.
- I read the payload builder. It is
  `coPositions.stream().map(position -> { … }).collect(Collectors.toList())` with **no filter and no
  predicate** — it maps every element of the same unmodified list into `OrderPositionDto`, which then
  becomes `orderDto.setPositions(...)`. **So the downstream OMS payload still sees every position,
  including the CANCELED ones** — exactly the property §3.1's ⚠ demands.

The committed comments also carry the §3.1.1 reasoning (why the fix is *here* and not in
`CustomerorderPositionService`, naming the `< PACKED` vs `< PICKED` bound and live order `585000351`),
and the A6 comment states the dead-today-but-data-armable justification. The code documents its own
invariant rather than leaving it in the plan only.

### 3. §8.1's three fixtures

File: `src/test/java/net/aim_ai/wms/integration/CancelOrderAlreadyCancelledPositionIntegrationTest.java`
(339 lines), `extends BaseRollbackIntegrationTest` — the **H2 lane** the plan's "GATE OUTCOME" block
selected, not Testcontainers. Correct per §8.1.

| Fixture | §8.1 shape | Constructed shape in the test | Verdict |
|---|---|---|---|
| **1 — stranded (`28848660`)** | cop 800, line 800, PO 700, `pcs=false` | `newOrder(…, ASSIGNED, false)` → `pickingconfirmationsent=false`; `newPosition(…, CANCELED, 1)`; `newPickingorder(…, FINISHED)`; `newPickLine(…, CANCELED, "0.0000")`. **Shape matches.** Asserts `co.state == CANCELED` and `markedforcancellation == false` | **PARTIAL** — see below |
| **2 — regression pin (`585000351`)** | cop 800, line **600**, `amountpicked=1`, PO 700, `pcs=true` | `newOrder(…, ASSIGNED, **true**)`; position `CANCELED`; picking order `FINISHED`; `newPickLine(…, **PICKED**, "**1.0000**")`. **Shape matches on every field.** Asserts `pop.state` stays `PICKED` **and** `po.state` stays `FINISHED` — both assertions §8.1 names, each with an `.as(...)` diagnostic that quotes `cancelOpenPickLines`' javadoc | **VERIFIED** |
| **3 — mixed** | cop 800 + cop 200 open | `newPosition(…, CANCELED, 1)` + `newPosition(…, PROCESSABLE, 2)`, each with its own pick line, picking order `STARTED`. Asserts order reaches `CANCELED` and the **open** position reaches `CANCELED` | **PARTIAL** — see below |

**Fixture 2 is a regression pin that passes before and after — confirmed by design, not by omission.**
Its javadoc opens "⚠ *This test passes on today's code and must keep passing. It is a regression pin,
not a gate criterion — it exists to reject a specific WRONG fix.*" That matches §8.1's measured table
(the rejected two-guard design is green on 1 and 3 and red only here). Not a defect.

**Two assertion gaps against §8.1's own table — both real, both minor:**

- **Fixture 1 does not assert the outbox row.** §8.1's row asks for "*one
  `ORDER_BATCH_CANCELLED_FROM_WMS` outbox row*". The test asserts only `co.state` and
  `markedforcancellation`. It **cannot** assert the outbox row as written: `MessageService` is declared
  `@MockitoBean` (line 101–102), alongside `@MockitoBean HttpRestService` and `@MockitoBean
  SyspropService`, so the enqueue is stubbed out rather than observed. Nothing verifies the OMS
  notification actually fires for the newly-unblocked order. Given §3.1's ⚠ about the payload needing
  every position, this is the one assertion I would have most wanted — a `verify(messageService, …)`
  or an outbox-repository count would cost one line against a mock that is already injected.
- **Fixture 3 does not assert "the cancelled one is untouched".** §8.1's row says "*the open position
  is still cancelled; **the cancelled one is untouched***". The test asserts the first half. The
  already-CANCELED sibling is never reloaded, so "untouched" is unverified (it is weakly implied —
  CANCELED is terminal — but that is an argument, not an assertion).

Neither gap weakens the AC-1 claim itself, and neither is a wrong assertion; they are assertions the
plan promised that the code does not make. I am recording them as PARTIAL rather than VERIFIED because
the brief asked whether each fixture "*actually constructs the shape it claims*" **and** what it grades.

**One fixture detail worth crediting:** the `@BeforeEach` seeds a **real** `Itemdata` with an inline
comment explaining that a placeholder id looks fine pre-fix (the payload builder is unreachable) and
dies with `EntityNotFoundException` post-fix. That is §8.1's "⚠ Fixture gap the mutation check caught"
carried into the code where it cannot be lost — good practice, and independent evidence the mutation
check described in §8.2 was actually run rather than predicted.

### 4. Build and tests — run fresh by me

**Where I ran them, and why not in the worktree.** The brief said a full `mvn verify` was already
running in this worktree and that a targeted `-o test` would be fine. When I checked
(`ps -eo pid,etime,args | grep maven`) that build — PID `1103693`, `-B -ntp clean verify`, with
`multiModuleProjectDirectory` pointing at this worktree — was **live and inside its surefire fork**
(PIDs `1104919`/`1104920`, JaCoCo agent writing `target/jacoco.exec`). The brief's own first command
is `mvn -B -ntp -o clean compile`, and **`clean` would have deleted `target/` out from under that
running fork** — destroying the other lane's run and guaranteeing a false red for mine. Concurrent
Maven in one worktree is a known false-red source here.

So I built an **isolated copy of the exact commit** instead of touching the shared tree:

```
git archive 2a80ed7f | tar -x -C <scratchpad>/build3363
```

and verified the copy is the same code before grading it:
`diff -q` on `CustomerorderService.java` between the copy and the worktree → **identical**; the test
file is present; `grep -c SBDEV-3363` on the service → 4 hunks. The working tree being clean is what
makes `git archive <HEAD>` equivalent to the tree. **This grades the committed code, in a tree nothing
else was writing to.**

| Command | Result |
|---|---|
| `mvn -B -ntp -o clean compile` | **BUILD SUCCESS**, 12.3 s, `COMPILE_EXIT=0` |
| `mvn -B -ntp -o test -Dtest=CancelOrderAlreadyCancelledPositionIntegrationTest -Dsurefire.failIfNoSpecifiedTests=false` | **`Tests run: 3, Failures: 0, Errors: 0, Skipped: 0`** in `CancelOrderAlreadyCancelledPositionIntegrationTest`, 27.93 s · **BUILD SUCCESS**, `TEST_EXIT=0` |

**VERIFIED.** The selector matched the class (3 tests, not 0) — so this is a real verdict on real code,
not a stale-XML read from a selector that matched nothing.

**One piece of log noise, checked and dismissed:** the run logs an H2 `JdbcSQLSyntaxErrorException` on
`create table tenant_discovery (… key varchar(50) …)` — `key` is reserved in H2 — plus the standing
`LockTimeoutHibernateJpaDialect` SBDEV-3250 warning about H2 not being PostgreSQL. Both are
**pre-existing landlord-schema noise, not caused by this change**: the diff touches no entity, no
mapping and no DDL, and the suite still reports BUILD SUCCESS with 0 errors. Recording them so the
next lane does not re-investigate them as regressions.

**What I did *not* run:** the full suite. §8's baseline (surefire `6629/0/0`, failsafe `409/0/0`) is the
comparison the floor requires, and the other lane's `mvn verify` is the run that produces it. **I am
not claiming the full-suite row** — see "Could not confirm" below.

### 5. §10 open questions — does anything still-open block Fix A?

| Item | State in the plan | Blocks Fix A? |
|---|---|---|
| **Q1** | **RESOLVED** 2026-09-15 by reading `CancellationReversalService.completeReversal` rather than its comment | No |
| **Q4** | **DECIDED (Nam, 2026-09-15): option (a)** — accept and document; Fix A skips outright and writes no log row. Marked *"Do not re-litigate this at the gate or in review."* | No — **and the code conforms**: the `continue` skips the position entirely and adds no `recordCancellation` call, which is option (a) exactly, not (b) |
| F1 | finding, stays on ticket, deliberately not fixed here | No |
| F2 | optional hygiene, Fix B scope | No |
| F3, F4 | T3 → proposed, not filed; Fix B / Fix D scope | No |
| Q3 | out of scope; "nothing is stuck", producer dead | No |
| **Q2** | **still open** — *"does any OMS-side behaviour depend on receiving the current rejection for these orders? Only the WMS side was traced."* | **Not a stated blocker, but it is the one open item inside Fix A's blast radius.** Fix A's whole effect is that these orders now send an OMS cancel notification where today they send nothing, and Q2 is precisely the question of what OMS does with it. Flagging, not blocking — the plan does not gate step 1 on it |

§5.1 prerequisites: the only ⚠ row is the Flyway version, which belongs to **Fix D**, not Fix A. No open
prerequisite blocks step 1.

### 6. Deferred-by-design (NOT missing)

The plan explicitly authorizes shipping this subset. §5.2 orders the work 1–5 and states: *"Steps 1 and
2 are independent of 3–4 and of each other, so if the ticket has to be split under budget, split it
there."* Step 1 is *"Fix A + A6 … `CustomerorderPositionService` is untouched. **Independently
shippable.**"*

| Fix | Scope | Present in `2a80ed7f`? | Verdict |
|---|---|---|---|
| **Fix A + A6** (AC-1) | §5.2 step 1 | yes | in scope, implemented |
| Fix B (AC-5, Option 3) | §5.2 step 3 | no | **deferred by design** — plan says so |
| Fix C (Mobile M-4) | §5.2 step 4; different repo (`wms2-mobile-ui`) | no | **deferred by design** — and §5.1 requires API-before-mobile deploy order |
| Fix D (AC-4 Flyway) | §5.2 step 2 | no | **deferred by design** |
| Fix E (AC-6 repair) | §5.2 step 5, *"after Fix A reaches dev"* | no | **deferred by design** — by definition cannot precede this commit |

---

## Plan-side drift found (documentation, not code)

Two internal inconsistencies in the plan. Neither is a code defect; both would mislead the next reader.

1. **§5.2 step 1 says "the AC-1 *Testcontainers* fixtures (§8.1)"**, but §8.1's GATE OUTCOME block
   explicitly overrides that: *"the lane is H2, not Testcontainers. An earlier draft said
   Testcontainers."* The implementation followed §8.1 (H2 / `BaseRollbackIntegrationTest`), which is
   the later and more specific decision — **the code is right and §5.2 is stale.** Worth a one-word fix
   so a future reader does not "correct" the test into the container lane.
2. **§5.2 says "step 1 alone closes AC-1 and AC-6"**, but AC-6 *is* Fix E (§3.5), which the same list
   schedules as step 5 *"after Fix A reaches dev."* Step 1 **unblocks** AC-6; it does not close it.

Also noted for whoever finalizes: §8.2 ends with the sentence *"A red arriving as
`NoSuchMethodException` or an NPE in setup is not a kill"* **three times**, and the paragraph about the
vacuous `< CANCELED → <= CANCELED` pairing appears **twice** (once at the end of the table's note, once
in the ⚠ under row 3). Editing residue, harmless.

---

## Could not confirm

Named explicitly rather than folded into a pass.

- **The full-suite comparison against §8's baseline.** I ran only the targeted class. The `mvn verify`
  owned by the other lane in this worktree is the run that produces it; its result is not mine to
  report. **Floor item 5 is therefore not discharged by this lane** — someone must compare that run
  against surefire `6629/0/0` + failsafe `409/0/0`.
- **The §8.2 mutation rows.** The plan states rows 1–3 are "MEASURED, not predicted" and run
  2026-09-15. I did **not** re-run PIT or re-apply the mutants; re-running them would mean editing the
  tree, which this lane has no write access to and should not do. My independent corroboration is
  indirect but real: the committed fixture carries the `Itemdata` comment describing a failure mode
  *only observable on a tree where the fix works*, which is consistent with the mutants having been
  executed. Treat the mutation rows as **asserted by the implementer, corroborated but not
  re-measured here.**
- **Runtime behaviour against a real tenant DB.** H2 only; no PostgreSQL execution of the cancel path.
  §8.1 argues no assertion here depends on PostgreSQL semantics, and having read the three tests I
  agree — but that is a reviewed argument, not a measurement.
- **Q2** (OMS-side behaviour on the newly-sent cancel notification), per §5 above.

---

## Verdict

### **PASS** — with two minor assertion gaps and two plan-doc nits, none blocking.

| Criterion | Verdict |
|---|---|
| §0.1 A0 — both loops carry the skip | **VERIFIED** |
| §0.1 A6 — RAPID `isEmpty()` guard | **VERIFIED** |
| §0.1 A1/A2 — `CustomerorderPositionService` genuinely untouched | **VERIFIED** (0-line diff; bands intact at `:61`, `:120`) |
| §0.1 A3/A4/A5 — out of scope and not touched | **VERIFIED** (plan states each as out of scope, with reasons) |
| Diff is one main-source file | **VERIFIED** |
| §3.1 — caller-side skip in both loops | **VERIFIED** |
| §3.1 ⚠ — `coPositions` neither reassigned nor filtered; OMS payload still sees every position | **VERIFIED** (payload builder at `:987` maps the unfiltered list) |
| §8.1 fixture 1 (stranded) | **PARTIAL** — shape correct; the promised outbox-row assertion is absent and unreachable as written (`MessageService` is `@MockitoBean`) |
| §8.1 fixture 2 (regression pin) | **VERIFIED** — shape correct on every field, both assertions present, and correctly documented as passing before and after |
| §8.1 fixture 3 (mixed) | **PARTIAL** — shape correct; asserts the open position is cancelled but never reloads the already-CANCELED sibling to assert "untouched" |
| Fresh `clean compile` | **VERIFIED** — BUILD SUCCESS |
| Fresh targeted test run | **VERIFIED** — 3 run / 0 failed / 0 errors / 0 skipped, BUILD SUCCESS |
| §10 — nothing still-open blocks Fix A | **VERIFIED**, with Q2 flagged as the one open item in Fix A's blast radius |
| Fix B/C/D/E absent | **deferred by design**, per §5.2 — not missing |

**The committed code does what §3.1 designed.** The two PARTIALs are assertions the plan promised that
the tests do not make — they narrow what the suite would catch in future, but they do not weaken the
AC-1 claim, and the discriminating fixture (2) is fully present and correct. Recommend closing the
fixture-1 outbox gap (one `verify(messageService, …)` against an already-injected mock) before the PR,
and treating fixture 3's missing sibling assertion and the two §5.2 doc nits as cleanup.
