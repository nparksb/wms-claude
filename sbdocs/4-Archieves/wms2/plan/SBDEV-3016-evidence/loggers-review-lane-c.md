# SBDEV-3016 — Review Lane C: 12 non-mobile logger label edits

**Scope**: exactly the 12 `LOG.*` label edits listed in the task, across 7 files in
`controller/` and `service/` (excluding `controller/mobile/`, which lane A/B already covered).
Base commit `2d56ac4c`. Worktree read-only; no `mvn`, no writes.

Diff command used:
```
git diff 2d56ac4c -- src/main/java/net/aim_ai/wms/controller src/main/java/net/aim_ai/wms/service
```
Confirmed the diff contains exactly 12 hunks in the 7 named files, matching the task table
1:1 (plus the already-reviewed 19 mobile edits, which this report ignores).

The worktree's own `CLAUDE.md` documents this exact sweep (31 labels across 14 files, 3
categories) and independently corroborates the "different live handler" / "sibling in the
same class" characterization used below — cited as corroboration, not as a substitute for
reading the code.

## Verdict: APPROVE WITH CHANGES

All 12 assigned edits are correct, arity-safe, and free of the StockUnitController-style
false-positive error. However, **item 5 (under-reach) found 5 additional mismatched labels
in one of the same 7 files (`UserController.java`) that are not part of this edit set and
remain unfixed.** They are real instances of the same defect class this ticket exists to
close, sitting in files this ticket already touched. Recommend they be added to SBDEV-3016
(sub-T3 fix, same file already dirty) before this branch ships, per the "findings go on the
existing ticket" policy — flagging here rather than filing a new ticket since the ticket is
still in flight (not `on dev` or later).

---

## Per-item findings

### 1. Enclosing method (brace-matched, not line-proximity)

| # | File:Line | Enclosing method (verified) | New label names it correctly? |
|---|---|---|---|
| 1 | CustomerOrderBatchController.java:71 | `batchUpdatePriorityByBatchIds` (decl. :70) | Yes |
| 2 | CustomerOrderController.java:92 | `pickingDateBatchUpdate` (decl. :91) | Yes |
| 3 | CustomerOrderController.java:117 | `batchUpdatePriorityByOrderIds` (decl. :116) | Yes |
| 4 | ReceivingController.java:299 | `createPallet` (decl. :297) | Yes |
| 5 | ReplenishOrderController.java:283 | `create` (decl. :282) | Yes |
| 6 | ReplenishOrderController.java:343 | `stockUnitInfoForReplenishment` (decl. :342) | Yes |
| 7 | UnitLoadController.java:109 | `deleteContainer` (decl. :102) | Yes |
| 8 | UnitLoadController.java:144 | `bulkDeleteContainer` (decl. :137) | Yes |
| 9 | UnitLoadController.java:178 | `deleteContainerRecursive` (decl. :177) | Yes |
| 10 | UnitLoadController.java:237 | `childrenUnitloads` (decl. :236) | Yes |
| 11 | UserController.java:675 | `getUserDetails` (decl. :672) | Yes |
| 12 | KeycloakService.java:741 | `createSingleUserWithTempPassword` (decl. :739) | Yes |

**Result: PASS, all 12.** None swaps one wrong name for another; each new label matches the
method whose brace scope actually contains it. Verified by reading full method bodies (not
just the touched line) for all 7 files — no nested inner classes or blocks in any of these
classes that would make line-proximity misleading, but brace-matched anyway per instruction.

### 2. Arity

| # | File:Line | `{}` count | vararg count | Match? |
|---|---|---|---|---|
| 1 | CustomerOrderBatchController.java:71 | 1 | 1 (`reqMap.toString()`) | Yes |
| 2 | CustomerOrderController.java:92 | 1 | 1 | Yes |
| 3 | CustomerOrderController.java:117 | 1 | 1 | Yes |
| 4 | ReceivingController.java:299 | 1 | 1 | Yes |
| 5 | ReplenishOrderController.java:283 | 0 | 0 | Yes |
| 6 | ReplenishOrderController.java:343 | 1 | 1 (`id`) | Yes |
| 7 | UnitLoadController.java:109 | 1 | 1 (`id`) | Yes |
| 8 | UnitLoadController.java:144 | 1 | 1 (`ids.length`) | Yes |
| 9 | UnitLoadController.java:178 | 1 | 1 (`id`) | Yes |
| 10 | UnitLoadController.java:237 | 1 | 1 (`parentId`) | Yes |
| 11 | UserController.java:675 | 0 | 0 | Yes |
| 12 | KeycloakService.java:741 | 0 | 0 | Yes |

