# SBDEV-3323 — code review (adversarial lane)

**Reviewer lane:** `review-3323` · **Date:** 2026-09-15 · **Mode:** read-only

**Trees reviewed**
- `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-mobile-ui/SBDEV-3323` — branch `bugfix/SBDEV-3323-rts-partial-position-completion`, base `origin/develop` `fb72f0d`
- `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3323` — branch `bugfix/SBDEV-3323-cancellation-dto-reversal-required`, base `origin/develop` `46bac87d`

**Counts:** 2 High · 5 Medium · 11 Low (one of which is a "no change needed" verdict) = 18 items.

---

## 0. Instruments and baselines (so the reds and greens below are attributable)

**Jest baseline.** Rather than mutate either worktree, I extracted `origin/develop` into a scratchpad
(`git archive origin/develop | tar -x`), symlinked the worktree's `node_modules`, and ran the suite:

| Tree | Suites | Tests | Result |
|---|---|---|---|
| `origin/develop` `fb72f0d` (baseline) | 30 | 355 | all green |
| branch as it stands | 32 | 383 | all green |

+2 suites, +28 tests, **0 regressions** in the 30 pre-existing suites. AC-5 is met.

**Maven.** Run in a scratchpad `rsync` copy of the api worktree, not in the worktree itself (a
concurrent `mvn` from another session was live on this machine — `pgrep` confirmed a
`launcher.Launcher clean test` under a different scratchpad — and this repo has a known
false-red mode when two builds share one tree).
`mvn -o test -Dtest='CancellationLogEntryDtoSerializationTest,CancellationReversalServiceUnitTest'`
→ **27 tests, 0 failures, 0 errors** (24 + 3). BUILD SUCCESS.

**Mutation sandbox.** Same technique: `origin/develop` archive + the four changed/new files copied
over it, symlinked `node_modules`. Confirmed green at 32/383 before mutating, restored between
mutants. **Every "survives" below was executed, not reasoned about.** Nine JS mutants and two Java
mutants were run; 6 JS mutants survived, 2 JS and both Java mutants were killed.

> The 16-mutant sweep the author ran is real and its kills hold up. What follows is the complement:
> mutants the sweep did not contain.

---

## HIGH

### H-1 — Nothing pins that the component routes through the loop. The core of AC-1/AC-2 is unprotected, and the revert passes 383/383.

`components/cancellation/cancellationAction.vue`:

```js
    complete() {
      this.$store.dispatch('cancellation/completeSelectedPositions', {
```

and the test helper that is supposed to grade it,
`test/components/cancellation-partial-selection.spec.js`:

```js
/** The submitted ids, whichever action the component ends up dispatching. */
function submittedIds(dispatched) {
  const call = dispatched.find(d => d[0] === 'completeSelectedPositions' || d[0] === 'completeReversal')
  return call ? call[1].positionIds : null
}
```

**Why it is wrong.** The `|| 'completeReversal'` arm was the right call while this was a TDD-gate test
written before the store existed. Now that both actions exist it makes the helper blind to the
distinction the ticket is *about*. I ran the mutant:

```
sed -i "s#dispatch('cancellation/completeSelectedPositions'#dispatch('cancellation/completeReversal'#" \
    components/cancellation/cancellationAction.vue
→ Test Suites: 32 passed, 32 total · Tests: 383 passed, 383 total
```

That mutant is not a strawman — it is **the pre-fix behaviour, re-landed**. One request carrying the
whole ticked subset, against a method annotated
`rollbackFor = {BusinessException.class, FacadeException.class}` whose own pre-validate loop is
commented *"fail atomically before any stock movement"*. One refusal rolls back every ticked
position. AC-2 ("a refused position is shown as refused … and the others still complete") is dead,
and the whole suite is green. The store suite cannot catch it because it calls
`actions.completeSelectedPositions` directly; the component suite cannot catch it because of the
`||`.

**Fix.** Drop the fallback arm and assert the action *name*:

```js
function submittedIds(dispatched) {
  const call = dispatched.find(d => d[0] === 'completeSelectedPositions')
  return call ? call[1].positionIds : null
}
```

plus one explicit case in the first `describe`:

```js
it('routes through the per-position aggregate, not the single-request primitive', async () => {
  const { wrapper, dispatched } = build([position(P1), position(P2), position(P3)])
  wrapper.vm.checked = [P1, P3]
  await wrapper.vm.$nextTick()
  wrapper.vm.complete()

  expect(dispatched.map(d => d[0])).toEqual(['completeSelectedPositions'])
})
```

