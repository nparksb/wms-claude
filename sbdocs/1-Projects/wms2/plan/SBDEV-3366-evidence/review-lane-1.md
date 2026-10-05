# SBDEV-3366 Code Review — Lane 1

**Scope:** `app/Services/Legacy/LegacyInventoryAdjustService.php` (`applyInventoryQuantities`) in `v2/oms-laravel-api`, plus its test file. Diff reviewed at `/private/tmp/claude-503/-Users-np1076-dev-spk-owl/1feb43a9-d9cc-4c55-a384-f78400b95f2a/scratchpad/sbdev-3366.diff`; pre/post full method read from `svc.head`/`svc.bak` in the same dir. Cross-checked against `origin/develop` of `v2/wms2-api` (all 20 real call sites of `SharedService.getStockChangeDTO`) and `v2/oms-laravel-api` (all callers of `applyInventoryQuantities`/`processWMSUpdate`).

**lsp_diagnostics:** not run — this worktree (`.claude/worktrees/oms-laravel-api/SBDEV-3366`) is explicitly off-limits (a test run is swapping files in it), and `php` is not on `PATH` in this session to lint the scratchpad copies directly (`command not found: php`). Correctness below is established by manual trace of every call site instead; per project memory (`oms-laravel-api-has-no-runnable-test-env.md`) this repo has no locally runnable test environment anyway, so this gap is expected and pre-existing, not something this PR could have closed.

## Stage 1 — Spec compliance

The ticket claims: WMS sends a GROSS physical delta in `normal` on the incremental (`stockUpdate`, `$addToExisting=true`) path, and OMS must net `quantity_on_hand` down to SELLABLE stock on that path exactly as it already does on the absolute/count path. The diff removes the `!$addToExisting &&` guard so the same three-bucket subtraction (`damaged`, `missing`, `on_hold`) runs unconditionally, and rewrites the comment to explain why. This is a one-line semantic change plus a comment/test rewrite — it matches the stated intent. **Spec compliance: PASS.**

## Stage 2 — Code quality / logic

### Verified: netting is correct for every real wms2 caller (check #1)

I enumerated every non-definition call site of `getStockChangeDTO` on `origin/develop` of `v2/wms2-api` (20 sites across `GoodsReceiptPositionService`, `ReceivingService`, `StockunitService`, `UnitloadService`, `MobileCycleCountService`, `MobileMoveUnitloadService`) and hand-traced the netted result against the intended sellable-on-hand effect. All check out:

- Pure receiving (`GoodsReceiptPositionService.java:113,179`, `ReceivingService.java:600,605`): `total=N, damaged=missing=onHold=0` → net delta `= N`. Correct, no bucket involved.
- Pure bucket moves, `normal=0` (`StockunitService.java:641,755,838,988,991`; `MobileMoveUnitloadService.java:773,812`): e.g. good→damaged is `(0, +N, 0, 0, 0)` → net delta `= -N` on-hand, `+N` damaged. A damaged/on-hold **release** is `(0, -N, 0, 0, 0)` or `(0,0,0,-N,0)` → net delta `= +N` on-hand, bucket decreases by N. This is exactly the shape the rewritten comment claims ("arrives as normal 0 / damaged ±N").
- `UnitloadService.java:602` (manual removal, the one flagged for sign-semantics in the task): `getStockChangeDTO(itemData, amount.negate(), damaged, 0, on_hold, 0, ...)` where `damaged`/`on_hold` are pre-computed to equal `amount.negate()` *iff* the deleted stock unit was already in that lock state, else `0`. Traced all three cases:
  - `QUALITY_FAULT` unit, amount=5 deleted: `total=-5, damaged=-5` → net `= -5 - (-5) = 0`. Correct: the unit was already excluded from sellable on-hand (damaged), so deleting it changes only the damaged bucket (`-5`), not sellable stock.
  - `ON_HOLD` unit, amount=5 deleted: `total=-5, on_hold=-5` → net `= 0`. Same reasoning.
  - Unlocked unit, amount=5 deleted: `total=-5, damaged=on_hold=0` → net `= -5`. Correct: a genuinely sellable unit disappearing must reduce sellable on-hand by the full amount.
  All three are correct under netting — this is a real sign-semantics validation, not a coincidence.