**Result: PASS, all 12.** No `{}`/vararg mismatch introduced by any edit.

**On line 144 specifically**: old label was `"start reprintLabel unitload={}"` logging
`ids.length` — already wrong on two axes (wrong method name AND `unitload=` labeling a count).
New label `"start bulkDeleteContainer count={}"` fixes both: `count={}` accurately describes
`ids.length` (an `int`, the size of the id array being bulk-deleted), which is strictly more
accurate than the old `unitload=` framing that implied a single unit-load identifier. This is
a genuine improvement, not merely a rename.

### 3. Semantic accuracy of new wording

11 of 12 read well and are appropriately specific for a DEBUG-level entry/exit trace.

**Low — ReplenishOrderController.java:283, `"start create"`.** Technically correct (names the
enclosing method) but carries zero diagnostic payload — the handler takes a
`ReplenishMobileOrderDto order` parameter that isn't logged at all, unlike sibling handlers in
the same file that log at least an id (`"start cancelReplenishOrder orderId={}"` at :200,
`"start loadOrderByDestination locationName={}"` at :225). A more useful label would be
`"start create clientId={}"` or similar. That said, this is consistent with the *existing*
local convention in this same file — four other untouched handlers in
`ReplenishOrderController` (`update`, `updateStockUnit`, `changeSourceStockUnit`) log the
equally generic `"start action unitload={}"` — so this edit isn't introducing a new low bar,
just matching one already present. Not a blocker; worth a follow-up polish pass if the team
wants richer replenish-order tracing generally, not specific to this ticket.

Everything else (UserController:675 `"getUserDetails start"`, KeycloakService:741 `"Beginning
createSingleUserWithTempPassword"`, all four UnitLoadController edits, both
CustomerOrderController edits, the CustomerOrderBatchController edit, ReceivingController:299,
ReplenishOrderController:343) is specific, accurate, and reads at least as well as neighboring
untouched labels in the same file.

### 4. Over-reach

Re-examined the full diff hunks for all 7 files: every hunk is a single-line change inside a
`LOG.debug(...)` or `LOG.info(...)` string literal. No signature changes, no logic changes, no
added/removed lines besides the label text itself, and no changes to any file outside the 7
named ones (`git diff --stat` limited to `controller/` + `service/` shows only the 7 files
plus the already-reviewed mobile controllers).

**Result: PASS.** No over-reach in the 12 assigned edits.

### 5. Under-reach — independent scan of the 7 touched files for remaining mismatched labels

Grepped every `LOG.debug/info/warn/error/trace` call in all 7 files and checked each against
its enclosing method.

**CustomerOrderBatchController.java, CustomerOrderController.java, ReceivingController.java,
ReplenishOrderController.java, UnitLoadController.java, KeycloakService.java: clean.** Every
remaining label either (a) already names its own enclosing method correctly (e.g.
`ReceivingController:244` `"start createAndSelectPallet..."` inside the real
`createAndSelectPallet` method — correctly left alone), or (b) is verb-first/name-free per the
project's stated rule (`"start action unitload={}"`, `"Response: status:{}"`, generic error
messages) and therefore cannot misdirect a grep.

