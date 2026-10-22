# SBDEV-3323 — independent conformance / claim verification

**Lane:** `verify-3323` (independent verification, read-only)
**Date:** 2026-09-15
**Method:** every claim re-derived from scratch in **temporary worktrees of my own**, never in the two
shared SBDEV-3323 worktrees. Nothing in the shared trees was edited, stashed, checked out or reset.

## Worktrees I created (and their provenance)

| Path | Base | Contents |
|---|---|---|
| `…/scratchpad/api-base` | `origin/develop` `46bac87d` | clean, for the API baseline |
| `…/scratchpad/api-verify` | `46bac87d` + the lane's diff | for the with-change API run |
| `…/scratchpad/mobile-baseline` | `origin/develop` `fb72f0d` | clean, for the Jest baseline |
| `…/scratchpad/mobile-mut` | `fb72f0d` + the lane's diff | for the with-change Jest run and my mutation sweep |

The diff was lifted out of the shared trees with `git diff HEAD` plus a copy of the untracked test
files, then re-applied with `git apply`. Both shared trees are descendants of the stated bases:

```
$ git -C .claude/worktrees/wms2-api/SBDEV-3323 rev-parse HEAD origin/develop
46bac87ddabd1a7295cbc6544c99ee9b16dc70c9   (both)
$ git -C .claude/worktrees/wms2-mobile-ui/SBDEV-3323 rev-parse HEAD origin/develop
fb72f0d483378d73061e98e3b023c5e334f64746   (both)
```

⚠ **Contamination check first.** A mutation harness (`/tmp/claude-1000/mut3323/run.py`) was *running
in the shared mobile worktree while I was reading it* — `pgrep -af jest` showed
`node_modules/.bin/jest --testPathPattern=cancellation --json --outputFile=/tmp/claude-1000/mut3323/jest.json`
live at the time of my first read. I therefore verified that what I captured was the un-mutated
source before using it, by checking the two files byte-for-byte against the harness's own pristine
backups and checking that all 18 mutation anchors were present:

```
cancellation.js         worktree==pristine: True  (13830 chars)
cancellationAction.vue  worktree==pristine: True  (5531 chars)
ANCHOR MISSES IN PRISTINE: 0   (18/18 anchors present, each exactly once)
```

So the diff under test here is the real one. **But note the operational hazard**: if that harness had
crashed mid-mutant, the shared worktree would have been left holding mutated source, and any lane
reading it — including a reviewer, or a commit — would have picked that up silently. Nothing in the
harness guards against it.

---

## Summary of verdicts

| Claim | Verdict | One line |
|---|---|---|
| A — Jest 30/355 → 32/379 | **BROKEN (number), CONFIRMED (substance)** | with-change is **383**, not 379. Baseline 30/355 is right; delta is exactly the 28 new tests; no existing test touched |
| B — `mvn clean test` 6600 / 0 / 1 skipped | **CONFIRMED** | 6600 / 0 failures / 1 skipped; the skip is `@Disabled` for SBDEV-2608, pre-existing on `46bac87d` |
| C — mobile UI is the only caller | **CONFIRMED** | reproduced with a different instrument (`grep -r`, not `git grep`) over all 7 repos, all file types, gitignored files included |
| D — 7 pending rows, 2 orders, multi-position, all `picktostockunit_id` NULL | **CONFIRMED** (with one material addition) | exact match; **but** neither order contains a single `reversal_required = false` row, so the mixed order the fix is designed for does not exist on PRD today |
| E — `NOT NULL DEFAULT true`, null arm unreachable | **CONFIRMED** | live schema + **both** migration paths (the cited `V2.1.12` and also `V2.2.00`, which the claim did not mention) |
| F — `amount_picked` stores the ordered amount; blast radius display-only | **PARTIAL — the second half is BROKEN** | the code claim is right and the DB proves it. The blast radius is **not** display-only: `amount_picked` is the quantity `completeReversal` physically transfers back to stock |
| G — no AC-3 test exists | **BROKEN — your suspicion is wrong** | the diff contains a dedicated 4-test `describe` block for AC-3, including a positive control |
| H — 16 killed / 0 survivors, trustworthy | **PARTIAL** | the *number* is wrong (the script holds **18** mutants). The *substance* holds: I reproduce **18 killed / 0 survivors** under a harness with the four guards the original lacks |