- `StockunitService.java:887,890,893` (`adjustAmount`/manage-inventory, the other flagged site): `diff = newAmount - oldAmount` on a *locked* stock unit. `ON_HOLD`: `(diff, 0, 0, diff, 0)` → net `= diff - diff = 0` (an on-hold unit's amount changing doesn't touch sellable stock; the on-hold bucket absorbs the whole diff). `QUALITY_FAULT`: `(diff, diff, 0, 0, 0)` → net `= diff - diff = 0`, same reasoning. `NOT_LOCKED`: `(diff, 0, 0, 0, 0)` → net `= diff`, correct for a genuinely sellable unit. Also correct.
- `MobileCycleCountService.java:239,452`: `(diff, 0,0,0,0)`, pure recount, correct.

I could not find a single wms2 call site where netting produces the wrong sellable-on-hand delta. **This is strong, call-site-by-call-site evidence the fix is correct**, not just correct on the two examples in the ticket.

One caveat: none of the 20 sites ever pass a non-zero `missing` argument — `missing` is always literally `0` in every `getStockChangeDTO` call in `src/main`. The new `bucketMoveProvider` "good -> missing" test case (`normal:0, missing:+2`) exercises a shape the WMS has never actually sent. Not a defect — the code path is still correct and worth having tests for — but the comment's blanket claim ("every wms2 SharedService.getStockChangeDTO caller ... arrives as normal 0 / damaged ±N") is really only demonstrated for `damaged`/`on_hold`; the `missing` bucket is netted symmetrically by construction, not by an observed caller. See LOW finding below.

### Verified: no other OMS caller relies on non-netting (check #2)

`git grep -n "applyInventoryQuantities("` in `oms-laravel-api` finds exactly two call sites: `processWMSUpdate` (line 730, `addToExisting=true`) and `processStockCounts`'s per-record handler (line 891, `addToExisting=false`). `processWMSUpdate` is only reached from `processStockUpdates`, which is only reached from `LegacyInventoryController.php:320` (`/call/inventory/stockUpdate`), which is WMS-only per the route's own docblock. There is no second incremental-path caller in this codebase to regress. **No regression found for check #2.**

### MEDIUM — netting uses the pre-clamp payload delta, but bucket columns are clamped afterward, so an over-large release can mint phantom sellable stock

File: `app/Services/Legacy/LegacyInventoryAdjustService.php` (post-fix, `svc.bak:1058-1067`)
```php
if (array_key_exists('quantity_on_hand', $quantities)) {
    $quantities['quantity_on_hand'] = (int) $quantities['quantity_on_hand']
        - (int) ($quantities['quantity_damaged'] ?? 0)
        - (int) ($quantities['quantity_missing'] ?? 0)
        - (int) ($quantities['quantity_onhold'] ?? 0);
}

foreach ($quantities as $column => $value) {
    $newValue = $addToExisting ? ((int) $inventory->{$column} + (int) $value) : (int) $value;
    $inventory->{$column} = max(0, $newValue); // inventory can never go negative
}
```
The netting subtraction reads the **raw payload deltas** (`$quantities['quantity_onhold']` etc., straight off the wire). The bucket columns themselves are only clamped to zero *after*, in the loop, independently per column. If a bucket's payload delta is larger in magnitude than what that bucket currently holds (data drift between WMS and OMS, a duplicate/out-of-order release message, etc.), the two clamp domains disagree:

**Concrete scenario:** OMS's `quantity_onhold` is currently `2` (already drifted low vs. WMS's real state). WMS legitimately releases 4 on-hold units (`normal:0, on_hold:-4`). Netting computes `on_hand delta = 0 - 0 - 0 - (-4) = +4` (uses the raw `-4`), so `quantity_on_hand` gains `+4`. But the bucket loop computes `onhold = max(0, 2 + (-4)) = max(0, -2) = 0` — clamped, so the bucket only actually lost `2`. The row now shows on-hand up by 4 while only 2 units ever left the on-hold bucket: **2 phantom sellable units** appear that were never in any bucket on this row, and `quantity_available` (derived from the now-inflated on-hand in `applyReconciledCounters`) can let those phantom units be allocated to a real order — i.e. this can contribute to overselling.

This exact failure mode did not exist on the incremental path before this fix, because pre-fix the `!$addToExisting` guard meant `quantity_on_hand` was never touched by bucket deltas at all on this path — so there was nothing for the bucket clamp to disagree with. It is a real, new side effect of doing the netting unconditionally, triggered only when a bucket's payload delta exceeds that bucket's current stored value (a drift precondition, not the common case — none of the 20 real call sites send a bucket delta that isn't tied to a specific already-tracked stock unit's own amount, so this needs WMS/OMS state to already disagree before the message arrives). Given this repo's own memory notes document recurring WMS↔OMS drift issues (outbox dispatcher gaps, sync loss, etc.), this is not a purely theoretical precondition.

