# SBDEV-2996 — independent code review (review lane)

**Reviewer:** code-reviewer lane (independent; author did not self-approve)
**Date:** 2026-08-28
**Scope reviewed:**
- `.claude/worktrees/wms2-api/SBDEV-2996` — commit `90146e08`, branch `feature/SBDEV-2996-retire-move-stock-scan-destination`
- `.claude/worktrees/wms2-mobile-ui/SBDEV-2996` — commit `37e7823`, same branch name
- Uncommitted vault edits: `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md` (new §4.1), `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md` (`doesUserHaveAccess` re-measurement)

---

## Verdict: **APPROVE WITH FIXES**

The **code** change is correct, complete and well-tested. I re-derived the dead-code claim from scratch and it holds, including on the deployed branches the author did not check. The 8 dropped constructor dependencies are genuinely unused. Both absence-pin test suites are real — I mutation-checked them myself rather than taking the commit message's word, and every negative *and* every anchor fired exactly where it should.

Every fix below is in the **accompanying documentation** plus three small leftovers. The one that matters is M1: the new §4.1 guard table asserts four "gaps" on the live path and **three of the four guards are actually present**. That table, as written, would send a future reader to build guards that already exist and would keep SBDEV-2995 open for something that shipped.

No code changes are required. Nothing here blocks merge once M1 is corrected.

---

## Findings

### M1 — Medium · `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md:146–155` · **CONFIRMED**

The §4.1 table is headed *"Guards that lived **only** on the retired path, and so are absent from the live one — each is a real gap on `transferStock`, not something the retirement introduced"*. Three of its four rows are wrong.

| Row | Doc says | Reality |
|---|---|---|
| Destination is Nirvana | `no — tracked by SBDEV-2995` | **Present and ungated.** `StockunitService.transferStock:177` calls `destinationEligibilityService.assertCanReceiveStock(unitLoad)` on the existing-container branch; `DestinationEligibilityService:114–117` refuses `Nirwana` **outside** the `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` gate. The class javadoc states this in as many words: *"The Nirvana-sentinel refusal is NOT gated."* That is SBDEV-2995's fix, already shipped. |
| Source stock unit `ON_HOLD` | `no` | **Present, and broader than the retired check.** `StockunitBusinessService.transferStockToUnitLoad:293–297` throws whenever `sourceStockunit.getEntityLock() != NOT_LOCKED` and `ignoreLock == false` — which is what `transferStock` passes at `:197, :201, :237, :305`. The retired path checked `ON_HOLD` only. The two damaged branches (`:270, :276`) pass `ignoreLock=true` deliberately. |
| Destination must be a FLOWBIN when it is a Location | `no` | **Correct — genuinely absent.** But it is a capability difference, not a gap: `StockunitService:238–…` deliberately supports non-flowbin destination locations. The retired path's `"Destination is not a flowbin!"` refusal would be a regression on the live path, not an improvement. |
| Flowbin `FixLocationAssignment` SKU match | `no` | **Present.** `StockunitService:229–232` throws `"Flow bin has different SKU …"`. ⚠ Worth recording while correcting the row: `:229` compares `Long != Long` by reference, so for itemdata ids > 127 it always evaluates true and the guard **over**-rejects. Pre-existing, not introduced by this change, and the opposite failure mode from "absent". |

**Failure scenario:** a maintainer reads §4.1 as an authoritative gap list, files or executes work to add a Nirvana refusal and an `ON_HOLD` refusal to `transferStock` — both already there — and leaves SBDEV-2995 open against a shipped fix. The Nirvana row is the worst of the three because it names a live ticket.

**Suggested fix:** rewrite the three rows with the file:line evidence above and drop the "each is a real gap" framing; keep only the flowbin-restriction row, reworded as a deliberate divergence rather than a gap. If the table cannot be made accurate cheaply, delete it — §4.1 is complete and useful without it.

---

### L1 — Low · `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md:111, 117, 271` · **CONFIRMED**

Stale line pins in the section whose frontmatter (`:11`) now claims *"§4 re-verified 2026-08-28 against SBDEV-2996"*. The doc pins `selectSource()` at `[line 99]` and `selectStockUnit()` at `[line 191]`; at `origin/develop` they were `:106` / `:198`, and after this commit they are **`:70` / `:162`** (the constructor shrank by 36 lines above them). `:271` repeats `line 191`.

**Fix:** update to `:70` / `:162`, or drop the numeric pins in favour of symbol names. A "re-verified" stamp on drifted pins is worse than no stamp.

---

### L2 — Low · `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md:476` · **CONFIRMED**

The re-measurement note says SBDEV-2996 removed sites at `MobileMoveStockService:251, 256`. At `origin/develop` the two `doesUserHaveAccess` calls are at **`:252` and `:257`**. Off by one.

