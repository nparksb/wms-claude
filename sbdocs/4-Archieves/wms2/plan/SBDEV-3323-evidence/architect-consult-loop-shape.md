# SBDEV-3323 — architecture consult: per-position reversal loop shape

Scope: one question, six parts, plus traps. Read-only pass over the mobile worktree at
`fb72f0d` and `wms2-api` `origin/develop`.

---

## Load-bearing facts I had to establish first (they change three of the six answers)

**F1 — `detail(coId)` is UNFILTERED.** `CancellationReversalService.detail` is
`logRepository.findByCustomerorderId(coId)` — no predicate. Compare `scanTote`, which filters
explicitly: `.filter(l -> l.isReversalRequired() && l.getReversalCompletedAt() == null)`. So the
`CancellationDetailDto.positions` the screen renders **already contains** already-completed rows and
`reversalRequired = false` rows. Two consequences: every `completeReversal` response is a *complete
snapshot*, not a delta (relevant to Q3); and the screen is today ticking and submitting rows the
server will never act on (relevant to T6/T7).

**F2 — the write path filters where the read path does not.**
`findPendingReversalsForUpdateByCustomerorderId` is `WHERE l.customerorderId = :customerorderId AND
l.reversalRequired = true AND l.reversalCompletedAt IS NULL`. A `positionId` for a non-required row
therefore matches nothing: **no refusal, no completion, silent no-op.**

