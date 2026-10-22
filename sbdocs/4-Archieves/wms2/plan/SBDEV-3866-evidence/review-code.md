# SBDEV-3866 — independent code review (lane: code-reviewer)

- Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-mobile-ui/SBDEV-3866`
- Commit under review: `b576156` on `origin/develop` `f51dc6c`
- Files: `store/cycleCount.js` (+5), `test/store/cycleCountRecountMismatch.spec.js` (+61)
- Server contract read from `v2/wms2-api` `origin/develop`: `CycleCountLosController.java:113-151` (`/countSingleUnitLoad`), `:153-178` (`/recountSingleUnitLoad`), `MobileCycleCountService.java:153-198`, `:205-…`
- Evidence run (read-only): new spec 3/3 pass; full jest suite **57 suites / 755 tests, 0 failures**.

## Stage 1 — spec compliance

The ticket's defect is fixed as stated: a `/countSingleUnitLoad` answer carrying `stockUnit` (server's "differs expected") is no longer toasted as success and no longer resets to `21_unitLoad`. Pre-fix, the `else` arm would have fired `toast.success` on that answer, so spec test 1 fails on the parent commit (reasoned from the diff; no mutation run in the worktree, per instructions).

The arm mirrors `countSingleUnitLoad` (`store/cycleCount.js:217-221`) **only partially**: in the first-count flow the component commits `setCountData(data)` before dispatching (`components/cycleCount/single/countUnitLoad.vue:59`). The recount component never does (`components/cycleCount/single/recountUnitLoad.vue:55-62`), and the new arm doesn't either. That gap is finding H1.

## Response shape (Q1a) — OK

Server mismatch map = `{stockUnit, itemData, client, unitLoad, location, message}` (`CycleCountLosController.java:133-138`), the same keys `scanSingleUnitLoad` returns (`:94-98`). `recountUnitLoad.vue:6-10` reads `stockUnitInfo.unitLoad.labelid / client.name / itemData.itemNr / itemData.name / location.name`, and `:56-57` reads `stockUnitInfo.stockUnit` and `stockUnitInfo.unitLoad.labelid`. Committing `result` whole into `stockUnitInfo` is therefore correct. The next submit sends the fresh DB `stockUnit`, so `data.stockUnit.amount` becomes the new DB amount. That part works.

## Findings

### [HIGH] Confidence: HIGH. New arm leaves `countData` at the first count, which locks the operator into a recount loop where the only exits are wrong values
`store/cycleCount.js:243-247`
```js
} else if (result.stockUnit) { // the db amount changed since the screen loaded (SBDEV-3866)
  console.log('countSingleUnitLoad returned', result)
  this.$toast.error(result.message)
  context.commit('setStockUnitInfo', result)
  context.commit('setProcess', '23_recount')
```
Walk the flow. C1 = first count, A1 = DB amount returned with the first mismatch, A2 = DB amount when the recount posts, C2 = the operator's recount.
1. First count C1 ≠ A1. `countData = {count: C1}` (`countUnitLoad.vue:59`), go to `23_recount` with `stockUnit.amount = A1`.
2. Recount C2 = A1, so the code takes the `/countSingleUnitLoad` branch. The DB is now A2 ≠ A1, so the server answers mismatch. The **new arm** sets `stockUnitInfo.amount = A2`, but `countData.count` stays **C1**.
3. The operator counts the same physical C2 again. `C2 === A2`? No. `C2 === countData.count (C1)`? No, because C1 ≠ A1 = C2. That falls to `store/cycleCount.js:268`, `this.$toast.error(\`Amount ${data.count} differs expected. Count again!\`)`, with **no server call**. This repeats on every honest recount.

Escapes: type C1 (posts `/recountSingleUnitLoad` and **adjusts stock to C1**, the count the operator already distrusted), type A2 (server records a matching count with **no adjustment**, which the operator can't do on purpose because the recount screen never shows the amount), or leave the page. The recount screen has no back button (`recountUnitLoad.vue:21`, the `goBack` button is commented out). The ticket's false success turns into a dead end that pushes the operator toward entering a wrong value. The "count twice, same number" rule the `else` branch implements (`:256`) expects `countData` to hold the **previous** count, which here is C2.

**Fix:** in the new arm add `context.commit('setCountData', data)`, which is what the first-count path does through its component. The third count C2 then matches `countData.count` and posts `/recountSingleUnitLoad`, which adjusts to C2: two consecutive agreeing counts, the existing rule. Add a spec that runs a **second** `recountSingleUnitLoad` against the resulting state (count = C2, `stockUnit.amount = A2`, `countData` taken from the commit) and asserts it posts `/cycleCountLos/recountSingleUnitLoad`.

### [MEDIUM] Confidence: HIGH. The spec never pins `countData`, so it passes with the H1 defect
`test/store/cycleCountRecountMismatch.spec.js:35-38`
```js
expect(h.toast.error).toHaveBeenCalledWith(MSG)
expect(committed(h.context, 'setStockUnitInfo')).toEqual([response])
expect(committed(h.context, 'setProcess')).toEqual(['23_recount'])
```
Test 1 is meaningful: it fails on the parent commit because `toast.success` fires. It checks the immediate transition but not the state the **next** recount depends on. Add `expect(committed(h.context, 'setCountData')).toEqual([DATA])` plus the follow-on recount described in H1. Mutation-check it: drop the commit and confirm red.

### [LOW] Confidence: HIGH. Tests 2 and 3 are characterization tests and are green on the parent commit too
`test/store/cycleCountRecountMismatch.spec.js:41-60`. They guard the `21_unitLoad` and errors arms against regression, which is useful, but they don't prove the fix. Fine to keep. Label them as regression guards in the `describe`/`it` text so nobody counts them as red-first evidence.

### [LOW] Confidence: MEDIUM. Fixture response is thinner than the wire shape
`test/store/cycleCountRecountMismatch.spec.js:31`
```js
const response = { stockUnit: { id: 11, amount: 9 }, message: MSG }
```
The real map also carries `itemData`, `client`, `unitLoad` and `location` (`CycleCountLosController.java:133-137`), and `recountUnitLoad.vue:6-10` dereferences all of them without guards. A store-level test doesn't render, so this is harmless today. A realistic fixture (`unitLoad: {labelid:'UL-1'}, client:{name:..}, itemData:{itemNr,name}, location:{name}`) would document the contract the screen depends on and catch a future server change that drops a key.

### [LOW] Confidence: HIGH. Duplicated response handling: three copies of the count result arms
`store/cycleCount.js:214-226`, `:240-253`. The `/countSingleUnitLoad` response handling now exists twice, verbatim apart from the log line. A later change to one (for example this H1 fix) can easily miss the other. Consider extracting a helper such as `applyCountSingleResult(context, result, data)` that both call. That helper also needs `setCountData(data)` in its mismatch arm, which is harmless for the first-count path (the component already committed the same `data`).

### [LOW] Confidence: HIGH. Pre-existing: the recount screen has no exit and never shows the expected amount
`components/cycleCount/single/recountUnitLoad.vue:21`. `<!-- <v-btn ... @click="goBack">Main Menu</v-btn> -->`. This is out of the diff's scope, but it is why H1 is a hard trap and not just an annoyance. It is not this ticket's to fix unless H1's fix is rejected.

## Sibling sweep (Q2)

- `countSingleUnitLoad` (`store/cycleCount.js:208-232`): already routes mismatch to `23_recount`. Correct, and it is the model for this fix.
- `recountSingleUnitLoad` `else` arm (`:255-266`) posts `/recountSingleUnitLoad`. The server's success map only has `message` (`CycleCountLosController.java:171-173`), and errors arrive as `errors` → handled. No mismatch shape is possible there. Clean.
- By-SKU (order) path: `countUnitLoad` (`:120-150`) routes no `cyclecountPosition` → `15_recount`, and `recountUnitLoad` (`:155-182`) always posts `/recountUnitLoad` with no client-side amount comparison. That avoids the stale-screen class of bug entirely. **No sibling of SBDEV-3866 there.** Minor pre-existing oddity: if `countBySKURecount` returned an unmapped key, the controller's `default:` (`CycleCountLosController.java` recountUnitLoad switch) returns `{}` and the store toasts `success(undefined)` and stays put (`store/cycleCount.js:176-178`). The service (`MobileCycleCountService.java:551-581`) can only return the three mapped keys, so this is unreachable today. Not worth a finding beyond this note.
- `bySku/recountUnitLoad.vue` reads `countData.cyclecountPosition/orderId` and does not depend on `countData.count`. Unaffected.

## Positive observations

- The arm is correctly placed **after** the `errors` check and keys on `result.stockUnit`, the same discriminator the server and `countSingleUnitLoad` use. The `null` → success arm stays intact.
- The comment cites the ticket and explains the stale-screen cause. The spec header explains the SBDEV-3857 server change that made this reachable.
- The spec asserts the exact endpoint and payload, the absence of a success toast, and the exact commit sequence, rather than just "an error toast happened".
- Full suite green (755/755).

## Open questions

None at low confidence.

## Verdict

**REQUEST CHANGES**: one HIGH (H1, HIGH confidence). Add `context.commit('setCountData', data)` to the new arm and a follow-on recount spec that would fail without it.

---

## Re-review (commits `1a6b046`, `fac05e4` on top of `b576156`)

Scope: `git diff b576156..fac05e4`, which changes `store/cycleCount.js` and `test/store/cycleCountRecountMismatch.spec.js`. This was a read-only pass with no mutation runs in the worktree. The worktree is clean. Evidence: the spec passes 5/5, and the full jest suite passes **57 suites / 757 tests with 0 failures** (baseline 755 + 2 new tests).

### H1: closed (HIGH confidence)
`store/cycleCount.js:9-13`, the mismatch arm of `applySingleCountResult`:
```js
} else if (result.stockUnit) { // count not the same as what's in the db
  toast.error(result.message)
  context.commit('setStockUnitInfo', result)
  context.commit('setCountData', data)
  context.commit('setProcess', '23_recount')
```
Re-walking the earlier scenario: the recount posts C2 = 7 against the stale amount 7. The server answers a mismatch with DB amount 9, so `countData.count` becomes 7 and `stockUnit.amount` becomes 9. The operator repeats 7. The check `7 === 9` fails, then `7 === countData.count (7)` passes, so the code posts `/recountSingleUnitLoad` and the stock is adjusted to 7. The dead end is gone. The new test `repeating that count ... confirms it through /recountSingleUnitLoad` (spec `:61-77`) covers exactly this path. Its `toast.error.mock.calls` equality also proves that the local "differs" rejection did **not** fire. Without the new commit, `countData` would stay at 5. The second action would then take the local-reject arm, so `$post` would be called only once and the test would go red. I reasoned this through rather than running the mutation, per the run rules.

### Behaviour change from `countSingleUnitLoad` committing `countData`: none
- The only caller is `components/cycleCount/single/countUnitLoad.vue:59-60`. It commits `setCountData(data)` and then dispatches with the **same object**, so the helper's commit writes back an identical reference. The commit is a no-op, and there are no watchers on `countData`. The persisted-state write happens once more, with the same value.
- The errors arm does not commit anything, and neither did the old code. The success arm still sets `countData` to null. Both are unchanged.
- The recount path's errors arm, for example "stock unit moved", leaves `countData` and `process` as they were, same as before. The `/recountSingleUnitLoad` arm and the local-reject arm (`:248-265`) are untouched.
- `countData` here also carries `stockUnit`, `unitLoadName` and `comment`. The single flow reads only `.count`. The by-SKU screen reads `countData.cyclecountPosition/orderId`, but that flow starts from `11_select`, gets its own `setCountData` from `bySku/countUnitLoad.vue:58`, and the page `created()` runs `resetState`. No cross-flow leak.

### Test quality: good
- The harness now runs the module's real `mutations` against `state()` (spec `:16-24`). That makes a multi-step test possible and removes the hand-stubbed `state.countData`.
- The `mismatch()` fixture matches the controller's wire keys (`CycleCountLosController.java:133-138`). This closes my earlier LOW on the thin fixture.
- The "regression guard" labels are accurate: those two arms pass on `f51dc6c` too.
- The `countSingleUnitLoad` test (`:103-118`) pins the new helper commit. Its harness doesn't simulate the component's own commit, so it really does depend on the helper.

### New findings

**[LOW] Confidence: HIGH. The two-step test doesn't pin the second POST's payload.**
`test/store/cycleCountRecountMismatch.spec.js:72-73`
```js
expect(h.axios.$post.mock.calls.map(c => c[0])).toEqual(
  ['/cycleCountLos/countSingleUnitLoad', '/cycleCountLos/recountSingleUnitLoad'])
```
Only the URLs are asserted. The point of step 2 is that the confirm posts **count 7 with the DB stock unit**. Add `expect(h.axios.$post).toHaveBeenNthCalledWith(2, '/cycleCountLos/recountSingleUnitLoad', expect.objectContaining({ count: 7, stockUnit: DB }))`.

**[LOW] Confidence: HIGH. The fixture's success message doesn't match the server's text.**
Spec `:62` uses `{ message: 'Recounted UL-1' }`, but `/recountSingleUnitLoad` returns `"Counted " + unitLoadName` (`CycleCountLosController.java:172`). This is cosmetic. Use `'Counted UL-1'` so the fixture stays on the wire contract like the rest.

**[LOW] Confidence: MEDIUM. Pre-existing, not introduced here: the local-reject arm never updates `countData`.**
`store/cycleCount.js:263-265`. A count that differs from both the last server-submitted count and the DB amount is rejected, and nothing is remembered. So an operator whose *submitted* count was itself a miscount has to match that miscount or the hidden DB amount. This is the original "count twice" design, made no worse by this change. Mention it on the ticket only if the recount UX gets revisited along with the deliberately commented-out exit button.

The previous LOWs:
- Duplication: fixed by the helper.
- Fixture: fixed.
- Characterization labels: fixed.
- No exit button: accepted with a stated rationale and being recorded on the ticket. With H1 closed, the screen is no longer a forced dead end, so I agree it should not block this ticket.

### Re-review verdict

No CRITICAL, HIGH or MEDIUM findings remain. The two new LOWs are test polish and can be done in the same pass if convenient.

**APPROVE**

---

## Re-review 2 (commit `6855cc2`)

Scope: `git show 6855cc2`. It makes one product-code line change in `store/cycleCount.js:263` and adds test fixes. This was a read-only pass with no mutation runs. The worktree is clean. Evidence: the spec passes 6/6, and the full jest suite passes **57 suites / 758 tests with 0 failures**.

### Test fixes for the re-review LOWs: done
- Spec `:73-74` now pins the second POST's payload: `mock.calls[1][1]` is checked against `repeat`, and `repeat.stockUnit` against `DB`.
- Spec `:65` uses the server's real `'Counted UL-1'`.
- The new test (`:106-122`) covers the local-reject → repeat → confirm path. Its `toast.error.mock.calls` and `$post` URL-list equalities are exact, so a missing commit would turn it red: the second call would be rejected locally and no POST would happen.

### Does the new commit weaken the double-count check? On the store alone, no. Combined with the recount screen, yes.

`store/cycleCount.js:262-264`
```js
} else { // different but the new count deffers from the previous count again
  this.$toast.error(`Amount ${data.count} differs expected. Count again!`)
  context.commit('setCountData', data) // repeating this count confirms it (SBDEV-3866)
```
**The store rule on its own holds.** An adjustment through `/recountSingleUnitLoad` still needs `data.count === countData.count`, and `countData` is only ever the operator's *previous* submission. One entry X followed by a different entry Y is rejected (and `countData` becomes Y). No single submission can confirm itself. The rule changed from "equals the **first** count" to "equals the **immediately previous** count". Both are a two-equal-counts rule, so the store logic is not weaker in principle. It also fixes the pre-existing LOW, where an operator whose correct count differed from the original miscount could never confirm it.

**The weakness: on this screen, "a second submission" doesn't require a second count.** Two facts combine with the new line.
1. `pages/cycle-count.vue:18`: `<single-recount-unit-load v-else-if="process === '23_recount'" />` has no `:key`. A local reject leaves `process` at `23_recount`, so the component is **not remounted**.
2. `components/cycleCount/single/recountUnitLoad.vue:49-63`: `submit()` never clears `this.count` (the only `this.count = null` is in the commented-out `goBack`, `:45`). The button (`:23`) has no in-flight / `disabled` guard.

So after a local reject, the fat-fingered value is **still in the field**. Pressing Submit again, or pressing Enter in the comment field (the `v-form @submit`, `:12`), resubmits the same number. That number now equals `countData.count`, so it posts `/recountSingleUnitLoad` and the **stock is adjusted to the typo** without anyone counting again.

Double-tap is worse still. In the local-reject branch the action has no `await` before the commit, so the first tap's `setCountData(X)` lands synchronously. A second tap a few ms later sees `countData.count === X` and posts the adjustment. **One fat-fingered entry plus an accidental double-tap on a handheld now produces a stock adjustment.** The only signal is an error toast that the second tap immediately follows with a success toast.

Before `6855cc2`, the same double-tap was rejected twice, because X ≠ the first count. The first count was entered on a *different, freshly mounted* screen (`countUnitLoad.vue`), so the confirmation was always a separate act of typing.

The same retained-value property already applies to the 1a6b046 H1 path, which I approved in Re-review 1. After a server mismatch the screen stays on `23_recount` with C2 still in the field, so a second Submit confirms C2. That path is milder: it needs a server round trip between presses, so a fast double-tap sends two `/countSingleUnitLoad` posts and gets two mismatches, not an adjustment. C2 also matched what the DB held when the screen loaded. I'm correcting the record: Re-review 1 should have caught this too. It is the same root cause.

**[HIGH] Confidence: HIGH (mechanism traced statically; not exercised in a browser). A rejected recount can be confirmed by resubmitting the unchanged field (or a double-tap) with no second count, so an unverified count is written as a stock adjustment.**
File: `store/cycleCount.js:264` together with `components/cycleCount/single/recountUnitLoad.vue:49-63` and `pages/cycle-count.vue:18`.
Fix: keep the store line (its rule is sound), and make each confirmation a fresh entry. Either option works:
- (a) In `recountUnitLoad.vue` `submit()`, capture the value and then clear the field: `const count = parseInt(this.count); this.count = null` before dispatching. This forces the operator to retype the number. Optionally also add a `submitting` flag that disables the button until the dispatch promise settles, to kill the double-tap race.
- (b) If touching the component is out of scope, revert only the product line of `6855cc2`. That keeps the test fixes and leaves the pre-existing "must match the first count" limitation recorded on the ticket.

Pin (a) with a component spec: mount `recountUnitLoad.vue`, set the count, submit, and assert that `count` is empty afterwards. Mutation-check it by removing the clear and confirming red.

No other new defects. The by-SKU path is unaffected (it uses `recountUnitLoad`, which always round-trips to the server).

### Re-review 2 verdict

One HIGH at HIGH confidence. It was introduced by `6855cc2`'s product line and is reachable through a double-tap.

**REQUEST CHANGES**

---

## Re-review 3 (commits `50dd568`, `6df74bd`)

Scope: `git diff 6855cc2..6df74bd`. Product change: `components/cycleCount/single/recountUnitLoad.vue:62-65`. New spec: `test/components/cycle-count-recount-retype.spec.js`. This was a read-only pass with no mutation runs, and the worktree is clean. Evidence: the two SBDEV-3866 specs pass 8/8, and the full jest suite passes **58 suites / 760 tests with 0 failures**.

```js
console.log('recount data:', data)
this.count = null
this.$refs.scanLookup.resetValidation()
this.$store.dispatch('cycleCount/recountSingleUnitLoad', data)
```

### Q1: Every stock-adjusting path now needs two typed, equal counts. Yes.
Only `/recountSingleUnitLoad` changes stock. The store posts to it only when `data.count === countData.count` (`store/cycleCount.js:249`). `countData` is written from three places, and each one is a value the operator typed in a separate submission:

| Writer | Source of `data.count` |
|---|---|
| `single/countUnitLoad.vue:59` (first count) | typed on `22_count`, a different component from `23_recount` |
| `applySingleCountResult` mismatch arm (`store/cycleCount.js:12`, the H1 fix) | typed on `23_recount` |
| local-reject arm (`store/cycleCount.js:264`, `6855cc2`) | typed on `23_recount` |

The confirming submission is also typed on `23_recount`. That field is now empty after every submit, so a value can't carry over from the previous submission. Paths:
- **Server-mismatch arm (H1):** C2 is typed and cleared. The server says it differs, and `countData` becomes C2. C3 is typed, and C3 === C2 is needed to adjust. **Two typed entries.**
- **Local-reject arm:** X is typed and cleared, and `countData` becomes X. Y is typed, and Y === X is needed to adjust. **Two typed entries.**
- **First count → recount:** C1 is typed on `22_count`, then C2 is typed on a freshly mounted `23_recount`. C2 === C1 is needed. **Two typed entries**, unchanged from before.
- **Double-tap / Enter-repeat:** the second event arrives after the microtask flush that pushes `count = null` into the `v-text-field`, so `v-form.validate()` → `validate(true)` runs the `!!v` rule against `null`, fails, and dispatches nothing.

The one single-entry path is `count === DB amount` → `/countSingleUnitLoad`. It records a FINISHED position with `amountafter = amount` and **changes no stock** (`MobileCycleCountService.java:185-194`). That is pre-existing by design.

### Q2: `resetValidation` on Vuetify 2.7.2 behaves as intended. Yes.
Read from `node_modules/vuetify/lib/mixins/validatable/index.js` and `components/VForm/VForm.js`:
- **Comment is kept.** `VForm.resetValidation()` calls each input's `resetValidation()`, which only sets `isResetting = true` (`validatable :241-243`). Only `reset()` (`:235-238`) nulls `internalValue`, and it isn't called.
- **No red "required" left showing.** Here is the order of events.
  1. `count = null` re-renders the parent.
  2. The `value` watcher updates `lazyValue`.
  3. The `internalValue` watcher sets `hasInput = true` and runs `$nextTick(validate)`. This fills `errorBucket`, all in microtasks.
  4. Then the `isResetting` watcher's `setTimeout(0)` macrotask clears `hasInput` and `hasFocused` and re-runs `validate()` without force (`:196-203`).
  
  After that, `shouldValidate` is `hasInput || hasFocused`, which is `false` (`:139-143`), so `validationTarget` is `[]` and no message renders. While `isResetting` is true, `shouldValidate` is already `false` (`:141`), so the message doesn't even flash. The message comes back only on a real focus-then-blur of the empty field or on the next forced `validate()`, which is the intended behaviour.

### Q3: Other ways into `23_recount` with a prefilled count. None.
- The only producer of `'23_recount'` is `applySingleCountResult` (`store/cycleCount.js:14`, found by grep across `components pages store plugins middleware`).
- From `22_count`, the recount screen mounts fresh with `data(): count: null`.
- From `23_recount` to itself, the field is cleared on submit.
- A page reload runs `resetState` in `pages/cycle-count.vue` `created()`.
- `tabChanged` resets to `11_select` or `21_unitLoad`, never into `23_recount`.
- A stale `countData` left by a tab switch (`tabChanged` doesn't clear it) is always overwritten by `countUnitLoad.vue:59` before the next `23_recount`, so it can't pair with a later count.

### Test quality
- Both component tests are meaningful, and your stated mutant result (without the clear: `Received: '7'` and `2 calls`) matches what the assertions would do. The `v-form` stub's `validate()` reads `vm.count` and `vm.comment`, which matches the screen's `!!v` rules on both fields.
- **[LOW] Confidence: HIGH. `resetValidation()` is not pinned.** The stub (`spec :22`) is a no-op `resetValidation() {}` and no test asserts it was called. If it were removed, the clear would still work, but on real Vuetify a red "Item is required" would appear under the count right after every submit (the step-3 `hasInput = true` would no longer be undone). That is a UX regression the suite wouldn't see. Fix: make the stub method a `jest.fn()` and assert it is called once per dispatching submit.
- **[LOW] Confidence: MEDIUM. The double-tap test fires both submits in the same tick**, which is stricter than reality (real taps have a render flush between them). It passes because the stub reads `vm.count`, which is cleared synchronously. Fine as written. Just note that it proves the component-state guard, not Vuetify's `internalValue` timing (covered by reasoning in Q2).

### Carry-overs
- Re-review 2 HIGH: **closed** by `50dd568`.
- "No exit button on the recount screen" LOW: still accepted, and recorded on the ticket.
- No in-flight guard: acceptable. Once the field is cleared, a second dispatch requires a new typed value, and that is exactly what the two-count rule wants.

### Re-review 3 verdict

No CRITICAL, HIGH or MEDIUM findings. Two test-only LOWs; the first, pinning `resetValidation`, is worth doing in the same pass.

**APPROVE**

> Archived 2026-10-22. SBDEV-3866 shipped as wms2-mobile-ui #96 (merge 1497c3bb), on dev, DEV browser test passed. Every finding above is fixed except the recount screen's missing exit button, which was dropped (the header returns to the menu). Implementation worktree(s) removed 2026-10-22: wms2-mobile-ui/SBDEV-3866
