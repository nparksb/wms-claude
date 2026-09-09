# SBDEV-3016 — Review Lane A: mobile logger-label sweep

**Scope reviewed:** `git diff origin/develop` on branch `chore/wms2-mobile-misattributed-loggers`
(worktree `.claude/worktrees/wms2-api/SBDEV-3016-loggers`, base `origin/develop @ 2d56ac4c`).
Read + grep only, no build/write commands run against the worktree.

**Verdict: APPROVE WITH CHANGES**

The 19 label edits are all correct fixes and the CLAUDE.md counts/examples check out against the
code. One finding keeps this from a clean APPROVE: the doc's own stated criterion for "10 labels
audited and deliberately left alone" ("provided the method's own name appears") does not actually
hold for 5 of those 10 — they were left alone for a defensible reason (no misattribution risk), but
not for the reason the paragraph gives. This is a doc self-consistency defect, not a runtime bug;
nothing in the diff needs a behavior change.

---

## 1. Every one of the 19 edits, individually verified

Read each edited line's enclosing method (found by its real `{ }` boundaries, not line proximity)
and confirmed the new label names that method.

| # | File:line (new) | Enclosing method | Old label | New label | Verdict |
|---|---|---|---|---|---|
| 1 | CycleCountLosController.java:79 | `processScanUnitLoad` (GET, L78-111) | `scanSingleUnitLoad` | `processScanUnitLoad` | PASS |
| 2 | CycleCountLosController.java:105 | same | `scanSingleUnitLoad` | `processScanUnitLoad` | PASS |
| 3 | LookupController.java:59 | `searchSku` (L58-67) | `search` | `searchSku` | PASS |
| 4 | LookupController.java:65 | same | `search` | `searchSku` | PASS |
| 5 | LookupController.java:71 | `stockListByItemNumber` (L70-77) | `search` | `stockListByItemNumber` | PASS |
| 6 | LookupController.java:75 | same | `search stockListByItemNumber` (mislabel of a *third* method) | `stockListByItemNumber` | PASS |
| 7 | LookupController.java:81 | `unitLoadListByLocationName` (L80-87) | `search` | `unitLoadListByLocationName` | PASS |
| 8 | LookupController.java:85 | same | `search stockListByItemNumber` (mislabel of a *third* method — the worst case in the set) | `unitLoadListByLocationName` | PASS |
| 9 | LookupController.java:95 | `locationByLocationName` (L94-103) | `search` | `locationByLocationName` | PASS |
| 10 | LookupController.java:101 | same | `search` | `locationByLocationName` | PASS |
| 11 | MoveUnitloadController.java:86 | `selectStock` (POST `/selectDestination`, L68-92) | `selectSource` (a real sibling handler in the same file, L43-65) | `selectStock` | PASS |
| 12 | PalletizingController.java:51 | `scanUnitLoad` (GET `/scanParcel/{input}`, L50-70) | `scanParcel` | `scanUnitLoad` | PASS |
| 13 | PalletizingController.java:64 | same | `scanParcel` | `scanUnitLoad` | PASS |
| 14 | PutawayController.java:41 | `requestLocation` (GET `/scanPallet/{input}`, L40-73) | `scanPallet` | `requestLocation` | PASS |
| 15 | PutawayController.java:67 | same | `scanPallet` | `requestLocation` | PASS |
| 16 | PutawayController.java:179 | `storePalletBackOnPutawayLane` (L165-185) | `storePalletOnLocation` (a real sibling handler, L142-162) | `storePalletBackOnPutawayLane` | PASS |
| 17 | ReplenishController.java:165 | `clientList` (L164-168) | `orderList` (a real sibling handler, L171-176) | `clientList` | PASS |
| 18 | TruckLoadingController.java:64 | `truckLoadingInfo` (L63-67) | `truckLoadingInfo orderList` (mixed — carried its own name *and* a sibling's) | `truckLoadingInfo` | PASS |
| 19 | TruckLoadingController.java:128 | `scanGate` (L113-134) | `scanDestination` — not a live handler today, but was a real `MoveStockController` handler retired by SBDEV-2996 (`7393cfaf`, "retire the unreachable scanDestination endpoint"), so the mislabel was a genuine copy from a real sibling at the time it was written | `scanGate` | PASS |

None of the 19 moved from one wrong name to another wrong name — every new label matches its own
enclosing method's declared name exactly. **All 19 confirmed.**

Note on #1/#2 and #12/#13: the *old* labels (`scanSingleUnitLoad`, `scanParcel`) are each the
literal first path segment of the same handler's own `@GetMapping`/service call, not another
controller's handler name — a softer instance of the rule (label ≠ own **method** name) than the
handful of true cross-handler collisions (#11, #14/15, #16, #17, #19). Both are still correct fixes
per the stated rule ("a label must name its own method"); flagging only so the severity distinction
is explicit — these two did not previously misdirect a log grep to a *different* handler's traffic.

## 2. Format-string arity, every edited line

All 19 edits are string-literal-only changes; none touched the argument list. Verified each:

- Lines with `input`/`keyword`/`itemNumber`/`locationName` interpolation (1, 3, 5, 7, 9, 12, 14):
  exactly one `{}` and exactly one trailing arg, both before and after. PASS.
- All `"... finished"` / `"... start"` lines (2, 4, 6, 8, 10, 11, 13, 15, 16, 17, 18, 19): zero `{}`,
  zero args, both before and after. PASS.

**No arity regressions in any of the 19 edits.**

## 3. Over-reach check

`git diff origin/develop` touched exactly 8 files: `CLAUDE.md` plus the 7 controllers listed above.
Grepping the full diff for added/removed lines that are *not* `LOG.` calls turns up only the new
CLAUDE.md prose paragraph — zero non-log code lines were touched in any controller. No signature,
mapping, import, or logic line was changed. No already-correct label was touched: every one of the
19 "before" values differs from its enclosing method's name (see table above); none were fixed that
didn't need it. **PASS.**

## 4. Under-reach check (independently re-derived, not reusing the author's list)

Built the full method-name set for each of the 11 controllers in `controller/mobile/` from
`grep -n "public ResponseEntity" *.java` (`CycleCountLosController`, `LookupController`,
`MoveStockController`, `MoveUnitloadController`, `OrderCancellationController`,
`PalletizingController`, `PickingController`, `PutawayController`, `ReplenishController`,
`TransferOrderController`, `TruckLoadingController` — 11 confirmed), then pulled every
`LOG.(debug|info|warn|error|trace)` line in the package (~70 lines) and checked each one's full
label text — not just its first token — against every method name declared anywhere in the package.

Result: after the 19 fixes, **zero** remaining `LOG` lines contain a token that names a *different*
declared handler method anywhere in the 11 controllers. Checked in particular:
- `PickingController` (11 handlers, already fixed under the prior merged PR #263 / commit
  `d5a0d19f`, which is inside this branch's base `2d56ac4c`) — every label matches its own method.
- `MoveStockController`, `TransferOrderController` (untouched by this diff) — every label already
  matched its own method; no missed defects there.
- `ReplenishController` — 10 other handlers besides the fixed `clientList`, all already correct.
- The `PutawayController`/`ReplenishController` shared name `requestLocation` (documented two
  paragraphs above this diff, in the "6 handler method names ... shared" note) — both controllers'
  `requestLocation` correctly log their own name; the shared name is a known, accepted (not a
  defect) cross-controller collision, distinct from the mislabeling class this ticket fixes.

**No outstanding mislabels found. Under-reach check PASSES** — the author's 19-item set is complete.

## 5. Judgment on the 10 deliberately-unchanged labels — DISAGREE with how the line is drawn

Enumerating every verb-first / non-self-first label still in the tree (excluding the 19 just fixed)
gives exactly 10, matching the doc's count:

| Label | File:line | Enclosing method | Contains own method's name? |
|---|---|---|---|
| `"start orderList"` | CycleCountLosController.java:184 | `orderList` | yes |
| `"start locationList"` | CycleCountLosController.java:191 | `locationList` | yes |
| `"start unitLoadList"` | CycleCountLosController.java:198 | `unitLoadList` | yes |
| `"end  count OK, with 13_unitLoad"` | CycleCountLosController.java:297 | `recountUnitLoad` | **no** |
| `"end   location finished, with 12_location"` | CycleCountLosController.java:302 | `recountUnitLoad` | **no** |
| `"end   cycle count order finished, with 1_select"` | CycleCountLosController.java:307 | `recountUnitLoad` | **no** |
| `"Failed to release unit load back to putaway lane after error"` | PutawayController.java:54 | `requestLocation` | **no** |
| `"Failed to release unit load back to putaway lane after error"` | PutawayController.java:61 | `requestLocation` | **no** |
| `"start orderList"` | TransferOrderController.java:50 | `orderList` | yes |
| `"start orderList"` | TruckLoadingController.java:50 | `orderList` | yes |

**5 of the 10 satisfy the doc's stated rule** ("verb-first form is also fine provided the method's
own name appears"). **The other 5 do not** — the `recountUnitLoad` step markers name workflow
states (`13_unitLoad`, `12_location`, `1_select`), not the method, and the two `PutawayController`
warnings name the recovery action, not `requestLocation`.

None of these 5 are *harmful* in the sense this ticket fixes — none of them name a *different*
handler, so none misdirect a log grep to the wrong endpoint's traffic. That's a defensible reason to
leave them alone. But it is not the reason the CLAUDE.md paragraph gives, and the paragraph states
its criterion as a hard "provided": a reader who takes that sentence literally and then greps
`recountUnitLoad` in the logs will still get zero hits for these three status lines, and a reader
grepping `requestLocation` gets zero hits for the two warnings. That's an omission (missing from a
targeted grep), not a misattribution (returned to the wrong grep) — a real but different failure
mode than the one being fixed here, and one the doc's own rule claims doesn't exist in this set.

**Recommendation:** either (a) loosen the CLAUDE.md wording to state the actual criterion applied
("must never name a *different* handler; a pure status/warning line that names no handler is also
acceptable"), or (b) add the enclosing method's name to these 5 lines for full consistency. Not
blocking — no functional defect — but the doc oversells the audit as applying one test uniformly
when it applied two different (both reasonable) tests to different subsets of the 10.

## 6. CLAUDE.md paragraph — factual accuracy against the code

| Claim | Verified |
|---|---|
| "19 labels in 7 controllers" | Confirmed exactly: `CycleCountLosController` (2), `LookupController` (8), `MoveUnitloadController` (1), `PalletizingController` (2), `PutawayController` (3), `ReplenishController` (1), `TruckLoadingController` (2) = 19. |
| "Measured across the 11 mobile controllers" | Confirmed: 11 `*.java` files under `controller/mobile/`. |
| "the largest cluster was `LookupController` ... four of its five handlers logged `search`" | Confirmed: 5 handlers (`search`, `searchSku`, `stockListByItemNumber`, `unitLoadListByLocationName`, `locationByLocationName`); `search` itself logs correctly, the other 4 all previously logged `"search ..."`. |
| "`search` is itself a real sibling endpoint (`GET /search/{keyword}`)" | Confirmed: `LookupController.java:41-42`, `@GetMapping(path="/search/{keyword}") ... search(...)`. |
| "`PutawayController.requestLocation` logged `scanPallet`" | Confirmed (table row 14/15). Note: `scanPallet` is also a real handler in **two** other controllers (`PalletizingController.scanPallet`, `TruckLoadingController.scanPallet`), so this was a genuine cross-controller collision, not just a path-segment echo. |
| "`MoveUnitloadController.selectStock` logged `selectSource`" | Confirmed (row 11); `selectSource` is a real sibling handler in the same file and also in `MoveStockController`. |
| "`PalletizingController.scanUnitLoad` logged `scanParcel`" | Confirmed (rows 12/13). Caveat: no controller declares a handler literally named `scanParcel` (checked via grep across `controller/`); `scanParcel` is this handler's own path segment / the underlying service-method name it calls (`mobilePalletizingService.scanParcel(dto)`), not a different live handler. Still a correct fix under the "must name its own method" rule, but weaker evidence for the "sends a grep to a different endpoint" framing than the other three "elsewhere" examples. |
| "`TruckLoadingController.scanGate` logged `scanDestination`" | Confirmed (row 19). `scanDestination` is not a live handler today but *was* a real `MoveStockController` handler, retired under SBDEV-2996 (commit `7393cfaf`) before this ticket — so the mislabel did once point at a real sibling. |
| "Worst of the set: `unitLoadListByLocationName` logged `\"search stockListByItemNumber finished\"` — a different endpoint's name" | Confirmed verbatim in the pre-fix diff hunk; `stockListByItemNumber` is a real, distinct sibling handler. Correctly identified as the worst case (double mislabel: neither `search` nor `stockListByItemNumber` is this handler's own name). |
| "10 such labels were audited and deliberately left alone" | Count confirmed exactly (see §5). Criterion accuracy: see §5 finding — 5 of 10 don't actually satisfy the stated "own name appears" test. |

No wrong counts or fabricated examples found. The one accuracy gap is the §5 finding: the paragraph
implies a single uniform test was applied to all 10 "left alone" labels, when in fact two different
(both defensible) tests were applied to two different subsets.

## Per-item pass/fail summary

| Item | Result |
|---|---|
| 1. Every edit individually verified | **PASS** (19/19) |
| 2. Format-string arity | **PASS** (19/19, zero regressions) |
| 3. Over-reach | **PASS** (only `LOG.` lines + CLAUDE.md prose touched) |
| 4. Under-reach (independent re-derivation) | **PASS** (zero remaining mislabels across all 11 controllers) |
| 5. Judgment on the 10 left-alone labels | **DISAGREE (Low)** — 5 of 10 don't meet the doc's own stated criterion; not a runtime bug, but the doc's audit description overclaims |
| 6. CLAUDE.md factual accuracy | **PASS with two Low caveats** — `scanParcel` and `scanSingleUnitLoad`-type cases are framed alongside true cross-handler collisions when they're actually the softer "matches own path/service-call, not own method" variant |

## Findings, severity-rated

- **Low** — CLAUDE.md's "10 such labels were audited and deliberately left alone ... provided the
  method's own name appears" overstates uniformity: 5 of the 10 (`CycleCountLosController.java:297,302,307`,
  `PutawayController.java:54,61`) do not contain their enclosing method's name. No functional impact;
  recommend rewording the criterion or naming the method in those 5 lines. (§5)
- **Low** — Two of the four "elsewhere" examples in the new paragraph (`scanParcel` in
  `PalletizingController.scanUnitLoad`, and the unlisted `scanSingleUnitLoad` in
  `CycleCountLosController.processScanUnitLoad`) are framed identically to true cross-handler
  collisions, but are actually mislabels against the handler's own path segment / called service
  method, not a different live controller handler. The fixes themselves are still correct; only the
  doc's rhetorical framing slightly overstates the misattribution risk for these two. (§1, §6)

No Medium or High findings. No behavior, signature, or non-log-string changes found anywhere in the diff.

---
**File:** `/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3016-evidence/loggers-review-lane-a.md`
**Verdict: APPROVE WITH CHANGES**