**F3 — that same query is a multi-row pessimistic lock.** `@Lock(LockModeType.PESSIMISTIC_WRITE)`,
and the repository's own comment says `MULTI-ROW LOCK: locks every pending reversal row for the
order; the predicate is a FK plus two state columns, with no LIMIT`. Every POST in the loop takes
that lock over the whole order. (Q6, T4.)

**F4 — `cancellation.loading` is read by nothing.** `grep` over `pages/`, `components/`, `layouts/`
finds only `process`, `selectedOrder`, `pendingList`, `sourceFlow`. `layouts/default.vue` has no
overlay or progress binding. The flag is currently write-only. (Q6.)

**F5 — the primitive swallows.** `completeReversal`'s catch is `toastError(...)` and fall-through; it
resolves on failure. **A loop over it cannot distinguish success from failure.** The primitive must
change shape no matter where the loop lives.

---

## Q1 — where the loop lives

**Recommendation: a new store action `completeSelectedPositions({ coId, notes, positionIds })` owns
the loop and all aggregate reporting. `completeReversal` stays the single-position primitive, but is
re-shaped to *return an outcome* and to stop owning aggregate side effects.**

Why the store and not the component:

- The component is deliberately dumb — every method is a one-line dispatch or commit (`back()` is
  `this.$store.commit('cancellation/SET_PROCESS', '1_detail')`). The aggregate semantics you are
  about to write are the most defect-prone part of this ticket, and putting them in the `.vue` puts
  them where nothing currently tests them.
- The entire existing safety net for this flow is `test/store/cancellationErrorSurface.spec.js`,
  which calls actions **directly** with a stub context and no mount:
  `await actions.completeReversal.call(h.ctx, h.context, { coId: 159907, ... })`. A store action
  inherits that harness for free. A component loop needs `@vue/test-utils` plus a Vuex mock, which
  this suite does not set up for cancellation at all.

Required shape change to the primitive (F5). Return a result rather than rethrowing:

- success → `{ ok: true, positionId, order: result }`
- failure → `{ ok: false, positionId, status, message }`, where `message` is the value
  `apiErrorMessage` already computed (**may be `null`** — the handled-403 case).

**Do not rethrow.** Rethrowing forces the aggregate to re-derive the message, which re-implements the
null-403 rule at a second site — exactly the duplication SBDEV-3316 removed when it deleted the local
`backendMsg()` helper. Keep the rule in one place.

Move these two out of the primitive and into the aggregate:

- `this.$toast.success('Reversal complete.')` — otherwise a 4-position loop fires four success bars.
- `context.commit('SET_PROCESS', context.state.sourceFlow)` — otherwise the screen navigates away
  after the **first** position and the remaining three run against an unmounted view.

Also move `SET_LOADING` out (see Q6) and `SET_SELECTED_ORDER` out (see Q3).

Keep the primitive's payload shape `{ coId, notes, positionIds }` with `positionIds` an **array**,
rather than narrowing it to a scalar `positionId`. Three reasons: the server contract is a list; the
existing spec passes a list at five call sites and would otherwise need mechanical edits that hide
the real diff; and if a future decision reverts to one batched request, only the aggregate changes.
The aggregate passes `[id]` per iteration.

⚠ Regression check before you start: the existing spec asserts on `toast.error` and `SET_ERROR` for
`completeReversal`, and has **no** assertion on `toast.success` or `SET_PROCESS` (verified by grep),
so hoisting those two out leaves that suite green. Confirm that by running it, not by trusting this
paragraph — a green suite after a behaviour move is exactly the shape of a test that stopped
covering anything.

---

## Q2 — first refusal: stop, or continue?

**Recommendation: CONTINUE. The ticket's reading is correct, and the server makes it safe.**

- Each POST is its own `@Transactional(value = "tenantTransactionManager", rollbackFor =
  {BusinessException.class, FacadeException.class})` unit, and the refusals are thrown in a loop
  whose comment says `Pre-validate: fail atomically before any stock movement`. A refused request
  therefore leaves **no trace at all** — including the opportunistic
  `log.setPicktostockunitId(recovered); logRepository.save(log);` heal, which rolls back with it.
  There is no partial-write hazard created by continuing.
- Stopping at the first refusal reproduces the defect at a finer granularity: the operator must
  deselect and retry to discover, by bisection, which rows are bad. That *is* the bug being fixed.
- Iterate in the **rendered order** (`positions` order = `findByCustomerorderId` order). Do not sort
  or reorder: the operator's mental model of "the third one failed" has to match the list.

**One carve-out — abort, do not merely stop, on 401/403.** Those are not position-specific; they mean
"you cannot do this at all". Continuing produces N identical denials, and for a 403 with a `reason`
the axios interceptor has already toasted each one. Break out of the loop on `status === 401 ||
status === 403` and report what completed before it. This is the only reason the result object needs
`status` as well as `message`; a `message === null` test would catch the typed 403 but not a 401 that
carries a message.

---

## Q3 — final state: last successful response, or an explicit re-fetch?

**Recommendation: commit the last successful response as a floor, then ALWAYS dispatch
`fetchDetail(coId)` after the loop. Commit nothing from inside the loop.**

The last successful response is *usually* right, and F1 is why: `completeReversal` returns
`detail(coId)`, which is unfiltered, so each response carries every log row for the order with
`reversalCompletedAt` / `reversalCompletedBy` populated for the ones already done. A later response
strictly supersedes an earlier one, and a failed request changed nothing, so on the ordinary path
"last success wins" is accurate.

It is not accurate in three cases, and all three are live here:

1. **Transport failure after a server-side commit** — a dropped connection or timeout on a handheld
   over warehouse wifi. The client books the position as failed; the server has it completed. Only a
   re-read reconciles, and without one the screen invites a retry that reports a success for a no-op.
2. **Zero successes.** Nothing was ever committed, so the screen holds the pre-loop snapshot. It
   happens to be correct, but only by accident, and it is wrong the moment (3) applies.
3. **A concurrent operator on the same CO.** F3's lock serialises the *writes*; it does not make the
   DTO in this client's hand current.

Cost is one GET on a screen that just issued N POSTs. Reuse the existing `fetchDetail` action so the
error rendering stays the shared one rather than a fourth hand-rolled catch.

Commit the last successful response **before** the re-fetch, not instead of it: if the re-fetch
itself fails, `fetchDetail` leaves `selectedOrder` untouched, and you want that untouched value to be
the freshest thing you legitimately observed rather than the pre-loop snapshot.

Do **not** commit `SET_SELECTED_ORDER` per iteration. It buys nothing (no progress UI is bound to it)
and it re-renders the position list under the operator's fingers mid-flight, which is the direct
cause of the `checked` desync in T1.

---

## Q4 — what the operator sees after 3 successes and 1 refusal

**Recommendation: keep the per-position error toasts in the primitive; add exactly one aggregate line
in the aggregate.**

- **Per-position failures keep toasting via `toastError`.** That message names the position and the
  reason — e.g. `Reversal for position 159909 cannot be completed: no source stock unit could be
  resolved for the pick-to unit load (picktounitload_id=159979) — manual intervention required`. It
  is the whole point of SBDEV-3316 and the operator cannot act without it. Because the toast stays
  inside the primitive, **the null-`apiErrorMessage` rule is untouched** — `toastError` already
  guards `if (msg && toast && typeof toast.error === 'function')`, so a handled 403 stays silent and
  no new call site has to re-learn the rule.
- **Aggregate line, one per invocation:**
  - all selected succeeded → `success('Reversal complete.')` — reuse the exact existing string, do
    not churn wording the floor staff already recognise;
  - mixed → `info`, not `success` and not `error`: `3 of 4 positions reversed. 1 could not be
    completed.`;
  - **none succeeded → say nothing.** The per-position errors already fired; a fourth bar reading
    "0 of 4" under three red ones on a handheld is noise. This also covers the all-403 case, where
    the interceptor's typed denial is already the complete and correct message.

⚠ Two mechanical traps in that:

- `this.$toast.success('Reversal complete.')` is called **unguarded** today, while `toastError`
  guards the handle. Guard the new `info` call the same way (`toast && typeof toast.info ===
  'function'`). The existing harness stubs `{ success, error, info }`, so an unguarded call passes
  the suite and throws in any leaner harness — a false green by construction.
- Toast **stacking**: four failures produce four red bars plus nothing else. I am deliberately *not*
  adding message dedup in this ticket: dedup has to live in the aggregate, which means passing a
  `silent` flag into the primitive and splitting the SBDEV-3316 rule across two sites. The measured
  reality (Hydra PRD 2026-09-11, per the service comment: all 7 pending rows still resolve) says
  multi-failure is rare. Note it as a follow-up; do not pay for it now.

---

## Q5 — when should `SET_PROCESS(sourceFlow)` fire?

**Recommendation: only when nothing actionable remains pending for the CO, and decide that from the
post-loop re-fetched state — not from a client-side success count.**

```
const stillPending = (context.state.selectedOrder?.positions || [])
  .some(p => p.reversalRequired && !p.reversalCompletedAt)