That `toEqual` (not `toContain`) is the load-bearing part: it fails on the revert *and* on a
belt-and-braces implementation that dispatches both.

---

### H-2 — AC-3 is **not met by this diff**. Do not claim it.

The author's suspicion is correct, and I can state the boundary precisely.

- Nothing on the UI side models, references, or asserts the OMS enqueue. `grep -n` for
  `ORDER_BATCH_REVERSAL_COMPLETED`, `outbox`, `enqueue`, or `notif` across
  `test/store/cancellationPartialReversal.spec.js` and
  `test/components/cancellation-partial-selection.spec.js` → **zero hits**. The store harness's fake
  server stamps `reversalCompletedAt` and returns a detail DTO; it has no notion of a notification at
  all, so no assertion in either new file *could* be about AC-3.
- The only coverage is two **pre-existing, untouched** tests in
  `CancellationReversalServiceUnitTest`:
  `completeReversalMovesStockBackToSourceLocation` (`verify(outboxService, never()).enqueue(any())`
  with a sibling row left pending) and
  `completeReversalEnqueuesTheOmsNotificationOnlyWhenNothingIsLeftPending`. Neither appears in
  `git diff origin/develop`, and neither exercises the per-position loop — they call
  `service.completeReversal` once.

So: **the server behaviour is correct and was already pinned; this diff adds no AC-3 coverage and the
new per-position calling pattern is not graded against it at all.** The ticket asked to "pin it from
the UI side"; that has not been done.

I also verified the server behaviour independently rather than taking it on trust
(`CancellationReversalService.java`):

```java
        List<CustomerorderCancellationLog> remaining = logRepository.findPendingReversals().stream()
            .filter(l -> l.getCustomerorderId().equals(coId))
            .collect(Collectors.toList());
        if (remaining.isEmpty()) {
```

— evaluated per request. Under the loop, calls 1..n-1 see a non-empty `remaining` and enqueue
nothing; the call that clears the last pending row enqueues exactly once. Correct, including the case
where the unselected remainder is all `reversalRequired = false` (those rows are not in
`findPendingReversals()`, so the enqueue correctly fires).

**Fix — the missing assertion.** Teach the store harness's fake server the one rule it is missing,
then assert on it. In `harness()`:

```js
  const enqueued = []
  // Mirrors CancellationReversalService: the notification fires when, and only when, no row on this
  // order is still pending after the write. Modelling it here is what lets the UI side grade AC-3;
  // without it the harness cannot distinguish a partial from a full completion at all.
  const notifyIfNothingPending = () => {
    if (!server.positions.some(p => p.reversalRequired && !p.reversalCompletedAt)) {
      enqueued.push('ORDER_BATCH_REVERSAL_COMPLETED')
    }
  }
```

called at the end of the `$post` handler, returned from `harness`, and graded by two cases:

```js
it('completing a SUBSET does not notify OMS — positions are still pending', async () => {
  const h = harness([position(P1), position(P2), position(P3)])
  await run(h, [P1])
  expect(h.enqueued).toEqual([])
})

it('notifies OMS exactly once, on the request that clears the last pending position', async () => {
  const h = harness([position(P1), position(P2), position(P3)])
  await run(h, [P1, P2, P3])
  expect(h.enqueued).toEqual(['ORDER_BATCH_REVERSAL_COMPLETED'])
})
```

The second is the one that earns its keep: it fails if the loop is ever replaced by something that
re-posts the full set, and it pins "exactly once" rather than "at least once".

⚠ State the blind spot in the comment when you add it: this is a **model** of the server rule, not
the server. It cannot catch a change to `findPendingReversals()`'s filter. That is what the two
server tests are for, and they should be named in the comment so the pair is discoverable.

---

## MEDIUM

### M-1 — After a 401/403 break, the summary line's arithmetic is wrong: unattempted positions are counted nowhere.

`store/cancellation.js`:

```js
          if (outcome.status === 401 || outcome.status === 403) break
```

then

```js
        toastLine(this.$toast, 'info',
          `${completed.length} of ${selected.length} positions reversed. `
          + `${refused.length} could not be completed.`)
```

**Why it is wrong.** The `break` is right — I agree with it and with the reasoning. But `refused`
then holds exactly one id while the positions after it were never attempted. Select three, get one
success and then a 403, and the operator reads:

> "1 of 3 positions reversed. 1 could not be completed."

1 + 1 ≠ 3. The operator is left to infer the fate of the third, and the most natural reading — that
it is accounted for somewhere — is wrong. This is the case where the operator most needs an accurate
count, because a 403 means they must hand the order to someone else and say what is left.

Not covered: the existing mixed-result test uses a 422, which does not break, so `completed + refused
=== selected` holds there and the defect cannot appear.

**Fix.** Count what is not done, rather than what was refused:

```js
      const notCompleted = selected.length - completed.length
      ...
        toastLine(this.$toast, 'info',
          `${completed.length} of ${selected.length} positions reversed. `
          + `${notCompleted} could not be completed.`)
```

and add a case with a 403 mid-selection asserting the line contains `'1 of 3'` and `'2 could not'`.

---

### M-2 — The mixed-result assertion is tautological: swapping the two counts passes.

`test/store/cancellationPartialReversal.spec.js`:

```js
    const line = h.toast.info.mock.calls[0][0]
    expect(line).toContain('2')
    expect(line).toContain('3')
```

**Why it is wrong.** Neither assertion says which number means what. Executed mutant — swap
`completed.length` and `refused.length` in the template literal:

```
→ Tests: 383 passed, 383 total
```

The mutated build tells the operator *"1 of 3 positions reversed. 2 could not be completed."* when 2
succeeded and 1 failed — i.e. it inverts the only number the operator acts on — and the suite is
green. This is precisely the class the author asked me to hunt for in point 7: a plausible wrong
implementation not in the sweep.

**Fix.** Assert the sentence, not its digits:

```js
    expect(line).toContain('2 of 3 positions reversed')
    expect(line).toContain('1 could not be completed')
```

(If M-1 is fixed first, that second string becomes the `notCompleted` count and the two findings are
covered by one pair of assertions.)

---

### M-3 — The navigate predicate the code's own comment calls load-bearing is unpinned.

`store/cancellation.js`:

```js
      const stillPending = ((context.state.selectedOrder && context.state.selectedOrder.positions) || [])
        .some(p => p.reversalRequired && !p.reversalCompletedAt)
      if (!stillPending) context.commit('SET_PROCESS', context.state.sourceFlow)
```

The comment above it explicitly rejects the alternative — *"`refused.length === 0` answers a
different question and gets the concurrent-operator case wrong"*. Executed mutant, substituting
exactly that:

```
if (refused.length === 0) context.commit('SET_PROCESS', context.state.sourceFlow)
→ Tests: 383 passed, 383 total
```

**Why it matters.** Three tests appear to cover this area, and none of them separates the two
predicates: in *"stays on the action screen while any position is still pending"* both say stay; in
*"leaves the action screen once nothing actionable is left"* and *"a position needing no reversal does
not by itself hold the screen open"* both say go. The distinguishing case — the one the comment
describes — is never constructed. A comment asserting a behaviour that no test can detect is how this
regresses silently.

**Fix.** Add the case the comment describes: a refusal in the loop, but a concurrent operator has
completed the remainder by the time the re-read lands, so the screen must still close.

```js
it('closes the screen when the SERVER says nothing is pending, even though this loop had a failure', async () => {
  // The concurrent-operator case the predicate exists for: P2 refuses us, but someone else finished
  // it before our re-read. Nothing is pending, so this screen has no further work and must close.
  // A `refused.length === 0` test strands the operator on a screen with no actionable row on it.
  const h = harness([position(P1), position(P2)],
    { [P2]: problemDetail(422, `Reversal for position ${P2} cannot be completed: …`) })
  h.axios.$get = jest.fn(() => {
    h.server.positions.forEach((p) => { p.reversalCompletedAt = '2026-09-15T11:30:00Z' })
    return Promise.resolve({ customerorderId: CO_ID, positions: h.server.positions.map(p => ({ ...p })) })
  })

  await run(h, [P1, P2])

  expect(h.state.process).toBe('0_list')
})
```

Mutation-check it against `refused.length === 0` before trusting it.

---

### M-4 — A `200` is read as "this position was reversed". The server returns `200` for a position it did not touch.

`store/cancellation.js`:

```js
      const order = await this.$axios.$post(`/cancellation/${coId}/complete`, { notes, positionIds })
      return { ok: true, positionIds, order, status: null, message: null }
```