---

## A — Jest counts

**Baseline, re-derived from a clean detached checkout of `origin/develop` `fb72f0d`:**

```
$ cd …/scratchpad/mobile-baseline && npx jest --ci
Test Suites: 30 passed, 30 total
Tests:       355 passed, 355 total
```

✅ Baseline claim **CONFIRMED**.

**With the change, in my own re-application of the diff:**

```
$ cd …/scratchpad/mobile-mut && npx jest --ci
Test Suites: 32 passed, 32 total
Tests:       383 passed, 383 total
```

❌ You claimed **379**. The real figure is **383**. Delta is **+2 suites / +28 tests**, not +24.

The 28 reconcile exactly against the two new files — 18 `it()` in
`test/store/cancellationPartialReversal.spec.js` (8 + 4 + 6 across three `describe`s) and 10 in
`test/components/cancellation-partial-selection.spec.js` (5 + 2 + 2 + 1). 355 + 28 = 383. The likely
cause of 379 is a count taken before the last four tests — the AC-3 `describe` is exactly four tests
— which is worth knowing because it means **the number you reported predates the AC-3 block you
believed you had not written** (see G).

**"Did not modify or delete an existing test" — CONFIRMED**, by content hash rather than by eye:

```
$ (cd mobile-baseline && find test -type f | sort | xargs md5sum) > base
$ (cd mobile-mut      && find test -type f | sort | xargs md5sum) > chg
$ diff base chg
0a1
> 8fac360a…  test/components/cancellation-partial-selection.spec.js
18a20
> f2a0ee7b…  test/store/cancellationPartialReversal.spec.js
```

Two files **added**, zero modified, zero deleted — all 18 pre-existing test files byte-identical.

---

## B — `mvn clean test`