if (!stillPending) context.commit('SET_PROCESS', context.state.sourceFlow)
```

- Navigating on a mixed result destroys the only screen that shows which rows failed, while the
  7-second error toast for those rows is still on display. The operator is bounced to the list and
  cannot re-read what went wrong.
- Staying is the correct affordance: with the new `reversalRequired` filter plus completed rows
  hidden, the screen re-renders as precisely the work that is left.
- The predicate must be the **server's**, not the client's. `failures.length === 0` answers a
  different question and gets the concurrency case wrong — if another operator finished the
  remainder, nothing is pending and we *should* leave, even though this loop had a failure.
- All-success is the same predicate's happy case, so there is one rule, not two.
- **If the post-loop re-fetch failed, do not navigate at all.** You do not know the remaining state,
  and leaving on an admittedly-stale snapshot is worse than staying with a red bar up.

---

## Q6 — `SET_LOADING`

**The flicker does not matter (F4: nothing reads the flag). The nesting does, and it is not cosmetic.**

If the primitive keeps its `finally { context.commit('SET_LOADING', false) }`, then in a loop the
flag goes **false between every request**. Anything you later gate on it — a spinner, a disabled
button — un-gates N−1 times mid-operation. That is a correctness bug in waiting, not a flicker.

**Recommendation: hoist `SET_LOADING` (and `SET_ERROR` reset) to the aggregate — true once at entry,
false once in `finally`. Remove both from the primitive.** A refcount would preserve standalone use
of the primitive, but the only caller is `cancellationAction.vue`'s `complete()` plus the spec, so a
counter is unearned complexity. Hoist.

**The change that actually matters is in the component, though.** `Complete Reversal` is gated only
by `:disabled="!allChecked"`. An N-request loop is visibly slow on a handheld and a second tap
re-enters it with the same `checked` array. Server-side that is idempotent (`if
(log.getReversalCompletedAt() != null) continue; // idempotent`), so no data corruption — but it
takes a second multi-row pessimistic lock (F3), re-toasts, and races its own re-fetch. Bind the
button: `:disabled="!canComplete || loading"`, with `loading` mapped from
`$store.state.cancellation.loading`. Hoisting the flag without binding it changes nothing, because
today nothing reads it.

---

## Traps

**T1 — the `checked` array, precisely (the one you asked about).**
`<v-checkbox v-model="checked" :value="pos.customerorderPositionId">` binds to component-local
`data() { return { checked: [] } }`, *not* to anything derived from `positions`. A new
`SET_SELECTED_ORDER` therefore does **not** clear it, and `:key="pos.logId"` is stable across a
re-fetch (log ids do not change), so Vue patches in place and ticks survive. That is the benign half,
and it is why the current code gets away with it.

The malignant half arrives **with the `reversalRequired` filter**. Once `positions` is filtered
(hiding non-required rows, and hiding or disabling completed ones), any re-render *shrinks* the list
while `checked` still holds ids that have left it:

- `allChecked` is `this.checked.length === this.positions.length`. With 4 ticked and 1 row left
  rendered, `4 === 1` is false — the button dead-locks OFF and there is nothing visible left to
  un-tick to recover.
- In the other direction: you must replace `allChecked` with something like `this.checked.length > 0`
  for partial selection to work at all, and then a second tap submits ids of rows already completed.
  Server-idempotent, but it inflates the "N of M" line, so the count lies.

Fix: prune `checked` against the rendered list, in a `watch` on `positions` (or on `order`) so the
list/scan re-entry paths are covered too, not only the loop's callback:

```
this.checked = this.checked.filter(
  id => this.positions.some(p => p.customerorderPositionId === id))
```

Assign a **new array**. Vue 2 cannot observe `this.checked.length = 0` or index assignment. And do
not "fix" the shrink by keying the `v-for` on the index — `:key="pos.logId"` is correct; an index key
makes the patch reuse the wrong checkbox instance when the filtered list shortens.

**T2 — the zero-selection case.** The server answers an empty list with `throw new
BusinessException("positionIds required")`, which is developer prose, not operator prose. Keep the
button disabled at zero selection rather than letting that string reach the floor.

**T3 — do not move `checked` into Vuex to make it testable.** The store's own SBDEV-2930 comment:
*"The whole Vuex root state is persisted to localStorage['vuex-mobile'], so this module's `process`
marker AND its working set outlive both the session and the OPERATOR — handhelds are shared between
shifts."* A half-ticked selection surviving a shift change is a worse bug than the one you are
fixing. Component data is the right side of that line. (`pages/cancellation.vue` commits
`resetState` in `created()`, which covers the store side on re-entry.)

**T4 — sequential `for...of` with `await`; never `Promise.all`, never `.forEach(async …)`.** By F3
each POST locks *every* pending row for the order, so parallel requests from one operator contend on
the same row set; the tenant `lock_timeout` bound applies per acquisition, so the failure mode is a
timeout that reads as a position-specific refusal — a misleading message pointing at innocent data.
`.forEach(async …)` additionally returns before the loop finishes, so the aggregate would report on
nothing.

**T5 — the outbox enqueue is deferred by a partial, not lost.** `completeReversal` enqueues
`ORDER_BATCH_REVERSAL_COMPLETED` only when `remaining.isEmpty()` — i.e. when no pending rows remain
for the CO, re-read inside that same transaction. Per-position, the enqueue rides whichever call
drains the last row. If the loop ends with a failure, nothing is enqueued (correct). Completing the
straggler on a **later visit** does fire it, because the condition is "none remain", not "this
request finished everything". Worth stating in the plan explicitly: a reviewer will ask whether
partial completion loses the OMS notification, and the answer is no.

**T6 — filter `reversalRequired = false` rows out of the submission, not just out of the view.** By
F2 such an id matches no row in the write query: silent no-op, no refusal, no completion. If they
stay in `positionIds`, they are counted as successes and the "3 of 4" line reports work that did not
happen. This is the second, load-bearing reason for the DTO field — the first is display.

**T7 — completed rows are already in `positions` today** (F1) and are currently ticked and re-sent,
surviving only on the server's `continue; // idempotent`. Decide explicitly whether the new screen
hides or merely disables them. If you **hide** them, T1's pruning stops being defensive and becomes
mandatory.

**T8 — `notes` is written once per position now.** The component sends `notes: ''` and the server
does `if (notes != null) { log.setReversalNotes(notes); }`. Per-position that write happens N times
instead of once. Harmless while notes is the empty string; if it ever becomes operator-entered, every
position silently gets the same text. Probably the intent — say so in the plan rather than discover
it later.

**T9 — a test-harness trap that produces a green test proving nothing.** The existing spec's context
is `{ commit: jest.fn(), state: { sourceFlow: '0_list' }, dispatch: jest.fn() }`. An aggregate that
calls `context.dispatch('fetchDetail', …)` gets a no-op there, so `context.state.selectedOrder` never
changes and the Q5 predicate is evaluated against `undefined` — `stillPending` is `false` and the
navigate fires unconditionally, in every test, regardless of the rule. Asserting merely that
`dispatch` was called with `'fetchDetail'` cannot see this. The test must stub `dispatch` to actually
mutate `context.state.selectedOrder`, and must include a **mixed** case whose expected outcome is
"does NOT commit SET_PROCESS". Mutation-check it: flip the predicate to `!failures.length` and
confirm the mixed case goes red.