**Why it is wrong.** I traced `completeReversal` on the server. Both loops are:

```java
            if (!positionIds.contains(log.getCustomerorderPositionId())) continue;
```

over `findPendingReversalsForUpdateByCustomerorderId(coId)`. There is **no error path for a
positionId that matches no row** — the only guard is `positionIds == null || positionIds.isEmpty()`.
So a request naming a position that is no longer pending moves no stock, stamps nothing, and returns
`200` with the refreshed detail. The client counts it as `completed`.

The `selected` filter is the stated defence, and its comment claims it prevents exactly this
("*Left in, it would be counted as a success and inflate the 'N of M' line into reporting work that
never happened*"). But the filter reads `context.state.selectedOrder`, i.e. **local** state — so it
can only catch the case the client already knows about, and is structurally unable to catch the case
that actually produces the false success: another operator, or another handheld, completing the row
between this screen's last read and this tap. Two operators on one cancelled order is not exotic;
it is the scenario that motivated the "concurrent operator" reasoning in M-3's own comment.

Worst form: operator B completes everything, operator A taps Complete on a 2-row selection, both
POSTs no-op, and A is told **"Reversal complete."** having moved nothing.

This is the shape the repo has been bitten by repeatedly — reading a transport-level success as a
business-level outcome.

**Fix.** The response body is the refreshed detail; grade against it rather than against the status
code:

```js
  async completeReversal(context, { coId, notes, positionIds }) {
    context.commit('SET_ERROR', null)
    try {
      const order = await this.$axios.$post(`/cancellation/${coId}/complete`, { notes, positionIds })
      // A 200 is NOT proof this position moved. completeReversal's two loops both `continue` on an
      // id that matches no pending row and there is no unmatched-id error path, so a request naming a
      // row another operator already finished no-ops and still answers 200. The returned detail is
      // the server's own view — read the stamp out of it instead of trusting the status.
      const applied = ((order && order.positions) || []).some(p =>
        positionIds.indexOf(p.customerorderPositionId) !== -1 && p.reversalCompletedAt)
      return { ok: applied, noop: !applied, positionIds, order, status: null, message: null }
    } catch (error) {
```

and give a `noop` its own bucket in the aggregate so it is neither counted as reversed nor toasted as
a refusal ("N already completed by someone else" is the honest line). Pin it with a harness case
where the fake server marks the row completed *before* the POST.

If you would rather not widen the outcome shape in this ticket, the minimum acceptable alternative is
to **stop claiming the filter closes this** — rewrite the `selected` comment to say it covers only
locally-known non-actionable ids and that a concurrently-completed row is still counted as a success
— and file the rest on the existing ticket.

---

### M-5 — AC-2's "shown as refused with its reason" is satisfied only by a toast that expires, and the one piece of durable state is unconditionally wiped.

Three things compose here:

1. The refusal reaches the operator only as `toastError(...)`, which `plugins/toast.js` renders for
   `API_ERROR_TOAST_DURATION` (7 s) and then destroys. No row-level refused state exists; a refused
   row simply remains in `actionable`, ticked, visually identical to one never attempted.
2. `state.error` would be the natural durable half, and the aggregate does commit it per position —
   but the post-loop `await context.dispatch('fetchDetail', { coId })` starts with
   `context.commit('SET_ERROR', null)`, so **after any partial, `state.error` is guaranteed null.**
3. `grep -rn "cancellation.error"` across `pages components layouts store` → **zero readers**, so
   `SET_ERROR` is write-only in this module today and nothing surfaces it anyway.

With two or more refusals the toasts stack and expire together; 7 seconds later the screen shows N
identical-looking selectable rows and no record of which ones the server refused or why. The messages
carry `picktounitload_id` values the operator may need to quote to support.

**Why I am calling it Medium rather than Low.** It is an acceptance criterion as written on the
ticket, and the diff does not meet the "shown as refused" half of it — only the "with its reason"
half, transiently. If the plan deliberately scoped this to toast-only, that is Nam's call, but it
should be recorded as a scoped-out AC rather than reported as met.

**Fix (smallest form that meets the AC).** Return the refused ids up from the aggregate into
component-visible state and render them:

- keep a `refusedPositions` map (`positionId -> message`) in the module state, committed by the
  aggregate after the loop and cleared on the next `complete()` tap and on `resetState` (it is
  already covered automatically by the `initialState()` factory pattern);
- in `cancellationAction.vue`, give a refused row a `v-list-item-subtitle` carrying its message and
  an error colour;
- move the `SET_ERROR(null)` out of the shared `fetchDetail` prologue, or have the aggregate
  re-commit the last refusal after the re-read.

---

## LOW

*(Per the repo's standing rule these are fixed in the same pass.)*

### L-1 — The fail-open arm is never exercised. (Answers the author's point 2, direction question.)

```js
    const selected = known.length
      ? requested.filter(id => known.some(p => …))
      : requested
```

Executed mutant — force the filter branch unconditionally (i.e. fail **closed** when the order is not
loaded): **383 passed**. Every harness seeds `selectedOrder`, so the `: requested` arm is dead in
test.

**Verdict on the direction: OPEN is right.** Failing closed would silently submit nothing, and the
`selected.length === 0` path says nothing at all (L-5) — so a fail-closed bug would present as "the
button does nothing", the single hardest defect shape to report from a warehouse floor. And the
server is safe either way: an unmatched id no-ops.

**Fix.** One case with `state.selectedOrder = null` asserting the requested ids are still posted.

### L-2 — `if (!refreshed) return` is unpinned.

Executed mutant — replace with `if (false) return`: **383 passed**. No test makes `$get` reject, so
nothing grades "do not navigate on an unknown state". Add a case where `$get` rejects after a
successful loop and assert `state.process` is still `'2_action'`. (This also exercises `fetchDetail`'s
new `return false`, which is otherwise only graded through the happy path.)

### L-3 — The `latestOrder` floor commit is unpinned.

```js
      if (latestOrder) context.commit('SET_SELECTED_ORDER', latestOrder)
```

Executed mutant — delete the line: **383 passed**. Its entire purpose is the case where the re-read
then fails, which no test constructs. The L-2 test above covers this too if it also asserts
`state.selectedOrder` reflects the last successful POST rather than the pre-loop snapshot.

### L-4 — The `toastLine` guard is untested, and its javadoc overstates why it is there.

```js
function toastLine(toast, level, message) {
  if (toast && typeof toast[level] === 'function') toast[level](message)
}
```

Executed mutant — drop the guard: **383 passed**. Every harness in the repo stubs `success`, `error`
and `info`, so the javadoc's claim that the unguarded form *"throws in one that does not"* is
untested in both directions. The guard itself is correct and matches `toastError`'s existing shape —
keep it — but either add a case passing `$toast: undefined` (or `{}`) and asserting the action still
resolves, or trim the javadoc to "guarded for symmetry with `toastError`". Asserting a defence that
nothing exercises is the pattern that produced this repo's `never()`-audit findings.

`$toast.info` itself is fine — I checked: `plugins/toast.js` wraps `info`, and there are 21 existing
`$toast.info` call sites. No defect there.

### L-5 — `selected.length === 0` produces total silence.

If the filter empties the selection, the loop body never runs, `completed` and `refused` are both
empty, so no aggregate line is toasted, and the only observable effect is a re-read. The operator
tapped a button and nothing happened, with no message.

I checked reachability from the component and it is currently closed: `pages/cancellation.vue` commits
`cancellation/resetState` in `created()` (so no stale persisted `selectedOrder` from a previous shift
survives), `complete()` passes `this.order.customerorderId` so `coId` and `known` are always the same
order, and `checked ⊆ actionable` holds at tap time because the prune watcher flushes on a microtask
while the click handler is a macrotask. So this is defence-in-depth, not a live bug — but the failure
mode is unattributable, which is the kind this repo pays for later.

**Fix.** An explicit early branch:

```js
    if (!selected.length) {
      toastLine(this.$toast, 'info', 'Nothing left to reverse for this order.')
      await context.dispatch('fetchDetail', { coId })
      return
    }
```

### L-6 — The serialization test's javadoc names a mapper it does not build.

`CancellationLogEntryDtoSerializationTest`:

```java
    /** Wired the way {@code WebConfigurer} builds the MVC mapper, minus the date serializers this DTO's flags do not use. */
    private final ObjectMapper mapper = new Jackson2ObjectMapperBuilder().build();
```

`WebConfigurer.objectMapper()` actually builds:

```java
        ObjectMapper mapper = new ObjectMapper();
        mapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
        mapper.setDateFormat(new StdDateFormat().withColonInTimeZone(true));
        mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
        mapper.setSerializationInclusion(Include.NON_NULL);
        mapper.registerModule(new JavaTimeModule());
        mapper.registerModule(wmsTimestampModule());
```

— a bare `ObjectMapper`, not a builder, **with `Include.NON_NULL`** (also set globally:
`application.properties:14` `spring.jackson.default-property-inclusion=NON_NULL`, mirrored at
`src/test/resources/application.properties:17`).

**Consequence.** The test's mapper carries no inclusion setting at all, so it is blind to the
inclusion axis. The three assertions still hold under the real mapper today (a primitive `boolean` is
never null, and `NON_NULL` does not drop `false`) — so this is not a false green *now*. But a change
of `default-property-inclusion` to `NON_DEFAULT` would drop `"reversalRequired": false` from the
wire, the client would read `undefined`, every never-picked row would silently become
indistinguishable from an actionable one — and all three tests stay green, while the javadoc tells
the next reader this file grades the MVC mapper.

**Fix.** Two lines, and correct the javadoc:

```java
    /** Built the way {@code WebConfigurer.objectMapper()} builds the MVC mapper: a bare ObjectMapper
     *  with Include.NON_NULL (also the global default), minus the date serializers these flags do not use. */
    private final ObjectMapper mapper = new ObjectMapper()
            .setSerializationInclusion(JsonInclude.Include.NON_NULL);
```

The `false`-is-emitted test then genuinely grades inclusion rather than asserting it against a mapper
that could not have dropped it.

The javadoc's honesty about the surviving `Boolean`-widening mutant is good and correct — I confirmed
Jackson's `BeanUtil.okNameForIsGetter` accepts `isXxx` for both `Boolean` and `boolean`, so the author's
correction of their own earlier guess holds. Keep that paragraph.

### L-7 — The partial-result summary is the shortest-lived toast on screen, and it is the only one that says how many succeeded.

`toastLine` passes no options, so the info toast takes `nuxt.config.js`'s global `duration: 3500`,
while the per-position error toasts that provoked it take `API_ERROR_TOAST_DURATION` (7000). The
summary therefore vanishes at 3.5 s while the errors are still up — the inverse of the priority. The
7 s value exists in this repo because of a literal report that "the red bar disappears too fast to
screenshot"; the same argument applies with more force to a line the operator must act on.

**Fix.** `toastLine(this.$toast, 'info', line, { duration: API_ERROR_TOAST_DURATION })`, threading an
options argument through the helper.

### L-8 — A network failure does not break the loop.

The `break` fires on `outcome.status === 401 || 403`. A dropped connection gives `error.response ===
undefined`, so `status` is `null` and the loop continues through every remaining position, each
waiting out the axios timeout. On a handheld out of Wi-Fi range that is N sequential timeouts; and
because `plugins/toast.js` suppresses duplicate `(type, message)` pairs within 2000 ms, the N
identical "Failed to complete reversal." toasts collapse to roughly one — so the operator sees a
single error for N failures, and only the count line tells the truth.

**Fix.** Break on a transport failure too, and say so:

```js
          // No response at all = the network, not this position. The next N requests will fail the
          // same way, one timeout each, and the toast de-duplicator collapses them into one message.
          if (outcome.status === null || outcome.status === 401 || outcome.status === 403) break
```

⚠ Check this against M-1's count fix — with more break conditions, `selected.length -
completed.length` becomes the only honest denominator.

### L-9 — Positional button lookup in the component spec.

```js
    const completeBtn = wrapper.findAll('button').at(2)
```

Grades whichever button is third. Adding a button ahead of Complete silently moves the assertion onto
the wrong element, and a `disabled` attribute check that lands on "Back" would still be green.
**Fix.** `wrapper.findAll('button').filter(b => b.text().includes('Complete Reversal')).at(0)`.

### L-10 — The re-read test does not pin ordering.

```js
    expect(h.axios.$get).toHaveBeenCalledWith(`/cancellation/${CO_ID}/detail`)
```

An implementation that re-read *before* the loop — which would defeat the entire point, since the
navigate decision would then be made on pre-loop data — passes this. **Fix.** Assert the call order,
e.g. by recording a single ordered log of `$post`/`$get` calls in the harness and asserting the `$get`
is last.

### L-11 — Point 5 (`notes` written once per position): verified harmless. No change needed.

The service stamps `log.setReversalNotes(notes)` inside the per-log write loop, gated on
`positionIds.contains(...)`. Under the old single request with N ids, N rows each received `notes`.
Under the loop, N requests each stamp exactly one row with the same value. **The set of rows written
and the values written are identical**, for any `notes` value, not just `''`. Nothing to handle now,
and nothing to handle when `notes` becomes non-empty either.

---

## Verdicts on the seven specific questions

| # | Question | Verdict |
|---|---|---|
| 1 | AC-3 pinned? | **No — see H-2.** Confirmed unmet by this diff; the only coverage is the two pre-existing untouched server tests. The missing assertion is written out in H-2. Do not claim AC-3. |
| 2 | `selected` filter vs stale state | **OPEN is the right direction** (L-1), but the stale-**but-present** case is *not* handled and is the one that actually produces a false success — **M-4**. The comment currently claims otherwise. Fail-open arm is also untested (L-1). |
| 3 | `SET_LOADING` nesting | **Your judgement is right — harmless.** Mechanism: `fetchDetail`'s `finally` queues Vue's flush (microtask A) before the `await` continuation resumes the aggregate (microtask B), so a re-render with `loading === false` genuinely can occur before the aggregate's last statements. But everything after that `await` is synchronous, no user input can be delivered inside a microtask gap, and the aggregate's own `finally` sets the flag to the same `false` — so the window is unobservable and unexploitable. No stuck-`true` path exists either: the pre-`try` filter cannot throw, and neither inner dispatch ever rejects. Not worth restructuring. |
| 4 | The prune `watch` on `actionable` | **Fires more often than you think, and that is fine.** Because `actionable` returns an Array, Vue 2's `Watcher.run` takes the `isObject(value)` branch and invokes the callback on *every* `selectedOrder` change, identity-equal result or not — not only when the list shrinks. Harmless: the body is idempotent and guarded by the length check. **No re-entrancy** — `checked` is not a dependency of `actionable`. **No lost tick** — the user watcher's id is lower than the render watcher's, so the prune lands in the same flush queue *before* re-render; and the tap path is a macrotask, so the microtask flush has always completed by the time `complete()` reads `this.checked`. Not `immediate`, correctly: `checked` starts `[]` and `pages/cancellation.vue` commits `resetState` in `created()`. |
| 5 | `notes` per position | **Harmless, and harmless for any value of `notes`, not just `''`.** Nothing to do — L-11. |
| 6 | SBDEV-3316 contract | **Intact.** The null-`apiErrorMessage` rule stays single-sited in `completeReversal`'s catch; `toastLine` only ever carries client-composed strings, never a server message; all 14 `cancellationErrorSurface.spec.js` cases pass unchanged, and they call `completeReversal` directly so the reshape does not move out from under them. One related-but-separate consequence is **M-5**: the post-loop `fetchDetail` unconditionally clears `SET_ERROR`, so the durable half of the error surface is always null after a partial. |
| 7 | Vacuous assertions | **Found: M-2** (counts swap, suite green) — the requested "plausible wrong implementation you did not mutate". Plus **H-1** (the `||` fallback in `submittedIds`), **M-3**, **L-1/L-2/L-3/L-4** (six executed mutants surviving), and **L-10** (ordering unpinned). |

## What is solid

Stated for balance, since the above is all findings:

- The Java half is genuinely well-pinned. Both mutants I ran against the mapping — hardcoded `true`,
  and `reversalRequired := (completedAt == null)` — **fail the build**, each with a message naming the
  position. The two-flags-answer-different-questions test is the right test and it earns its keep.
- `isReversalRequired()` on the entity is `reversalRequired != null && reversalRequired`, so the
  primitive DTO field cannot NPE on a null column; the `NOT NULL DEFAULT true` claim checks out at
  `V2.2.00__base_v2_schema.sql:829`.
- I verified the field reaches the screen on **all three** entry paths, not just `detail()`:
  `scanTote` delegates to `detail(coId)` and `initiateReversal` returns `detail(coId)`, both through
  the same `toDetailDto`. There is no path onto the action screen that would see `reversalRequired`
  undefined and render an empty selectable list.
- The one-request-per-position decision is correct and the `rollbackFor` reasoning behind it is
  accurate — I read the annotation and both loops.
- The `break`-on-403 decision is correct (the interceptor at `plugins/axios.js:289` does toast per
  denial); only its effect on the count is wrong (M-1).
- Mutant "unqualified success toast on a MIXED result" is **killed** — that assertion does work.
- Jest: no regressions against a properly-derived `origin/develop` baseline (30/355 → 32/383).
