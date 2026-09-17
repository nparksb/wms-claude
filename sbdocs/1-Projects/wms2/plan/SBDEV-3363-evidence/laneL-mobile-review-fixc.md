# Lane L — code review: SBDEV-3363 Fix C / M-4 (mobile UI + cross-repo contract)

- **Reviewed:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-mobile-ui/SBDEV-3363-m4`,
  branch `bugfix/SBDEV-3363-m4-demand-cancelled`, commit `1e3d979`, base `ab1e2ae`
  (`git merge-base HEAD origin/develop` = `ab1e2ae3ea3d0d5e6f6094ebc4141f8f570f788c` — base is current).
- **Producer side (read-only):** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3363-ac5` @ `af403931`.
- **Diff under review:** `store/picking.js` (2 hunks) + new `test/store/pickingDemandCancelled.spec.js` (156 lines).
- **Verdict: APPROVE.** The contract is correct, the back-compat claim holds over the *full* domain of
  `pickStatus` (not just the two values the tests use), and both widened conjuncts are individually
  mutation-killed. **10 findings, all Low or Info.** None block the merge; L-1 and L-2 are the ones
  worth acting on in this pass.

---

## 1. What I verified green

### 1.1 Cross-repo field name — PASS, character-for-character

| Side | Evidence |
|---|---|
| API emit | `MobilePickingService.java:943` — `map.put("demandCancelled", demandCancelledIds.contains(pos.getId()));` |
| API method | `MobilePickingService.getPickingOrderPositionsInfo(long)` — declared at `MobilePickingService.java:810`, emit site at `:943` is inside it |
| API route | `PickingController.java:283-291` — `@GetMapping(path= "/pickingOrderPositionsInfo/{id}")` → `items = mobilePickingService.getPickingOrderPositionsInfo(id);` |
| UI fetch | `store/picking.js:456` — `await this.$axios.$get(\`/picking/pickingOrderPositionsInfo/${data.value}\`)` |
| UI read (filter) | `store/picking.js:482-483` — `position.pickStatus !== CANCELLED_PICK_STATUS && !position.demandCancelled` |
| UI read (landing) | `store/picking.js:140` — `&& !state.pickingOrderPositions[i].demandCancelled` |

Same endpoint, same spelling, same case. The value is an autoboxed `Boolean` from
`Set.contains(...)`, so it is never `null` on a new API.

Row identity also lines up: the emit loop keys the flag on `pos.getId()` and writes the same value as
`map.put("id", pos.getId())`, and `findDemandCancelledPickLineIds` (`PickingorderBusinessService.java:936`)
returns `p.getId()` of the **pick line**. No id-space mismatch.

### 1.2 Back-compat / deploy-order — PASS, and provable over the whole domain

The task asked for *every* value `pickStatus` can take, not just the two the tests use. `pickStatus` is
`WmsConstants.State.getCodeText(pos.getState())`, whose full range is the enumerated strings
(`"Picked"`, `"Packed"`, `"Palletized"`, `"Loaded to Truck"`, `"Finished"`, `"Cancelled"`, plus the
earlier live states) and a `default: return String.valueOf(state)` fallthrough
(`v2/wms2-api .../service/WmsConstants.java:170-184`).

- **Old API** — the key is absent on every row, so `position.demandCancelled` is `undefined` and
  `!undefined === true` **for every row regardless of `pickStatus`**. Both widened predicates
  therefore reduce algebraically to the pre-change predicate. This is not an argument about which
  values the tests cover; the added conjunct is a constant `true`.
- **New API** — `demandCancelled` is a strict **superset** of the `pickStatus === 'Cancelled'` test:
  `isDemandCancelled`'s first trigger is `pickingPosition.getState() == WmsConstants.State.CANCELED`
  (`PickingorderBusinessService.java:988-991`), and `getCodeText(CANCELED)` returns exactly
  `"Cancelled"` (`WmsConstants.java:180-181`). So the retained `pickStatus` conjunct can only ever
  drop a row that `!demandCancelled` would also drop — **the widening can never over-filter.**

That is a stronger statement than the plan's §3.3 makes, and it is the reason the "widen, don't
replace" shape is safe in both deploy orders rather than merely safe in one.

### 1.3 Plan conformance — PASS