Run in `…/scratchpad/api-verify` (my own worktree, so it cannot be a stale `target/` and cannot race
the other lane's Maven — see the "concurrent Maven in one worktree" trap):

```
$ JAVA_HOME=…/21.0.11-ms mvn clean test
[WARNING] Tests run: 6600, Failures: 0, Errors: 0, Skipped: 1
[INFO] BUILD SUCCESS
```

✅ **CONFIRMED.**

**The 1 skipped is pre-existing.** Identified from the surefire XML rather than from the console
count:

```
SKIPPED: net.aim_ai.wms.landlord.config.TenantPoolEndpointSecurityTest :: evict_missingAdminRole_forbidden
  msg: SBDEV-2608: actuator security slice deferred — no @WebMvcTest/@Endpoint test infra exists yet…
```

and confirmed against the base commit itself, not against a working tree:

```
$ git show 46bac87d:src/test/java/net/aim_ai/wms/landlord/config/TenantPoolEndpointSecurityTest.java | grep -A2 Disabled
65:    @Disabled("SBDEV-2608: actuator security slice deferred …")
$ git log -1 --format='%h %ad %s' --date=short -- …/TenantPoolEndpointSecurityTest.java
8c92d8f0 2026-09-02 fix(multi-tenancy): SBDEV-3192 …
```

Unrelated ticket, unrelated package, untouched by this diff. ✅

A full clean `mvn clean test` on the untouched base (`…/scratchpad/api-base`) was also run to confirm
the delta is only the 5 new API tests (2 in `CancellationReversalServiceUnitTest`, 3 in the new
`CancellationLogEntryDtoSerializationTest`). **Result: see the appendix at the foot of this file.**

---

## C — only the mobile UI calls `POST /v3/cancellation/{coId}/complete`

You used `git grep`. I deliberately used a **different instrument with different blind spots**:
plain `grep -rIn`, which reads working-tree files including ones `.gitignore` hides from `git grep`
(the known `wms2-web-ui .gitignore reports/` trap), across all seven repos and every relevant
extension — and I searched for the *path fragment*, not the function name, so a dynamically built URL
cannot hide:

```
$ grep -rInE "cancellation/[^\"'\`]*/?(complete|detail|initiate)|/cancellation/" \
    --include='*.js' --include='*.vue' --include='*.ts' --include='*.tsx' --include='*.php' \
    --include='*.java' --include='*.json' --include='*.yaml' --include='*.yml' --include='*.md' \
    v1 v2 | grep -v node_modules | grep -v /target/
```

**Positive control:** the scan is live — it returns the mobile-UI hits, the wms2-api test hits, and an
unrelated doc mention in `oms-laravel-api`. A silent zero was not possible.

Callers found, exhaustively:

- `v2/wms2-mobile-ui/store/cancellation.js:127` — `` $post(`/cancellation/${coId}/complete`, …) `` — **a template literal, i.e. the dynamically-built-URL case, and it is still found by the path-fragment search.**
- Nothing else anywhere. `v1/oms`, `v1/wms-web-ui`, `v1/wms-mobile-ui`, `v2/wms2-web-ui`, `v2/omsv2-UI` and `v2/oms-laravel-api` have **zero** hits on any `/cancellation/` path.

A third pass on the spellings `completeReversal` / `complete-reversal` / `completeSelectedPositions`
over *all* files (no `--include` filter) returns only the mobile store, the mobile component, and the
wms2-api server side.

One more angle checked, because it is how a PHP caller would normally hide: `oms-laravel-api` builds
WMS URLs from `config/wms.php` endpoint constants. There is **no** cancellation endpoint among them
(`transfer_completion`, `qa_complete` only).

✅ **CONFIRMED.** I could not break it.

---

## D — the 7 pending rows on Hydra PRD

Instrument: `mcp__wms2-hydra__execute_sql` (first query went through on the first attempt).

```sql
SELECT customerorder_id, count(*) AS pending_rows,
       count(*) FILTER (WHERE picktostockunit_id IS NULL) AS pts_null,
       (SELECT count(DISTINCT l3.customerorder_position_id)
          FROM customerorder_cancellation_log l3
         WHERE l3.customerorder_id = l.customerorder_id) AS distinct_positions_logged
FROM customerorder_cancellation_log l
WHERE reversal_required IS TRUE AND reversal_completed_at IS NULL
GROUP BY customerorder_id;
```

| customerorder_id | pending_rows | pts_null | distinct positions |
|---|---|---|---|
| 60861 | 4 | 4 | 4 |
| 159907 | 3 | 3 | 3 |

✅ 7 pending rows · 2 orders · both multi-position · **all 7 `picktostockunit_id` NULL**. **CONFIRMED**
on every conjunct.

Whole-table shape, for the record: 16 rows, 7 `reversal_required = true`, 9 `false`, **0 null**, 0
completed.

### ⚠ Addition that changes how the fix should be described

Grouping *all* 16 rows by order:

| order | rows | required=true | required=false |
|---|---|---|---|
| 60861 | 4 | 4 | 0 |
| 61120 | 1 | 0 | 1 |
| 126791 | 2 | 0 | 2 |
| **159907** | **3** | **3** | **0** |
| 180307 | 2 | 0 | 2 |
| 180310 | 2 | 0 | 2 |
| 180338 | 2 | 0 | 2 |

**No order on Hydra PRD mixes required and not-required rows.** Every order is uniformly one or the
other. The motivating scenario written into the `CancellationLogEntryDto` javadoc and into
`cancellationAction.vue` — "a partially-picked order that was then cancelled renders rows the
operator cannot act on" — is **structurally reachable but has never occurred on PRD**. That does not
make the guard wrong; the `reversalRequired` filter is still the correct invariant, and orders 61120 /
126791 / 180307 / 180310 / 180338 are exactly the all-unpicked case the screen must not offer. But
any claim that the change *fixes rows that exist today* would be false, and I would not let that
phrasing onto the ticket.

---

## E — `reversal_required` is `NOT NULL DEFAULT true`

**Instrument 1 — live PRD schema:**

```sql
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns WHERE table_name='customerorder_cancellation_log';
```
→ `reversal_required | boolean | is_nullable: NO | column_default: true`

**Instrument 2 — the Flyway source.** The cited file is real, and its path is worth stating precisely
because it is **not** under `db/migration/`:

```
src/main/resources/db/v1-to-v2-onboarding/schema/V2.1.12__add_cancellation_reversal_log_and_grant.sql:29
    reversal_required BOOLEAN NOT NULL DEFAULT true,
```

**The claim understates its own support.** There are *two* creation paths for this table and I
checked both — the second one was not mentioned:

```
src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:829
    reversal_required boolean DEFAULT true NOT NULL,
```

`grep -rn reversal_required src/main/resources/db/` returns those two lines and nothing else — **no
later migration ever relaxes the constraint.** So the guarantee holds on fresh-v2 tenants as well as
on v1-migrated ones, not just on Hydra.

✅ **CONFIRMED**, on three instruments (live schema, both migrations, and 0/16 null rows measured).

Consequently `entry.setReversalRequired(log.isReversalRequired())` cannot NPE from database-sourced
data, and the `boolean`-not-`Boolean` field declaration is sound.

---

## F — `amount_picked` semantics and blast radius

### The code claim: ✅ CONFIRMED

```java
// CancellationLogService.java:70
log.setAmountPicked(pickingPosition.getAmount());
```

and `PickingorderPosition` carries **both** fields as distinct columns:

```java
// PickingorderPosition.java:20,23
private BigDecimal amount = BigDecimal.ZERO;
private BigDecimal amountpicked = BigDecimal.ZERO;
```

with `PickingorderBusinessService.confirmPick` writing the *real* picked quantity to the other one
(`:881  pickingPosition.setAmountpicked(amountPicked);`). So `amount_picked` is populated from the
**ordered** amount. The field name is a lie.

### Independent DB proof, which I think is the strongest evidence available

Joining the log against the picking position on PRD:

| log rows | `log.amount_picked` | `pp.amount` | `pp.amountpicked` |
|---|---|---|---|
| the 7 pending | = pp.amount | — | = pp.amount |
| **the 9 not-required** | **= pp.amount** | — | **0.0000** |

Nine rows on PRD carry a non-zero `amount_picked` (2, 2, 3, 6, 6, 6, 6, 10, 2) while the position
they describe has `amountpicked = 0`. **Nothing was ever picked and the column says otherwise.** That
is a direct empirical confirmation independent of reading the code.

### The blast radius: ❌ **BROKEN — it is not display-only**

Exhaustive consumer set of `getAmountPicked()` / `amount_picked`
(`grep -rn "setAmountPicked\|getAmountPicked\|amountPicked\|amount_picked" src/main src/test`):

| Site | What it does | Display-only? |
|---|---|---|
| `CancellationReversalService.java:355` | `stockunitService.transferStock(stockUnit, log.getAmountPicked(), false, log.getPickfromlocationname(), …)` | **NO — this is the quantity of stock physically moved back to the source bin** |
| `CancellationReversalService.java:409` | `residue.getAmount().compareTo(amountBeforeTransfer)` — the residue-relock guard runs on the post-transfer amount, i.e. downstream of the value above | **NO — indirectly load-bearing** |
| `CancellationReversalService.java:406` | `LOG.info(…)` | yes (log line) |
| `CancellationReversalService.java:512` | `entry.setAmount(log.getAmountPicked())` → `CancellationLogEntryDto.amount` → the mobile screen's "Returned {{ pos.amount }} of …" | yes |
| `CancellationLogServiceUnitTest.java:141` | asserts the value, with the comment *"the amount to move back is snapshotted at cancel time"* | test |
| `CancellationReversalLockClearIntegrationTest.java:409,711` | fixtures | test |

Checked and **excluded** from the blast radius, so the boundary is drawn, not guessed:

- **Does not reach OMS.** The `ORDER_BATCH_REVERSAL_COMPLETED` payload sets
  `orderDto.setPositions(Collections.emptyList())` (`CancellationReversalService.java:447`) — the
  outbox message carries batch id, facility code and order unique id only.
- **No view, no native SQL.** `grep -rn amount_picked src/main` returns only the `@Column` mapping and
  a comment; the only other hits are the two DDL files.
- **Not exposed over Spring Data REST.** `RestConfiguration.java:891` sets
  `RepositoryDetectionStrategies.ANNOTATED`, and `CustomerorderCancellationLogRepository` carries no
  `@RepositoryRestResource`.

**So: the blast radius is the mobile display *plus the actual stock movement*.** On a short pick —
`confirmPick` sets `state = PICKED` and `amountpicked = <whatever was scanned>` with no requirement
that it equal `amount` (`PickingorderBusinessService.java:827-831` rejects only negative and zero) —
`completeReversal` would transfer the **ordered** quantity back into the source bin while only the
**picked** quantity is physically on the tote. That is an inventory over-return, not a cosmetic
label.

Live exposure today: **none among the 7 pending rows**, because for all 7 `pp.amount ==
pp.amountpicked` (fully picked). The divergence is latent, not active. Note also that the existing
test at `CancellationLogServiceUnitTest:141` **blesses the current behaviour** with a fixture where
`amount = 24` and `amountpicked` is never set — it cannot distinguish the two semantics, so it would
stay green through a fix and through the bug alike.

**This is out of scope for SBDEV-3323 and should not be fixed in this diff** — but "the blast radius
looks display-only" should not go on the ticket, and per the ticket policy this is a sub-T3 finding
that belongs on an existing ticket or as a proposal. I would rank it: real, latent, low current
probability, high consequence if it fires (silent stock inflation), cheap to fix
(`getAmountpicked()` with a fallback, plus a fixture where the two differ).

---

## G — AC-3: "completing a subset does not enqueue ORDER_BATCH_REVERSAL_COMPLETED"

❌ **Your suspicion is wrong. The test exists.**

`test/store/cancellationPartialReversal.spec.js:233` — a dedicated block of four:

```
describe('SBDEV-3323 — AC-3: a partial reversal must not tell OMS the order is reversed')
  ✓ does not drain the order when the operator completes only some of it
  ✓ does not drain the order when one of the selected positions is refused
  ✓ drains the order exactly once, on the request that completes the last pending position
  ✓ a straggler finished on a LATER visit still drains the order
```

The third is a **positive control** — and its own comment says why it is there: *"Without it the two
negatives above are satisfied by a store that never completes anything at all, which is the failure
mode a pure-negative pin cannot see."* That is precisely the vacuity trap, handled.

### What it actually pins, and the honest limit

The `enqueued` array is a **model** of the server's gate, built inside the test harness:

```js
const stillPending = server.positions.some(p => p.reversalRequired && !p.reversalCompletedAt)
if (!stillPending) enqueued.push('ORDER_BATCH_REVERSAL_COMPLETED')
```

I checked that model against the server and it is **faithful**:

```java
// CancellationReversalService.java:430
// Enqueue outbox when ALL positions on this CO are complete
List<CustomerorderCancellationLog> remaining = logRepository.findPendingReversals().stream() … 
if (remaining.isEmpty()) { … outboxService.enqueue(… ORDER_BATCH_REVERSAL_COMPLETED …) }
```
with `findPendingReversals()` = `reversalRequired = true AND reversalCompletedAt IS NULL`. The
harness's `$post` stub also correctly refuses to stamp an id outside that set, mirroring the server's
write query — so a store that submits junk ids cannot fake progress.

The spec file declares this limit itself, in a ⚠ block, and names the server-side authority. **I
verified that the named test actually exists** (a cross-reference to a non-existent test is a common
way for this kind of note to be wrong):

```
$ grep -rn completeReversalEnqueuesTheOmsNotificationOnlyWhenNothingIsLeftPending src/
src/test/java/net/aim_ai/wms/unit/service/CancellationReversalServiceUnitTest.java:220
```

It is pre-existing (not added by this diff) and it captures the `OutboxMessage` and asserts the
process type, aggregate id, destination URL and payload contents.

**Verdict: AC-3 is satisfied** — by a UI-side behavioural pin plus a pre-existing server-side pin on
the rule itself. The only caveat worth carrying to the ticket is the structural one the file already
states: no Jest test can observe the outbox, so the UI half pins *which requests the store issues*,
not the enqueue.

---

## H — audit of the 16-mutant sweep

### The number is wrong

`/tmp/claude-1000/mut3323/run.py` as it stands on disk contains **18** mutants (M1–M18; note the list
is out of order, M16 sits last). You reported 16. Either the script grew after the run you quoted or
the count was taken from a shorter list — **the "16" does not describe the script that exists.**

### Audit against the four classic failure modes

| Failure mode | Original script | Verdict |
|---|---|---|
| **Anchor never applied** | `if old not in src: … survivors.append(name+" (ANCHOR MISS)")`, plus a second `if open(path).read()==src` no-op check | ✅ **handled — this is the one it gets right.** I independently confirmed all 18 anchors are present in the pristine files **exactly once each** (no ambiguous multi-match either) |
| **Restore did not restore** | `restore()` copies and never verifies; the final `RESTORED:` line is *printed but never asserted* | ⚠ **unguarded.** In fact restore works — I verified by MD5 after every mutant — but the script would not have told you if it didn't |
| **Red from a different cause** | kill criterion is `if f and f>0` — **any** failing test counts, and only `names[0][:95]` is printed | ⚠ **unguarded.** A mutant that reds the pre-existing `cancellationErrorSurface.spec.js` for an unrelated reason would score as a kill. I verified independently that it never happens (below) |
| **Stale report file** | `os.remove(out)` before each run + `raise SystemExit` if absent | ✅ **handled** — the surefire-stale-XML analogue is covered |

Two further gaps the brief did not list but which matter more:

- **The baseline is never asserted green.** `base_f` is printed and then ignored. If the baseline had
  been red, *every* mutant would have reported KILLED and the run would have printed
  `SURVIVORS: none` — which is exactly the result you got. The output shape cannot distinguish the
  two cases.
- **The `.pristine` files' provenance is unverified.** The script never creates them from git; it
  copies *from* them on its first line. Had they been captured while a mutant was applied, the whole
  run would be measuring the wrong source. (They were fine — I checked.)
- **Scope.** `--testPathPattern=cancellation` runs **3 of 32 suites / 42 of 383 tests**. Notably
  `test/pages/workflow-reset-on-entry.spec.js` imports `cancellationAction.vue` and is **outside** the
  pattern. This can only understate kills, not overstate them.

### Independent re-run under a hardened harness

I re-implemented the sweep in my own worktree (`…/scratchpad/mobile-mut`, so the shared tree was never
touched), reusing the *same 18 mutant definitions* parsed straight out of `run.py`, but adding the
four guards it lacks: assert the baseline is green and abort otherwise; assert restore by MD5 after
every mutant; record **which spec file** each red came from and flag any kill not attributable to the
two SBDEV-3323 specs; and detect suite-level crashes (which surface as `numFailedTests == 0` and would
otherwise read as SURVIVED).

```
BASELINE: 42 passed, 0 failed, 3 suites, suite-level-failures=[]

KILLED  M1  drop the 401/403 abort                       (1 red in cancellationPartialReversal)
KILLED  M2  mixed result toasts success, not info        (1 red in cancellationPartialReversal)
KILLED  M3  aggregate success line fires with refusals   (1 red in cancellationPartialReversal)
KILLED  M4  navigate unconditionally                     (1 red in cancellationPartialReversal)
KILLED  M5  stillPending ignores reversalRequired        (1 red in cancellationPartialReversal)
KILLED  M6  batch whole selection into one request       (4 red in cancellationPartialReversal)
KILLED  M7  submit what was requested, unfiltered        (2 red in cancellationPartialReversal)
KILLED  M8  skip the post-loop re-read                   (1 red in cancellationPartialReversal)
KILLED  M9  abort the loop on any failure                (3 red in cancellationPartialReversal)
KILLED  M10 primitive swallows again                     (3 red in cancellationPartialReversal)
KILLED  M11 canComplete reverts to allChecked            (2 red in cancellation-partial-selection)
KILLED  M12 complete() submits every actionable row      (1 red in cancellation-partial-selection)
KILLED  M13 actionable stops filtering                   (6 red in cancellation-partial-selection)
KILLED  M14 remove the prune watcher body                (2 red in cancellation-partial-selection)
KILLED  M15 button ignores loading                       (1 red in cancellation-partial-selection)
KILLED  M17 loop completes every position regardless     (6 red in cancellationPartialReversal)
KILLED  M18 loop is a no-op                             (14 red in cancellationPartialReversal)
KILLED  M16 alreadyReversed hides completed rows         (1 red in cancellation-partial-selection)

RESTORED: 42 passed, 0 failed (baseline 42/0) -> OK
MUTANTS RUN: 18
SURVIVORS: none
NOT-ATTRIBUTABLE/WEAK: none
```

Script: `…/scratchpad/hardened_mut.py`.

**Every one of the 18 kills is attributable to one of the two new SBDEV-3323 spec files.** Not one
rides on the pre-existing `cancellationErrorSurface.spec.js`, and not one is a suite crash. The
baseline was green, so no kill is an artefact of a pre-existing red. Restore was verified by hash 19
times.

### Verdict on H: **PARTIAL**

- The **count** "16" is wrong — the script holds 18.
- The **result** is trustworthy, but *not because the script established it*: the script would have
  reported `SURVIVORS: none` just as confidently against a red baseline or against a kill caused by
  something unrelated, and it never checked its own restore. The claim is sound because I
  re-established it under a harness that does check those things — not because the original output
  proved it.

Worth carrying forward as a standing note: the four guards above cost about fifteen lines. The known
repo-wide lesson ("hand-rolled mutation harnesses lied 9×") is about exactly these gaps, and this
script closed two of the four.

---

## Things I did **not** verify

- The Vue component's *rendered* behaviour in a real browser — all component evidence here is
  `@vue/test-utils`, not a headless browser.
- Whether the server actually emits `reversalRequired` on the wire *from the controller* — the new
  `CancellationLogEntryDtoSerializationTest` exercises a locally-built `ObjectMapper`, not
  `WebConfigurer`'s. The test file states this limit itself. No MockMvc test of
  `OrderCancellationController`'s response body exists.
- Any concurrency behaviour of the one-request-per-position loop against a real database.
- The 9 `reversal_required = false` PRD rows were not traced back to confirm *why* each was never
  picked; I took `pp.amountpicked = 0` as sufficient.

---

## Appendix — API baseline delta

Run in `…/scratchpad/api-base` — a clean detached checkout of `origin/develop` `46bac87d`, with its
own `target/`, concurrently with nothing:

```
[WARNING] Tests run: 6595, Failures: 0, Errors: 0, Skipped: 1
[INFO] BUILD SUCCESS
```

| | tests | failures | skipped |
|---|---|---|---|
| baseline `46bac87d` | 6595 | 0 | 1 |
| with the change | 6600 | 0 | 1 |
| **delta** | **+5** | 0 | 0 |

+5 reconciles exactly against the new API tests — 2 added to
`CancellationReversalServiceUnitTest` (`detailReportsWhetherEachPositionNeedsAReversal`,
`detailKeepsReportingACompletedPositionAsHavingRequiredAReversal`) and 3 in the new
`CancellationLogEntryDtoSerializationTest`. **No existing API test was removed or disabled**: the
diff's single deletion in that file is the `@DisplayName` line on the class, and the test count moves
by exactly the number added.

The skipped count is 1 on **both** sides, which independently re-confirms the skip is pre-existing
rather than introduced.