**UserController.java: NOT clean — 5 additional mismatched labels found, none of them in the
assigned 12, all pre-existing (not touched by this branch's edits):**

| File:Line | Enclosing method | Label says | Problem |
|---|---|---|---|
| UserController.java:358 | `importUser` (decl. :321) | `"end   create user with errors: {}"` | Names `createUser`, a different live handler (:366) |
| UserController.java:392 | `createUser` (decl. :366) | `"import user - update"` | Names `importUser`, a different live handler (:321) |
| UserController.java:428 | `updateUser` (decl. :425) | `"create user: {}"` | Names `createUser`, a different live handler (:366) |
| UserController.java:472 | `updateUser` (decl. :425) | `"end   create user"` | Names `createUser`, a different live handler (:366) |
| UserController.java:475 | `updateUser` (decl. :425) | `"end   create user with errors: {}"` | Names `createUser`, a different live handler (:366) |

`importUser`, `createUser`, and `updateUser` are near-duplicate method bodies (same
try/catch/error-map shape), and the debug labels were evidently copy-pasted across all three
without renaming — the same defect class this ticket is fixing elsewhere (e.g. the
`LookupController`/`UnitLoadController` clusters lane A/B reviewed), just not yet caught in
this file. This is the **"a different live handler"** category (the worst of the three per
the CLAUDE.md rule), not the harmless "sibling in the same class" or "calls a service of that
name" categories — a grep for `createUser`'s traffic will pick up noise from both `importUser`
and `updateUser`.

**Recommendation**: since `UserController.java` is already part of this ticket's changed-file
set and this is a same-shape one-line label fix (T0/T1, no logic change), it should be folded
into SBDEV-3016 now rather than filed as a separate ticket — consistent with the "findings go
on the existing ticket" policy for sub-T3 issues, and the ticket is not yet `on dev` so the
carve-out doesn't apply. Flagging here for the team lead/implementer to add; not fixing it
myself (read-only remit, no edits authorized in this worktree).

### 6. False-positive category check (the StockUnitController:544/:590 `printLabel`-as-parameter trap)

Checked all 12 old labels against the codebase to confirm each really was a **method name**
being referenced (a genuine collision), not a parameter/field/column name that happens to look
like one:

- `"priorityBatchUpdate"` (×3, two files) — real method `CustomerOrderBatchController.priorityBatchUpdate` (:44). Genuine method-name collision, not a field.
- `"createAndSelectPallet"` — real method `ReceivingController.createAndSelectPallet` (:242). Genuine.
- `"getPickableLocations"` — real method `ReplenishOrderController.getPickableLocations` (:245). Genuine.
- `"replenishorderDetailsById"` — real method `ReplenishOrderController.replenishorderDetailsById` (:336). Genuine.
- `"reprintLabel"` (×3) — real method `UnitLoadController.reprintLabel` (:69). Genuine.
- `"unitloadDetailsById"` — real method `UnitLoadController.unitloadDetailsById` (:230). Genuine.
- `"getAllRoles"` — real method `UserController.getAllRoles` (:624), itself a legitimate,
  correctly-labeled sibling handler (self-scoped via `denyUnlessSelf`). Genuine.
- `"createSingleUser"` — real method `KeycloakService.createSingleUser` (:689). Genuine.

**Result: PASS, all 12.** No instance of the StockUnitController category error (a
parameter/field name in the message text mistaken for a method reference). Every one of the 12
old labels named a real sibling or cross-controller method, so every edit is a legitimate fix
of a genuine collision, not damage to a message that was correctly using a field/parameter
name.

---

## Summary

| Item | Result |
|---|---|
| 1. Enclosing method | PASS (12/12) |
| 2. Arity | PASS (12/12) |
| 3. Semantic accuracy | PASS with 1 Low (ReplenishOrderController:283 `"start create"` — generic but consistent with sibling convention) |
| 4. Over-reach | PASS — no non-`LOG.*` changes in the 7 files |
| 5. Under-reach | **FAIL for UserController.java** — 5 pre-existing mismatched labels found (:358, :392, :428, :472, :475), same defect class, not part of this edit set |
| 6. False-positive category check | PASS (12/12) — no StockUnitController-style param/field misclassification |

**Verdict: APPROVE WITH CHANGES.** The 12 assigned edits are all correct and should not be
reverted or altered. The gap is scope, not correctness of what was done: the sweep that
produced these 12 edits missed 5 same-defect-class labels in one of the same 7 files. Add them
to this ticket before merge.