`store/picking.js:482-483` and `:138-140` are character-equivalent to the "RIGHT" snippet in plan
§3.3, including the instruction that *"`nextPickingPosition` tests the same string and must be widened
identically"*. No deviation.

### 1.4 Test lane

Full suite on the branch, `node_modules/.bin/jest` under nvm node v24.15.0:

```
Test Suites: 33 passed, 33 total
Tests:       400 passed, 400 total
```

**Mutation checks** (file copied to the scratchpad and restored from there — no `git checkout`/`restore`/`stash`
was used; `git status --short` was empty after each):

| Mutant | Effect | Result |
|---|---|---|
| M1 — drop `&& !position.demandCancelled` from the **filter** only | `2 failed, 3 passed` in the new spec | **killed** |
| M2 — drop `&& !…[i].demandCancelled` from the **landing rule** only | `1 failed, 4 passed` in the new spec | **killed** |
| M3 — *replace* not widen (drop the `pickStatus` conjunct at **both** sites) | `2 suites failed, 7 tests failed` across `test/store/` | **killed** (by the new spec's two back-compat rows **and** by `pickingCancelledPositions.spec.js`) |

Each conjunct at each site is independently pinned, and the back-compat direction — the one the plan
flags as the tempting wrong edit — is pinned twice over. This is the part of the change I have the
most confidence in.

### 1.5 Vue 2 / Vuex specifics — PASS

- **Mutation vs action placement is right.** The filter lives in the action (it shapes the payload
  before `commit`); the landing rule lives in the mutation (pure synchronous state). No async
  crossed into a mutation.
- **Reactivity is a non-issue here.** The change only *reads* `position.demandCancelled`; no property
  is added to an already-reactive object after the fact, so Vue 2's `Vue.set` caveat does not apply.
  Rows enter state by whole-array replacement (`setPickingOrderPositions`, `store/picking.js:85-87`),
  which is reactive.
- **`currentPosition` can never be left `undefined` by the widened landing rule.** Empty array →
  `state.currentPosition = null` (`:156-157`); all rows skipped → `state.pickingOrderPositions[0]`,
  which is defined. Empty array via the action's early return → `setCurrentPosition(0)` takes its
  `else` branch and nulls it (`:172-173`). `null`, never `undefined`. *(But see L-2 and L-3 for what
  those two paths leave behind.)*

---

## 2. Site sweep — every place that decides "cancelled / skippable / landable"

Swept `store/picking.js` (590 lines), `components/picking/**`, `pages/picking.vue`, for `pickStatus`,
`'Cancelled'`, `CANCELLED_PICK_STATUS`, index walking, and every `filter`/`find`/`findIndex`/`some`
over `pickingOrderPositions`.

| # | Site | Decides | Widened? | Verdict |
|---|---|---|---|---|
| 1 | `store/picking.js:482` filter in `getPickingOrderPositionsInfo` | which rows enter the working set | ✅ yes | correct |
| 2 | `store/picking.js:138-140` scan loop in `nextPickingPosition` | which row the operator lands on | ✅ yes | correct |
| 3 | `store/picking.js:148-152` the **`!found` fallback** of `nextPickingPosition` | which row the operator lands on when none qualify | ❌ **no** | **L-1** |
| 4 | `store/picking.js:100-111` `nextPosition` / `:112-122` `previousPosition` | index stepping | ❌ no | **not a defect** — they index into the already-filtered array; see L-2 |
| 5 | `store/picking.js:165-174` `setCurrentPosition` | index landing | ❌ no | no cancellation test by design; guards on bounds only. See L-3 for its `else` branch |
| 6 | `store/picking.js:566-568` `findIndex(position => position.id === rowBefore)` in `processPick` | whether the operator's row survived the re-query | n/a | **correct by construction** — keyed on id over the post-filter array, so a row the widened filter removed reports `-1` and falls through to `nextPickingPosition`. This is the path the whole ticket turns on, and M-4 makes it fire for the three new triggers |
| 7 | `components/picking/pick.vue:343-350` `activePick()` | Pick-button liveness + row greying | ❌ no | **L-5** |
| 8 | rapid picking (`components/picking/rapid/**`, `rapidPositionInfo`) | — | n/a | **out of scope, correctly** — a disjoint data path that never populates `pickingOrderPositions`; plan §3.3 scopes M-4 to the regular pick list |

There is **no `previousPickingPosition`** in this repo — the sibling the brief anticipated is
`previousPosition` (row 4), which carries no status test at all and needs none. The genuine unwidened
sibling is row 3, the `!found` fallback *inside the mutation that was changed*.

Only two writers of `pickingOrderPositions` exist —
`store/picking.js:454` (`[]`) and `:496` (`livePositions`) — plus a commented-out line at
`components/picking/selectOrder.vue:124`. This is what makes rows 4 and 5 safe, and it is also what
makes L-2 a comment problem rather than a code problem.

---

## 3. Findings

### L-1 — Low — `nextPickingPosition`'s `!found` fallback bypasses the guard that was just widened

`store/picking.js:148-153`:

```js
      if (!found) {
        this.$toast.info('No pending picking found')
        state.currentIndex = 0
        state.currentPosition = state.pickingOrderPositions[0]
        state.pickingCompleted = true
      }
```

The scan loop above it was widened to refuse a demand-cancelled row; this fallback then assigns
`positions[0]` unconditionally — including when `positions[0]` is exactly such a row. Proven by direct
probe against the real module (temporary spec, run and deleted; worktree left clean):

```
PROBE B -> currentPosition.id: 11  demandCancelled: true  pickingCompleted: true
```

**Impact is bounded, not zero.** `pickingCompleted === true` makes `pick.vue:99` (`v-if="!pickingCompleted"`)
hide the whole scan form, so no live Pick button is offered — this is *not* a return of the H1 symptom.
But `pick.vue:37` (`v-if="currentPosition"`) still renders the cancelled row's SKU, amount and location
under a blue **Done** chip. The same hole exists today for a plain `'Cancelled'` row, so this is
pre-existing from SBDEV-3319 rather than introduced here — but M-4 adds three new triggers that reach
it, so its exposure rises with this change.

**Recommendation:** either null `currentPosition` in the fallback, or add a sentence to the SBDEV-3363
comment recording that the fallback deliberately lands on an unpickable row and why that is safe.
Right now the comment at `:134-137` claims the guard is defence in depth and the code five lines below
silently defeats it.

### L-2 — Low — the stated rationale for widening the landing rule is false as written

`store/picking.js:475` and `test/store/pickingDemandCancelled.spec.js:26, :121` both justify the second
widening with:

> `// reachable via nextPosition/previousPosition, which is the same "live Pick button on work that cannot succeed"`

> `// Filtering alone is not enough: nextPosition/previousPosition walk the array directly, so a row the filter would have dropped can still be landed on if it is present for any reason.`

`nextPosition` (`:100`) and `previousPosition` (`:112`) index into `state.pickingOrderPositions` — which
**is** the filtered array. `grep -rn setPickingOrderPositions store/ components/ pages/` returns exactly
two live commits (`:454` `[]`, `:496` `livePositions`). A row the filter drops is therefore not present
in the array and is not reachable by any live path. The SBDEV-3319 timing argument inherited at
`:124-128` ("a cancel can land between them") is also inaccurate for this field: a server-side cancel
does not mutate the client's in-memory array, so only a re-query can change `demandCancelled`, and a
re-query re-runs the filter.

**The widening is still right and should stay** — it is cheap, it is what plan §3.3 mandates, and it is
the correct guard if a future caller ever commits unfiltered rows. But the reason as written will
mis-scope the next reader (and, per L-1, it is stated more strongly than the code delivers). Suggest
rewording to the honest one: *"defence against a future writer of `pickingOrderPositions`; there is no
live path today."* The sibling comment at `store/picking.js:497-508` already models exactly this
"honest scope" phrasing for the clamp — worth matching it.

### L-3 — Low — the all-cancelled early return leaves `state.currentIndex` stale

`store/picking.js:484-497`: the branch commits `setCurrentPosition(0)`, but with the list already empty
`setCurrentPosition` takes its `else` (`:172-173`), which nulls `currentPosition` and **never touches
`currentIndex`**. Probed:

```
PROBE A -> currentIndex: 3  currentPosition: null  pickingCompleted: true  positions.length: 0
```

`pick.vue:10` renders `Pick - {{ currentIndex + 1 }} of {{ orderPositions.length }}`, so the operator
reads **"Pick - 4 of 0"**. Cosmetic, pre-existing from SBDEV-3319 — but M-4 is what makes this branch
reachable for the three extra triggers, and the plan's own AC-5 framing predicts it will now fire on
real orders rather than only on the rare all-lines-cancelled case. One line in the branch
(`context.commit('setCurrentIndex', 0)` or resetting inside `setCurrentPosition`'s `else`) closes it.

### L-4 — Low — "all rows demand-cancelled" is indistinguishable from "picking finished" (brief Q5)

The test asserting `setPickingCompleted(true)` on an all-demand-cancelled order pins the right *store*
behaviour, but the screen it produces is:

- `pick.vue:13` — `<span v-if="pickingCompleted" …><strong>Done</strong></span>`
- `pick.vue:99` — `<div v-if="!pickingCompleted">` hides the entire scan form
- `pick.vue:185` — `<div v-if="pickingCompleted">` shows only a **Return** button

…which is byte-identical to a genuinely completed order. The **only** differentiator is the transient
`this.$toast.info('All picking positions for this order have been cancelled')` at `store/picking.js:493`.
An operator who taps away, or whose toast auto-dismisses before they look up, cannot tell that the work
was cancelled rather than done — and on a club/wave floor that difference determines whether they go
looking for the missing units.

Worth distinguishing. The store already carries a `verifiedPickingMessage` state field
(`store/picking.js:38`) that models exactly this "persistent explanatory line" pattern; a sibling
`pickingCancelledMessage` rendered next to the Done chip would be a small, contained follow-up.
Pre-existing from SBDEV-3319, widened in reach by M-4 — flagging rather than blocking.

### L-5 — Low — `activePick()` is the third copy of "is this row workable" and was not widened

`components/picking/pick.vue:343-350`:

```js
    activePick() {
      if (this.currentPosition) {
        const status = this.currentPosition.pickStatus
        if (status != 'Picked') return true
```

It keys on `'Picked'` alone — not `CANCELLED_PICK_STATUS`, not `demandCancelled`. It drives the Pick
button, the row greying (`pick.vue:36-39`, `:class="[!activePick() ? 'pl-1 grey lighten-2' : …]"`), the
`v-if="locationScan && activePick()"` scan form and the `locationScan` watcher.

**Currently unreachable with a cancelled row**, because the filter removes those rows before they can
become `currentPosition` — so this is not a live defect and the diff is not wrong to leave it. But it is
the same half-fix shape the ticket exists to close, it is the component-level guard the brief asked
about, and it is the guard that would matter in exactly the scenario L-1 and L-2 describe. Worth a
one-line comment recording that it deliberately tests only `'Picked'` and relies on the store filter,
so the next person does not read its narrowness as an oversight — or as licence to widen the store
filter's siblings less carefully.

### L-6 — Low — the new spec calls the action with a bare number, not the `{value, index}` payload

`test/store/pickingDemandCancelled.spec.js:77, :95, :110`:

```js
    await mod.actions.getPickingOrderPositionsInfo.call(self, context, 99)
```

Every production caller passes an object — `selectOrder.vue` passes `{value, index: 0}`, `processPick`
passes `{value: data.orderId, index: context.state.currentIndex}` — and the sibling spec
`test/store/pickingCancelledPositions.spec.js:99` correctly passes `{ value: 180342, index: 0 }`.
With `99`, `data.value` and `data.index` are both `undefined`. Probed:

```
PROBE C -> GET url: /picking/pickingOrderPositionsInfo/undefined
           commits: [["setPickingOrderPositions",[]],
                     ["setPickingOrderPositions",[{…}]],
                     ["setCurrentPosition",null],   // <- Math.min(undefined, 0) === NaN
                     ["setProcess","12_pick"]]
```

The assertions under test still hold **for the right reason** (M1 and M2 kill them), so this is not a
false green. But the harness misstates the call contract, the clamp at `:509` is exercised with `NaN`,
and a future change that dereferences `data.value` would fail here for a reason unrelated to M-4.
Pass `{ value: 99, index: 0 }`.

### L-7 — Low — one assertion in the all-cancelled test reads the reset, not the branch

`test/store/pickingDemandCancelled.spec.js:113`:

```js
    expect(committed(context, 'setPickingOrderPositions')).toEqual([])
```

On the early-return path the branch commits `setPickingOrderPositions` **zero** times; the only such
commit is the unconditional reset at `store/picking.js:454`. `committed()` takes `.pop()` of all calls,
so this reads the reset.

It is **not vacuous** — under mutant M1 a two-row commit lands last and it fails — but it would equally
pass if the action threw immediately after line 454, which is not what the test name claims to check.
The load-bearing assertion in that test is `setPickingCompleted → true`, and that one is solid.
Stronger form: `expect(context.commit.mock.calls.filter(c => c[0] === 'setPickingOrderPositions')).toHaveLength(1)`.

### L-8 — Low — coverage gaps in the new spec

- No row pins L-1 (every row demand-cancelled → `nextPickingPosition` fallback). Given the spec's own
  thesis is "the landing rule is the defence-in-depth layer", the case where that layer hands back a
  cancelled row is the one most worth pinning.
- The two landing tests assert only `state.currentPosition.id`. Neither asserts `state.currentIndex`
  (should be `1`) nor `state.pickingCompleted` (should be `false`) — both of which the mutation writes
  and either of which could regress silently. The sibling spec
  (`pickingCancelledPositions.spec.js:281, :296`) does assert `pickingCompleted`.

### L-9 — Low — dead scaffolding in the test harness

`test/store/pickingDemandCancelled.spec.js:41-45`: `harness()` returns `_axios`, `_toast`, `_get`,
`_post` and accepts a `post` mock. None of the five is referenced by any test in the file (no test
exercises `processPick`). `ctx()`'s `dispatch` is likewise never asserted. Harmless, but it reads as if
there is coverage of the POST path when there is none.

### I-1 — Info — `console.log` on the widened hot path

`store/picking.js:133` — `console.log('picking position test:', …)` runs once per row per operator tap,
now inside the loop this ticket touches. Consistent with the rest of the file (which is full of these)
and pre-existing, so not something to change in this diff — recording it only because the widened loop
made it visible in the test output.

---

## 4. Answers to the six questions put to this lane

1. **Is the site set complete?** Yes for the live paths, with one qualification. The two widened sites
   are the only two that decide the question on any reachable path. There is **no `previousPickingPosition`**;
   `nextPosition`/`previousPosition` need no widening because they step the already-filtered array. The one
   genuine unwidened sibling is the **`!found` fallback inside `nextPickingPosition` itself** (L-1), and the
   one unwidened component guard is `activePick()` (L-5) — both currently unreachable with a cancelled row,
   both worth a comment.
2. **Cross-repo field name.** Verified character-for-character, same endpoint, non-null Boolean, matching
   id space. §1.1.
3. **Back-compat.** Holds over the entire domain of `pickStatus`, not just the tested values — the added
   conjunct is a constant `true` on an old API, and a strict superset on a new one. §1.2.
4. **Test quality.** No vacuous assertion; all five rows die under the mutant they exist to catch, and the
   harness drives the **real** store module (`freshModule()` → `require('@/store/picking')` after
   `jest.resetModules()`, real `mod.state()`, real mutations). Weaknesses are L-6 (wrong payload shape),
   L-7 (one weakly-discriminating assertion), L-8 (gaps), L-9 (dead scaffolding) — none of them a false green.
5. **`setPickingCompleted` semantics.** The store behaviour is right; the *screen* it produces is
   indistinguishable from a genuinely finished order once the toast clears. L-4.
6. **Vue 2 / Vuex.** Placement correct, no reactivity hazard, `currentPosition` never `undefined`. §1.5.
   The residue is the **stale `currentIndex`** (L-3), not an undefined position.

---

## 5. Commands run

```bash
git -C …/wms2-mobile-ui/SBDEV-3363-m4 diff origin/develop...HEAD
node_modules/.bin/jest                    # 33 suites / 400 tests, 0 failures
node_modules/.bin/jest test/store/        #  9 suites / 145 tests, 0 failures
# three mutants applied with perl -0pi, each restored from a scratchpad copy of store/picking.js
# three behaviour probes via a temporary spec under test/store/, deleted after the run
git -C …/wms2-mobile-ui/SBDEV-3363-m4 status --short   # empty, before and after
```

No `git checkout --`, `git restore` or `git stash` was used at any point.