**Fix suggestion:** compute the netting subtraction from the *applied* (post-clamp) bucket deltas instead of the raw payload — i.e. move the on-hand netting to after the bucket columns are written, using `$inventory->{$column} - $originalQuantities[$column]` for each bucket the same way `$appliedDeltas` is already computed a few lines below (`svc.bak:1097-1102`). That already-computed value would make on-hand's netting internally consistent with what actually landed in each bucket.

Severity: MEDIUM (requires a pre-existing drift precondition; not exercised by any of the 20 real call sites in normal operation; can contribute to overselling when it does trigger). Confidence: HIGH (the code-level mismatch is deterministic and directly demonstrable from the quoted lines; the only uncertain part — how often OMS/WMS bucket state actually drifts in production — is not needed to establish the defect exists).

### LOW — comment's "every ... caller" claim is demonstrated for damaged/on_hold, not for missing

File: `app/Services/Legacy/LegacyInventoryAdjustService.php:1054` (post-fix)
```php
// as normal 0 / damaged -N) — every wms2 SharedService.getStockChangeDTO
// caller, and v1 production message history since 2022. Only netting
```
Verified true for `damaged` and `on_hold` (see Stage-2 analysis above — every real call site's shape checks out). No `getStockChangeDTO` call site in `origin/develop` of `v2/wms2-api` ever passes a non-zero `missing` argument, so "every ... caller" is not actually demonstrated for the `missing` bucket — it's netted correctly by construction/symmetry, but there is currently no live caller to validate it against. Not a logic defect (the new `bucketMoveProvider` "good -> missing" test case is correct arithmetic either way), just an overbroad completeness claim in the comment. Confidence: HIGH (grep-verified absence of any non-zero `missing` argument in `src/main`).

**Separately, "v1 production message history since 2022"** is an unverifiable-from-this-review historical claim (would require querying a tenant's `product_update_history`/message log, out of scope for a code-only review). Flagging under Open Questions rather than as a blocking finding.

### LOW — a payload that omits the `normal`/`quantity_on_hand` key entirely still skips netting

File: `app/Services/Legacy/LegacyInventoryAdjustService.php:713,718` (post-fix) and `:1058`
```php
$onHand = $update['normal'] ?? $update['quantity_on_hand'] ?? null;
...
if ($onHand !== null) { $raw['quantity_on_hand'] = $onHand; }
```
paired with the netting guard `if (array_key_exists('quantity_on_hand', $quantities))`. If a caller sends only bucket keys (e.g. `damaged` alone, no `normal`/`quantity_on_hand` key at all — distinct from sending `normal:0`), the netting block never runs and the bucket still gets applied without touching on-hand. Confirmed not reachable from any of wms2's 20 call sites — `StockChangeDto` is `@JsonInclude(Include.NON_EMPTY)` over `Integer` fields, and Jackson's NON_EMPTY treats a boxed `0` as present (only `null` is dropped), and every Java call site passes a primitive `int` (never null) for `total`/`normal`. So this is unreachable from the WMS today. It could be reached by the "legacy wrapped payload shape" the surrounding comment mentions being kept alive for compatibility (`$update['quantity_damaged']` etc. as aliases) if any caller other than wms2-api ever POSTs a bucket-only payload. Flagging as an open question rather than a finding since no such caller was found. Confidence: LOW (no evidence a caller does this; noting for completeness per the "surface every finding" instruction).

### Verified: alert/history downstream logic (check #3) — netting change is a genuine improvement, not a regression

`applyInventoryQuantities` computes `$appliedDeltas[$column] = $inventory->{$column} - $originalQuantities[$column]` (post-clamp, post-netting) for the `product_update_history` row and the `InventoryAdjustmentAlert` payload (`InventoryAdjustmentAlertDispatcher.php:62-77`). Before this fix, a pure bucket move (`normal:0, damaged:+N`) left `quantity_on_hand` completely untouched on the incremental path, so both the history row and the real-time alert would have reported **zero** on-hand change for what should be a `-N` sellable-stock event — a silent under-report. After this fix they correctly report `-N`. This is a real behavioral improvement, not a side effect to worry about.

Same conclusion for `InventoryReallocationDispatcher::onIncrease` (`processStockUpdates`, `svc.bak` around `:505-540`, gated on `availability_increased`): a damaged/on-hold **release** (`normal:0, damaged:-N`) now correctly raises `quantity_available`, which correctly triggers re-evaluation of parked/exception orders for that product+facility. Pre-fix this reallocation trigger was silently missed for release events. Positive side effect, not a regression — but note it compounds with the MEDIUM clamp finding above: if a release event is the kind of over-large/drifted delta described there, the "phantom" availability increase would *also* incorrectly wake up the reallocation dispatcher.

### Verified: `max(0, ·)` clamp interaction (check #4)

Covered above as the MEDIUM finding — the clamp is the mechanism the defect rides on. No other clamp-related issue found; the `quantity_on_hand` self-clamp (`max(0, on_hand + netted_delta)`) is internally consistent (the clamp and the value it's clamping are the same figure), unlike the cross-column bucket-vs-on-hand mismatch above.

### Test adequacy (check #6)

The pinning test flip (`test_stock_update_adds_deltas_from_wms_bare_array`) and the new `bucketMoveProvider` cases are arithmetically verified against the fixture seed (`quantity_on_hand=100, quantity_damaged=5, quantity_onhold=10, quantity_missing=2, quantity_in_transfer=3`, set in `setUp()`):
- good→damaged (`damaged:+3`): expected `on_hand=97, damaged=8`. Net `=0-3-0-0=-3` → `100-3=97` ✓, `5+3=8` ✓.
- damaged release (`damaged:-3`): expected `on_hand=103, damaged=2`. Net `=+3` → `103` ✓, `5-3=2` ✓.
- on-hold release (`on_hold:-4`): expected `on_hand=104, onhold=6`. Net `=+4` → `104` ✓, `10-4=6` ✓.
- good→missing (`missing:+2`): expected `on_hand=98, missing=4`. Net `=-2` → `98` ✓, `2+2=4` ✓.
- Main test (`normal:10, damaged:1, on_hold:2, missing:3, transfer:4`): net `=10-1-2-3=4` → `100+4=104` ✓; `transfer` un-netted `3+4=7` ✓.

All test math is correct, and the transfer-is-never-netted assertion is exercised. **Gap:** no test covers the MEDIUM finding above — a bucket delta whose magnitude exceeds the bucket's current stored value (the clamp-order mismatch). Given this is a real, if edge-case, defect, I'd ask for at least one regression test pinning the *current* (arguably wrong) behavior or the fixed behavior once addressed.

## Positive observations

- The rewritten comment is a substantial improvement — it states the *mechanism* (bucket moves don't change physical count) rather than just the conclusion, and that mechanism is what let me validate all 20 call sites quickly.
- The fix is a genuinely minimal, surgical diff: one guard condition removed, nothing else in the 1247-line file touched.
- `quantity_in_transfer` correctly stays un-netted, matching v1 and matching every call site (transfer is always passed as `0` by wms2 today, but the code doesn't rely on that).
- Test seed values were deliberately enriched (`missing`/`transfer` moved from `0`/`0` to `2`/`3` in `setUp` and `3`/`4` in the payload) specifically so the pinning test would have caught the pre-fix bug — good regression-test hygiene.
- `appliedDeltas`/history/alert plumbing already computes deltas from actual post-clamp state rather than the raw payload (see check #3) — the MEDIUM finding above is about the *on-hand netting* input, not this downstream reporting, which is done correctly.

## Open Questions (low-confidence findings — surfaced, not blocking)

- **[HIGH severity, LOW confidence]** "v1 production message history since 2022" (comment claim) is unverified by this review — would require querying live `product_update_history`/message logs. If false, it doesn't change the code's correctness, only the comment's credibility.
- **[LOW severity, LOW confidence]** A caller that sends bucket-only deltas with no `normal`/`quantity_on_hand` key at all would skip netting entirely. No such caller currently exists in wms2-api; flagged only because the surrounding comment explicitly keeps a "legacy wrapped payload shape" alias path alive for compatibility, and I could not enumerate every historical caller of this OMS endpoint.

## By Severity
- CRITICAL: 0
- HIGH: 0 (1 in Open Questions, low confidence)
- MEDIUM: 1
- LOW: 2

## Recommendation

**APPROVE** with a follow-up suggested (not blocking): address the MEDIUM clamp-order finding — net on-hand from the applied/post-clamp bucket deltas rather than the raw payload deltas — ideally with a regression test for the over-large-release scenario. The core fix is correct and validated against every real wms2 caller; the MEDIUM finding is a pre-existing-drift edge case, not a defect in the common path this ticket targets, and does not by itself justify blocking this specific, well-scoped change.