Everything else in that edit checks out — see "Verified clean" item 6 below.

---

### L3 — Low · `v2/wms2-api/src/test/.../unit/service/mobile/MobileMoveStockServiceTest.java:10, 52–53` · **CONFIRMED**

Scaffolding orphaned by the deleted tests and not swept:
- `:10` — `import net.aim_ai.wms.service.mobile.MobileMoveUnitloadService;` — the only occurrence of that symbol in the file.
- `:52–53` — `@Mock private FixLocationAssignment mockFixLocationAssignment;` — the only occurrence of that field.

Harmless at runtime (`@MockitoSettings(strictness = LENIENT)`, and an unused `@Mock` field is not a stubbing violation), but a ticket whose whole thesis is "delete what nothing reaches" should not leave two of these behind.

**Fix:** delete both.

---

### L4 — Low · `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:493, 545` · **CONFIRMED**

`setStockDamaged(Unitload)` and `removeStockDamaged(Unitload)` — the 1-arg overloads that delegate with `comment = null` — now have **zero `src/main` callers**. The deleted `selectDestination` was their last production caller; the surviving in-repo callers are four test sites (`MobileMoveUnitloadServiceTest:579, 613`, `MobileMoveUnitloadServiceUnitTest:562, 586, 610, 634`). Production reaches only the 2-arg forms, via `MobileMoveUnitloadService:306, 311`.

Not a defect — this is exactly the residue the ticket exists to remove, and the author's own rationale applies to it. Either delete the two overloads (and repoint those tests at the 2-arg form with an explicit `null`), or add one line saying they are kept as a test-only convenience. Flagging rather than demanding: deleting them widens the blast radius of a change that is currently very tightly scoped, and that trade is the author's call.

---

### L5 — Low · `v2/wms2-api/src/main/java/net/aim_ai/wms/util/StringConverter.java:47–51` · **CONFIRMED**

The revised javadoc says the varargs shape exists because *"palletizing and truck loading accept a label matching EITHER the string pattern OR the converted printing pattern, while a single-pattern caller passes just one."* After this deletion **no caller passes exactly one accept pattern**. The live shapes are:
- `MobilePalletizingService:206, 313` — `describeExpectedFormat(printingPattern)`, i.e. **zero** accept patterns;
- `MobilePalletizingService:249, 342` and `MobileTruckLoadingService:131` — two.

The parenthetical is honest about the retirement, but the sentence now describes a hypothetical caller and omits the live zero-accept-pattern shape, which is the actual reason the varargs tail can be empty.

**Fix:** replace "a single-pattern caller passes just one" with the real zero-arg case, e.g. *"while palletizing's not-found path passes a printing pattern and no accept pattern at all."*

---

### L6 — Low (informational) · in-repo archived plan docs · **CONFIRMED**

Still describe the deleted method as live:
- `docs/plan/completed/club-location-replenish-fix.md:59`
- `docs/plan/v1-fixes/done/v1-0ecc20e-96b3795-merge-picking-boxtype-propagation.md:46–47`

Both are archived historical records under `done/` / `completed/`; leaving history alone is defensible and I would not change them. Recorded only so the sweep is complete. (`sbdocs/3-Resources/workflows/wms1-move-stock-unitload-workflow.md` also references `selectDestination` — that is **v1**, whose code is untouched, and is correct as-is.)

---

### L7 — Low (design note) · both new test suites · **SPECULATIVE**

The pins are scoped to one class / one file:
- `MoveStockScanDestinationRetiredUnitTest` reflects only over `MoveStockController`. `AdminController` is a base class for 43 controllers, so a re-add of the route on any other class carrying `@RequestMapping("/v3/moveStock")` would not be caught.
- `move-stock-scan-destination-retired.spec.js` reads only `store/moveStock.js`; a re-add in another store module or a component-level `$axios.$post` would not be caught.

I did not find any second controller with that prefix, so this is a bound on what the pins prove, not a live hole. Worth one sentence in each javadoc so a future reader does not over-trust them.

---

### Nit · `90146e08` commit message · **CONFIRMED**

*"all five anchors were mutation-checked"* — the Java suite carries three anchor assertions; the Jest suite carries two. If "five" is the cross-repo total, the API commit should not claim all five for itself. Trivial; noted only because the number invites a reader to look for five in one file.

---

## Verified clean — the six things you asked me to attack

**1. Is the dead-code claim actually true? — YES, re-derived independently, and it holds more broadly than claimed.**

At `origin/develop`, using `git grep <rev>` throughout (the `.gitignore`/`reports/` trap you flagged cannot bite a `git grep` against a rev):

- `wms2-mobile-ui`: the *only* reference to `/moveStock/scanDestination` is `store/moveStock.js:215`, inside the action itself. No component dispatches `moveStock/scanDestination`. `components/moveStock/scanDestination.vue:184, 251` dispatch `moveStock/checkContainer` then `moveStock/transferStock`. The `scanDestination` mock at `test/components/move-damaged-reason-payload.spec.js:133, 150` is registered on the **`moveUnitload`** module (`mountMoveUnitload`), not `moveStock` — that file's `mountMoveStock` harness registers `transferStock` + `checkContainer`. Different store, untouched by this change.
- **No dynamic dispatch anywhere**: `git grep -E "dispatch\(\s*[\`\"']?\$\{|mapActions"` across `*.vue`/`*.js` at `origin/develop` → **0 hits**. The only `'…/scanDestination'` string dispatch in the repo is `components/moveUnitload/scanDestination.vue:134`, a different module.
- `wms2-web-ui`: **0** hits for `scanDestination` at `origin/develop`. The five `moveStock` hits are the substring inside `removeStockUnitLock` in cypress helpers.
- `omsv2-UI`, `oms-laravel-api`: 0 hits.
- **Non-UI caller inside `wms2-api`**: `MoveStockController.scanDestination` at `origin/develop:106` was the sole caller of `mobileMoveStockService.selectDestination`. Confirmed by `git grep selectDestination origin/develop` — every other hit is `moveUnitload/selectDestination` (a different controller and service, untouched) or a test/doc reference.
- **Beyond what the commit claims — deployed branches.** The risk a UI-side sweep of `develop` cannot see is a *released* bundle still calling the route. `wms2-mobile-ui` `origin/main` (prod) dispatches `moveStock/transferStock` at `components/moveStock/scanDestination.vue:184`; `origin/release` (QA) dispatches `checkContainer` then `transferStock` at `:184, :251`. Neither dispatches `moveStock/scanDestination`. So no shipped client calls the endpoint either, and deleting it is not a breaking change for an un-upgraded handheld.

**2. Did the deletion orphan anything still reachable? — No.** All four named collaborators keep many live callers in `src/main`:
- `stockunitBusinessService.transferStockToUnitLoad` — 12 call sites (`BillofladingService:868,887`, `ClubLineOrderProcessor:197`, `CustomerorderService:564`, `PickingorderBusinessService:552`, `StockunitService:197,201,237,270,276,305`, `UnitloadService:175`, `MobileMoveUnitloadService:451`).
- `fixLocationAssignmentService.createFixedLocationAssignment` — 6 (`StockunitService:226`, `MobileMoveUnitloadService:371`, `MobilePutAwayService:549`, `MobileReplenishService:435,570,1140`).
- `MobileMoveUnitloadService.setStockDamaged` / `removeStockDamaged` — the **2-arg** forms are live at `:306, :311`. Only the 1-arg overloads lost their last production caller → L4.

**3. Constructor dependency removal — all 8 genuinely unused; zero Spring risk.**
Per-symbol census of the post-change file: `fixLocationAssignmentRepository`, `itemdataRepository`, `unitloadBusinessService`, `stockunitBusinessService`, `fixLocationAssignmentService`, `accessService`, `syspropService`, `mobileMoveUnitloadService` → **0 occurrences each**. All 11 retained fields have real body uses (`itemdataService` :84,:129,:144; `locationRepository` :114,:115,:121,:143,:167; `unitloadRepository` :79,:106,:139; `locationTypeRepository` :175; `unitloadTypeRepository` :152; `stockunitRepository` :76,:82,:127,:165; `unitloadService` :109; `clientRepository` :141; `locationRackRepository`/`locationRackRowRepository` :172; `pickPathConfig` :171). Nothing over- or under-removed.

On wiring: removing an injection point cannot introduce a missing bean or a DI cycle — it only deletes an edge. I checked your specific lazy-bean concern: `UnitloadBusinessService` **is** class-level `@Lazy` (`:38`), but it retains ~20 other `src/main` injectors, so nothing depended on `MobileMoveStockService` to force its creation. `MoveStockController` is the only injector of `MobileMoveStockService` (confirmed). And the whole `src/test` tree compiles, which is what would have caught a stale 19-arg `new MobileMoveStockService(...)` — `MobileMoveStockServiceTest:69` was correctly updated to 11 args.

**4. Are the new tests real? — Yes. I mutation-checked all of them independently.**

Ran as committed: `MoveStockScanDestinationRetiredUnitTest` 3/3 green, `MoveStockControllerUnitTest$ScanDestinationRetired` 2/2 green, mobile spec 3/3 green.

Then I built mutants in a scratch copy (the reviewed trees were not modified) and compiled them against the branch's own `target/classes`:

| Mutant | Result |
|---|---|
| Restore `MoveStockController.scanDestination` handler | **2 of 3 red** — `[SBDEV-2996: the retired handler must not come back]` and `[SBDEV-2996: no verb may map /scanDestination on this controller]`. Exactly the intended assertions. |
| Add a stub `selectDestination` to `MobileMoveStockService` | third test red — `[the retired service method had exactly one caller …]`. |
| **Anchor check:** rename the live `selectSource` handler *and* its route, retired handler still absent | **both anchors red** — `[the live mobile Move Stock reads must survive the retirement …]` and `[the two live routes must still be mapped …]`. The anchors are load-bearing, not decorative. |
| Mobile: re-add the `scanDestination` action to a scratch `store/moveStock.js` | **2 of 3 red**, killed at `expect(source).not.toContain('/moveStock/scanDestination')` and at the action-absence assertion; the anchor spec stayed green. |

No assertion I could find passes against code that is actually broken. Two specific things I checked for vacuity and found sound:
- `noneSatisfy(...)` on `mappedPaths` is vacuously true on an empty set — but the preceding `contains("/selectSource/{input}", "/selectStockUnit/{id}/{input}")` makes an empty set impossible, and mutant C proves that anchor fires.
- The MockMvc `isNotFound()` case in `MoveStockControllerUnitTest` would be satisfied by a MockMvc that routes nothing; its sibling `liveSiblingRouteIsStillMapped` proves the same instance still serves `GET /v3/moveStock/selectStockUnit/1/5` with a 200 body assertion. Correctly paired.

**Full suite reproduced independently: `Tests run: 5679, Failures: 0, Errors: 0, Skipped: 67`, `BUILD SUCCESS`.** Matches the commit message exactly, and is consistent with the 5680 `develop` baseline (−3 service tests, −1 net controller test, +3 new class, −1 IT stub that runs in neither lane). Mobile: **233 passed / 20 suites**, matching the commit message.

**5. Leftovers — `noValidString` is NOT orphaned.** Five surviving throw sites: `MobilePalletizingService:205, 248, 312, 341` and `MobileTruckLoadingService:130`, backed by `messages_en_US.properties:325` and by `BusinessExceptionUnitTest:138–172`, `MobilePalletizingScanPalletFormatTest:133, 173`, `MobileTruckLoadingServiceTest:322, 369`. Nothing to clean up. (Separately and pre-existing: the key lives only in `messages_en_US.properties`, not `messages.properties` — the documented locale trap, not this change's concern.) No OpenAPI/Swagger leftover: the deleted handler carried no `@Operation`, and the class-level `@Tag` is untouched. Remaining textual references are L5 and L6.

**6. Doc numbers — both CONFIRMED.**
- `doesUserHaveAccess` has exactly **8** invocation sites in `src/main`: `UserAdministrationController:120`, `UserController:162`, `PutawayConfigService:142/188/237`, `StockunitService:265`, `MobileMoveUnitloadService:303/308`. (The other five grep hits are the declaration at `AccessService:82` and javadoc mentions at `UserController:126, 527`, `AccessService:93`, `PutawayConfigService:386`.) They pass **5** distinct constants: `WEB_UI_VIEW_USER_MANAGEMENT`, `WEB_UI_VIEW_ITEM_DATA`, `WEB_UI_VIEW_CLIENT`, `WEB_UI_VIEW_SYSTEM_PROPERTY`, `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`.
- `WEB_UI_ACTION_*` constants: exactly **8**, at `WmsConstants.java:426–433`.
- The "remaining `MobileMoveUnitloadService` pair moved to `:303, 308`, and `StockunitService` to `:265`" claim also checks out. Only the `:251, 256` pin is off by one (L2).

---

## Summary of required fixes

| # | Severity | Where | Fix |
|---|---|---|---|
| M1 | Medium | `wms2-move-stock-unitload-workflow.md:146–155` | Correct 3 of 4 guard-table rows (Nirvana, `ON_HOLD`, flowbin SKU match are all present on the live path); drop the "each is a real gap" framing |
| L1 | Low | same doc `:111, 117, 271` | Repin `selectSource` → `:70`, `selectStockUnit` → `:162`, or drop the numeric pins |
| L2 | Low | `wms2-keycloak-role-matrix.md:476` | `:251, 256` → `:252, 257` |
| L3 | Low | `MobileMoveStockServiceTest.java:10, 52–53` | Delete the unused import and the unused `@Mock` |
| L4 | Low | `MobileMoveUnitloadService.java:493, 545` | Delete the two now-unreachable 1-arg overloads, or state why they stay |
| L5 | Low | `StringConverter.java:47–51` | Describe the live zero-accept-pattern caller instead of a hypothetical single-pattern one |
| L6 | Low | archived in-repo plan docs | Informational only; no action recommended |
| L7 | Low | both new suites | One javadoc sentence bounding what the class-/file-scoped pin proves |
| — | Nit | `90146e08` message | "all five anchors" is a cross-repo total (3 Java + 2 Jest) |
