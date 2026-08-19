## VERDICT: **ITERATE**

The diagnosis in §1–§2 is correct and reproducible — I re-derived every line number in §0.1 against `origin/develop` (api `d2bedc0`) and they are all exact, the three commits in §3 exist with the quoted subjects, `grep -c EntityNotFoundException` on `StockunitService.java` really is 34, and I reproduced the verify baseline byte-for-byte (`Result: 4 pass, 21 fail, 1 skip`) by materialising the six graded files from `origin/develop` into a shadow root. This is not a plan that invented its defect.

It nonetheless cannot go to a TDD gate. Three independent blockers: (a) §0's enumeration misses a **second live server endpoint for the very screen in the ticket title**; (b) §8's controller acceptance criterion asserts a JSON field that does not exist, so the gate would write a test against a fabricated contract; (c) DELIBERATE mode's rule on pre-mortems — the plan has no pre-mortem section, and §11 does not substitute (details in §6 below). R3's "cleared by measurement" is also structurally invalid, and one statistic quoted in §12 Q4 is off by five orders of magnitude.

---

## MUST-FIX SUMMARY

| # | Finding | Sev |
|---|---|---|
| M1 | §0 misses `MoveStockController.scanDestination` → `MobileMoveStockService.selectDestination` — same screen, same defect, third convention | **High** |
| M2 | §8.2 / §5 assert `errors[0].type`; the actual body key is `field` | **High** |
| M3 | Fix C routes raw engineer-only text to the operator toast — contradicts P1/P4 and the plan's own §5.4 | **High** |
| M4 | Option 4 never priced; collapsed into Fix E's "~18 modules" strawman | **High** |
| M5 | R3's clearing query is structurally incapable of detecting what it rules out; the ON_HOLD half cannot fail | **High** |
| M6 | §12 Q4's "210,167 at Nirwana with `entity_lock=0` that do carry stock" — actual value is **1** | **High** |
| M7 | No pre-mortem; §11 is a risk register with two unassigned/unfalsifiable rows | **High** |
| M8 | Verify rows A3, B3, C1, T2, T3 demonstrated to pass on wrong implementations | **High** |
| M9 | Fix B breaks `StockUnitControllerUnitTest.returnsTrueWhenUnitloadExists` (:1030-1044); not in §0.3, not in §8.3, no verify row | Medium |
| M10 | §8.4 ignores the existing mobile component spec that pins `submit()`'s dispatch count and ordering | Medium |
| M11 | `mvn_test_passes` (script :102-105) can only ever be red | Medium |
| M12 | "`orElseThrow` cannot throw a checked exception from a lambda" (§5 Fix A) is false — 34 counter-examples in this repo | Medium |
| M13 | P3 violated: existing `entityNotFoundForName`/`entityNotFoundForId` keys never mentioned | Medium |
| M14 | `…NotUsable`'s `%2$s` is undefined for 2 of its 4 branches | Medium |
| M15 | §0.1 row 13 "both UIs send `false`" is false — the web popup has a Print Label switch | Medium |
| M16 | §10 row 3 says `canReceiveStock` is "a private helper, not a service entry point" — Fix B calls it via method reference from the controller | Medium |
| M17 | `destinationLocationNotFound` copy is untrue for `CancellationReversalService` (a *source* location) | Medium |
| M18 | §0.2 row 15 / §8.2 claim a bulk `EntityNotFoundException` regression test exists; it does not | Medium |
| M19 | Unguarded `Optional.get()` at `StockunitService:169` → `NoSuchElementException` → 500, not enumerated, not caught by Fix C | Medium |
| M20 | §8.1 bundle tests diverge from the documented worked pattern in the taxonomy (§5, UTF-8 reader + `Locale.ROOT`) | Low |
| M21 | Store-module counts understated ~2.3× (§5 Fix E, §12 Q3) | Low |
| M22 | Stale comment in the verify script (:136-137) still says `UnitloadType` | Low |

---

## 1. PRINCIPLE-OPTION CONSISTENCY

**M3 (High) — the plan classifies an error as engineer-only and then routes its raw text to the operator.**

§0.1 and §5.4 are explicit that rows 3-13 are cases where "the operator can do nothing; an engineer must." Fix C then does this (§5, plan:478):

```java
errors.add(getErrorMessage("Entity Not Found", e.getMessage()));
```

`EntityNotFoundException.getMessage()` is built by the constructors at `exceptions/EntityNotFoundException.java:9-19` — `"UnitLoadType not found by name: Pallet"`, `"Location not found with id: 3421"`, `"Client not found with id: 55750"`. That string lands in `results.errors[0].message`, which `wms2-mobile-ui store/moveStock.js:173` and `wms2-web-ui store/handlingUnits/stockUnits.js:165` pass straight to `$toast.error()`. So the fix's user-visible output for 11 of the 13 sites is a Java entity name and a primary key.

This is not a nit — it is the load-bearing objection to Fix C, and the plan's own §5 Fix A argues *against* Fix-C-alone on exactly this ground ("it flattens a scan mistake and a corrupt foreign key into one indistinguishable error string"), then ships Fix C without fixing the flattening. P4 fails too: "Location not found with id: 3421" is never true-and-actionable for an operator under any recoverable future. The honest shape is a fixed operator string plus the `LOG.error` the plan already mandates:

```java
LOG.error("transferStock failed on an internal lookup for stockUnit={}", id, e);
errors.add(getErrorMessage("Runtime Error", "Something went wrong completing this move. Contact support."));
```

**M16 (Medium) — §10 row 3 contradicts §5 Fix B.** §10 marks `readOnly=true` **N/A** because "`canReceiveStock` is a private helper, not a service entry point." But §5 Fix B calls it as `unitLoad.filter(stockunitService::canReceiveStock)` from `StockUnitController` — it must be `public` on the service, reached from a `GET` handler with no transaction, doing a `locationRepository.findById`. That is exactly a service entry point and the `readOnly` question is live (OSIV is disabled per §10 row 1, so this runs outside any transaction).

**M17 (Medium) — P4 fails on the location key for one of three callers.** `transferStock.destinationLocationNotFound=Location %1$s was not found.` is raised at `StockunitService:178`, reached from `CancellationReversalService:203` with `log.getPickfromlocationname()` — a **pick-from source** location. The key name and any future rewording that leans on "destination" become untrue there. §0.1 row 2 also mislabels that identifier "client-supplied": it is replayed from a cancellation log, so the operator cannot rescan it and the split rule's justification ("the operator can act") does not hold for that caller.

**M14 (Medium) — `%2$s` undefined for half its branches.** `transferStock.destinationUnitloadNotUsable=Container %1$s is %2$s and cannot receive stock.` The GOING_TO_DELETE branch passes `BusinessObjectLockState.getCodeText(2)` = `"To Delete"` (confirmed at `WmsConstants.java:1274-1276`). The ON_HOLD, Nirvana and Shipped branches are elided as `{ … }` in the plan. Nothing states what `%2$s` is for them, and §8.1's four `…NotUsable` tests all assert only `getKey()`, so no criterion pins it.

---

## 2. FAIR ALTERNATIVES

**M4 (High) — option 4 is not priced anywhere; it is strawmanned by conflation.**

§5 Fix E describes the alternative as "duplicated in ~10 mobile store modules and ~8 web store modules… a cross-cutting change with its own regression surface across every workflow page." That is a description of fixing *all* of them at the axios layer. Nobody proposed that. The ~4-line version touches **one** function — `wms2-mobile-ui store/moveStock.js:179-182` — and has no regression surface outside the Move Stock screen.

It is also cheaper than the plan implies, because the server already sends the message: `RestExceptionHandler.java:156` builds the 404 as `ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, ex.getMessage())`. So `error.response.data.detail` is already `"UnitLoad not found by labelid: UL314581"` today, and reading it names the scanned container — the reported symptom, fixed, in one file, zero API deploy, zero contract change, and it is observable in the existing Jest lane (which the Java lane is not, per D1).

Its real weakness is that it displays internal text — but **Fix C carries that identical weakness** (M3), so the plan's chosen option pays 3 repos, 5 production files, 3 message keys and a behaviour change for a downside it does not escape. Option 4's genuine gaps are that it delivers neither Fix B's usability guard nor a fix for the web bulk path. The plan needs to say that, rather than pricing an option nobody offered.

Options 2 and 3 are priced honestly. Option 2 (C alone) gets a real rebuttal in §5 Fix A (though see M3). Option 3 (D alone) is covered in §5 Fix D — which correctly concedes Fix D "is not the fix." Both fine.

---

## 3. RISK MITIGATION CLARITY

**M5 (High) — R3's clearing measurement is structurally incapable of the claim it makes.**

R3's second query is stated as "zero `MANUAL_SPLIT`/`MANUAL_TRANSFER` records whose destination unit load carries `entity_lock IN (2,104)`." `stockrecord.tounitload` is a `character varying` **label snapshot** (confirmed against `information_schema` on `wms2-wineco-dev`), so this must join `sr.tounitload = unitload.labelid`. But `UnitloadBusinessService:397` — the mechanism this whole plan is about — **renames** the row to `<label>-X-<id>` when it retires. So the join drops exactly the population being counted. Measured on `wms2-wineco-dev`:

| Quantity | Value |
|---|---|
| `MANUAL_SPLIT`/`MANUAL_TRANSFER` stockrecords | 94,061 |
| …whose `tounitload` matches **no** current `unitload.labelid` | **61,634 (66%)** |
| unit loads carrying the `-X-` mangle | 320,642 |
| join result with `u.entity_lock IN (2,104)` | 0 |
| same, joining on `split_part(tounitload,'-X-',1)` to undo the mangle | 0 |

The zero is produced by the join, not by the absence of the workflow. **P5 applies literally**: on that tenant `SELECT count(*) FROM unitload WHERE entity_lock=104` is **0** — there is not a single ON_HOLD unit load — so the ON_HOLD half of the clearing query cannot fail regardless of the truth. A check that cannot fail is worse than no check.

There is a second, softer problem: the query reads `entity_lock` **now** against events from the past. A destination that was To-Delete at move time and has since been cleared is a false negative — precisely the case R3 claims to rule out.

The first query is sound and I reproduced it: `stockrecord` rows with `tostoragelocation IN ('Nirwana','Shipped')` in 365 days = **0**. But all-time = **958**, with the most recent at **2025-04-23** — about 16 months back. "Nobody moves stock into these destinations today" rests on a window that happens to start just after the last occurrence. That should be stated, not smoothed.

**Production inference is not valid.** WineCo dev and Hydra UAT are two non-production tenants; per the deployment picture there are live prd tenants (hydra/nywh, ShipItEZ ×2, WineCo) that were not measured. A behaviour change that refuses moves cannot be cleared on dev data alone, especially when the dev copy is a v1→v2 migration whose history may not represent prd operator habits.

**Other R-rows.** R1, R5, R6, R8, R9 are concrete and falsifiable. **R2 is unfalsifiable as written** — "force one internal-lookup failure on dev and confirm the line appears" names no mechanism for forcing it (all 11 sites are internal FKs you cannot break from the UI) and no owner. **R7** is a process note, not a risk. No row carries an assignee anywhere in §11.

---

## 4. TESTABLE ACCEPTANCE CRITERIA

**M2 (High) — §8.2's central assertion names a field that does not exist.**

§8.2 requires `errors[0].type == "Entity Not Found"`, and §5 Fix A describes the shape as `200 {errors:[{type,message}]}`. The actual builder is `AdminController.getErrorMessage` (`controller/AdminController.java:264-269`):

```java
protected Map<String,String> getErrorMessage(String field, String message) {
    Map<String,String> error = new HashMap<String,String>();
    error.put("field", field);
    error.put("message", message);
    return error;
}
```

The key is **`field`**. The existing suite already proves it (`StockUnitControllerUnitTest:214`, `:285` assert `$.errors[0].message`), and the taxonomy doc says the same at `wms-exception-taxonomy.md:76` ("`{errors:[{field,message}]}` body"). A TDD gate writing `jsonPath("$.errors[0].type")` from §8 produces a test that fails after a correct implementation.

**§8.2 can observe the post-fix 200 but not the pre-fix 404.** `BaseControllerUnitTest.setupMockMvc` (`common/base/BaseControllerUnitTest.java:49-57`) is `MockMvcBuilders.standaloneSetup(controller)` with argument resolvers and a message converter and **no `.setControllerAdvice(...)`** — `RestExceptionHandler` is not registered. So on the unfixed tree the test fails by *throwing* (nested `ServletException`), not by observing `status().isNotFound()`. That is adequate for a red-first gate, but it means nothing in the plan verifies the claim the whole ticket rests on — that a real dispatcher stops producing 404. D1 is acknowledged in the abstract; §8 never closes it. §8.6 M1 is the only thing that does, and it is manual.

**Under-specified behaviours a gate would have to invent:**
- `canReceiveStock`'s return for a `null` `getStoragelocationId()` — the helper does `locationRepository.findById(destination.getStoragelocationId())` with no null guard; `findById(null)` throws `InvalidDataAccessApiUsageException`, which is neither of Fix C's caught types.
- `canReceiveStock`'s visibility, signature and whether it throws (M16).
- `%2$s` for 3 of 4 `…NotUsable` branches (M14).
- Fix D's toast copy — §5 Fix D says only "toasts a specific message"; §8.4 asserts "specific toast"; no string is given anywhere. Verify `D2` greps only for the identifier `checkContainer`.
- Fix D's `checkContainer` action name, return value and failure semantics (what happens when the probe itself 500s — the web equivalent at `stockUnits.js:215-218` toasts and leaves `validContainer` at its previous value).
- §8.2's `transferStock_businessException_returns200WithErrors` "existing behaviour pinned" — that test already exists as `returnsErrorsWhenBusinessException` (`:265-286`); the plan doesn't say whether to rename it, and verify `T4` pins a method name for the other one.

**M18 (Medium).** §8.2 lists `bulkTransferStock_entityNotFound_returns200WithErrors` as "parity reference — must stay green untouched", and §0.2 row 15 says bulk is "pinned by a regression check." Neither exists. The `BulkTransferStock` nested class on `origin/develop` has exactly two tests (`:315-344`, `:346-364`) and neither exercises `EntityNotFoundException`. It must be written, and no verify row covers it.

**M10 (Medium) — §8.4's mobile regression surface is not enumerated.** `test/components/move-damaged-reason-payload.spec.js` exists on `origin/develop` and mounts `components/moveStock/scanDestination.vue` in `existing` mode, calling `wrapper.vm.submit()` synchronously and asserting `expect(dispatched).toHaveBeenCalledTimes(1)` (`:359-365`, and rows at `:253-254`). Fix D inserts an `await`ed store dispatch into `submit()` before the transfer dispatch — that changes both the dispatch count and the synchronicity those tests depend on. §0.3 lists three Java files and zero mobile-UI tests. (Note the mobile Jest lane is real and configured for `.vue` via `vue-jest` in `jest.config.js`, so §8.4 is feasible — the gap is only that the existing specs are unlisted.)

**M9 (Medium) — a Fix B regression the plan does not predict.** `StockUnitControllerUnitTest:1030-1044` (`returnsTrueWhenUnitloadExists`) stubs only `unitloadRepository.findByLabelid` and asserts `jsonPath("$", is(true))`. After Fix B rewrites the probe to `unitLoad.filter(stockunitService::canReceiveStock).isPresent()`, the `@Mock StockunitService` returns `false` by default and that test flips to `false` and fails. Not in §0.3, not in §8.3, no verify row.

---

## 5. VERIFICATION SCRIPT AUDIT (all 26 rows)

Baseline reproduced exactly: **4 pass, 21 fail, 1 skip**, with `A3/P1/P2/P3` green. The helpers' fail-closed `[ -f "$2" ] || return 1` guards are correct and are a real improvement on the template. `A1b` and `A2b` are well-constructed — I confirmed `"UnitLoad not found by labelid: "` is unique in the file, and pinning `+ locationName` correctly spares the sibling at `:388` which concatenates `STORAGE_LOCATION_DAMAGED`. `W1`/`W2` are sound: `"Container does not exist"` appears exactly once in the whole `wms2-web-ui` repo. `B2` is sound — the declaration `assertDestinationCanReceiveStock(Unitload unitLoad)` cannot match `assertDestinationCanReceiveStock\(unitLoad\)` because the type token intervenes.

**M8 (High) — five rows demonstrated to pass on a wrong implementation.** I built a wrong-implementation tree in scratch and ran each predicate:

| Row | Wrong implementation | Result |
|---|---|---|
| **B3** | guard that checks Nirvana + Shipped but **omits `GOING_TO_DELETE`** | **PASS** — `BusinessObjectLockState.GOING_TO_DELETE` already appears at `StockunitService.java:368, 421, 465, 514` in unrelated methods, so the token is free. B3 verifies two-thirds of what it claims. |
| **C1** | `catch (EntityNotFoundException` added to a *different method*, or left **commented out**, anywhere in the 570-line controller | **PASS** — the row counts file-wide occurrences and cannot express "in `transferStock`". |
| **A3** | `:157` blanket-converted to `BusinessException` (the exact failure A3 exists to catch) | **PASS** — `"UnitLoadType not found by name: "` survives at `:225` and `:391`. The row's own comment calls it the proof "the split rule is real"; it cannot see the one site adjacent to the edit. |
| **T2** | test file containing only `/* getKey() */` in a comment | **PASS** |
| **T3** | test file containing only `// Properties` and `// .load(` | **PASS** |

Fixes: B3 should require the three tokens within the helper body (extract the guard to its own file, or use a tempered-greedy gap anchored on `assertDestinationCanReceiveStock`). C1 should anchor on a tempered gap from the `transferStock` signature to the new catch. A3 should count `EntityNotFoundException` occurrences (`>= N`) rather than test a non-unique literal. T2/T3 should require `assertThat(...getKey())` and `Properties(...)\s*\.load\(` on a code line. Better still, delegate all four to `RUN_MVN=1` behavioural rows — which brings us to:

**M11 (Medium) — the maven rows can only ever be red.** `mvn_test_passes` (script `:102-105`) greps `mvn test -q` output for `BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0`. `-q` sets Maven's log level to WARN; both "BUILD SUCCESS" (`ExecutionEventLogger`) and Surefire's `Tests run:` summary are INFO. On a passing build the pipe is empty and the row records FAIL. *(Reasoned, not measured — `mvn` is not on PATH in this environment, `mvn -q -o validate` returns 127. One command on a machine with maven settles it.)* Separately, that 127 itself is silently recorded as a plain FAIL by `run`, so a missing maven is indistinguishable from failing tests. Add `command -v mvn >/dev/null || { skip …; }` and drop `-q` (or grep the surefire XML instead). Given §8.7 makes `RUN_MVN=1` part of final acceptance, and given that M1-M3 are the only behavioural rows in a script that is otherwise 25 greps, this is the row set that matters most.

**Rows pinned tightly enough to false-RED on a benign edit:** `C2` pins the exact log string `"transferStock failed on an internal lookup`; `T4` pins the exact JUnit method name; `A1a`/`A2a` pin the exact argument list `, unitLoadLabelId)` / `, locationName)` — all three break on a reformat or a rename that changes nothing. Acceptable if the plan is treated as prescriptive, but `C2` in particular should match `LOG\.error\(` within the new catch rather than the copy.

**Rows that cannot fail:** none found — `B1`, `K1`-`K3`, `D1`, `D2`, `W1`, `W2`, `T1`, `P1`, `P2`, `P3`, `A1b`, `A2b`, `B2`, `B4` are all genuinely falsifiable. `B4` (`file_contains 'canReceiveStock' "$CTL"`) is weak but not vacuous.

**M22 (Low)** — the comment at script `:136-137` still says the sibling literals are `"UnitloadType not found by name"`. The actual literal is `UnitLoadType` (capital L). Leftover from the typo already fixed in `A3`; it will mislead the next reader into repeating the mistake.

---

## 6. PRE-MORTEM AND EXPANDED TEST PLAN

**M7 (High) — there is no pre-mortem, and §11 does not substitute.**

§11 is a risk register: nine independent rows, each a named hazard with a mitigation. A pre-mortem asks the opposite question — *it is three months from now and this change caused an incident; what happened?* — and it surfaces the failure modes a per-row register structurally cannot: interactions between fixes, adoption failures, and the ways the mitigations themselves fail.

Concretely, here are failure modes a pre-mortem would have caught that §11 has no row for:

1. **Fix B refuses a legitimate consolidation in production** because R3 was cleared on a query that cannot see the population (M5), and there is no sysprop gate (§7.1 explicitly declines one) and no dark-launch — so the only rollback is a hotfix deploy across all tenants.
2. **Fix C's `LOG.error` becomes noise and gets filtered**, at which point the 404→200 conversion is a pure loss of signal. R2 covers "the line never arrives"; nothing covers "the line arrives 400×/day and someone mutes it."
3. **Fix A + Fix D interact**: with A shipped and D shipped, the probe rejects client-side and the operator never sees the server's specific message; if D's copy is generic, Fix A's carefully-worded keys become dead code on the mobile path that motivated them.
4. **The two message keys go into `WmsConstants` but the throw sites use the 1-arg constructor** during a rushed merge conflict resolution — `BusinessException.java:42-47` sets `key="placeholder"` silently, every `getKey()` test still compiles, and §8.1's assertions go green against `"placeholder"` unless they assert equality (which §8.1 does — good, but only because it was written before this was a risk).
5. **The web toast reword ships without the probe change** (or vice versa) — they are in different repos with independent deploy cadences, and §7.1's deploy-order row covers only api-before-mobile, not api-before-web.

**§8 coverage given D1.** Unit: strong on the service (§8.1's eight cases are well chosen, and `internalLookupMiss_stillThrowsEntityNotFound` is genuinely the right test for the split rule). Controller: adequate but see M2/M18. Integration: correctly deferred with a real reason (SBDEV-2217) — that judgement is right. **Observability: absent.** §10 row 8 declines a Micrometer counter; R1's entire mitigation is one `LOG.error`; and §8 has no row that asserts the log line is emitted (`LogCaptor`/`ListAppender` would make R1 falsifiable in the unit lane, cheaply). Given D1 says no runnable lane observes the contract change, an observability assertion is the one thing that could partially compensate, and it isn't there. E2E: §8.6's eight manual scenarios are good and M8's SQL sanity check is a nice touch — but M4 requires "seed one if none exists," i.e. hand-crafting a To-Delete unit load with an unmangled label, with no recipe given; and M5 says "if the probe is bypassed" with no method for bypassing it.

---

## 7. COMPLETENESS OF §0

**M1 (High) — the second server path for the ticket's own screen is missing.**

The mobile Move Stock feature talks to **two** endpoints, not one. `wms2-mobile-ui store/moveStock.js` contains:

- `:167-169` → `POST /stockUnit/transferStock` — the path the plan analyses.
- **`:133-136` → `POST /moveStock/scanDestination`** — routed to `MoveStockController.scanDestination` (`controller/mobile/MoveStockController.java:96-117`) → `MobileMoveStockService.selectDestination` (`service/mobile/MobileMoveStockService.java:235-349`).

`MoveStockController:102-108` catches **only `BusinessException` and `FacadeException`** — byte-identical to the defect in `StockUnitController:96-102` — while `selectDestination` contains roughly fifteen `EntityNotFoundException` sites (`:238, :247, :248, :250, :266, :277, :309, :314, :327, :328, :336, :339`). And `store/moveStock.js:147-150` has the same blanket catch. **This is a second, unfixed instance of the exact reported defect, on the exact screen named in the ticket title, in a file literally called `scanDestination`.**

It is also a **third convention** for the case the plan is normalising. `MobileMoveStockService:294-318` handles an unknown destination label by validating it against the `STRING_PATTERN_SEPARATE_STOCK` sysprop and, on a match, **auto-creating** the unit load at Clearing — neither `BusinessException` nor `EntityNotFoundException`. Its Nirvana guard (`:320-324`) compares against `unitloadService.getNirvana()` (the Nirvana *unit load*), not the destination's *location* as Fix B does. §5.4 claims the split rule "is already how `MobileMoveUnitloadService` behaves"; the service that actually implements this screen behaves a third way, and the plan never looked at it.

I cannot find a component that dispatches `moveStock/scanDestination` today (`git grep` across `origin/develop` returns only the `moveUnitload` equivalent), so it may be legacy — but "probably dead" is a finding to state, not a reason to omit an endpoint from an enumeration that claims to be grep-derived. The §0 method line is the reason it was missed: `grep -rn "stockUnit/transferStock\|bulkTransferStock"` is scoped to two URL fragments and structurally cannot find a sibling endpoint under a different prefix.

**M19 (Medium) — an unchecked lookup Fix C does not net.** `StockunitService.java:166-169`:

```java
Optional<UnitloadType> defaultUnitLoadType = unitloadTypeRepository.findById(itemData.getDefultypeId());
if (!defaultUnitLoadType.isPresent()) {
    defaultUnitLoadType = unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_BOX);
}
Location palletLocation = …;
unitLoad = unitloadService.createUnitload(palletLocation, defaultUnitLoadType.get().getId(), …);
```

`.get()` on an `Optional` that may still be empty → `NoSuchElementException` → `RestExceptionHandler:145-150` → **500** with the body `"An unexpected error occurred."`. Fix C catches `EntityNotFoundException` only, so this path keeps its 500 and its generic toast. It sits inside the pallet branch of the *existing-container* path — the reported path. §0.1 enumerates 13 sites and presents them as the method's complete unchecked-lookup surface; this is a 14th of a different type. Either net it or state that it is knowingly left.

**M15 (Medium).** §0.1 row 13 dismisses the `printLabel` block as "only reachable when `printLabel=true`; both UIs send `false`." `wms2-web-ui components/handlingUnits/popups/transferStock.vue:43` is `<v-switch v-model="printLabel" label="Print Unit load Label">`, sent at `:104` as `printLabel: this.printLabel`. The default is `false` (`:67`) but the operator can flip it. That block (`StockunitService:269-290`) holds three further `EntityNotFoundException` sites reachable in production from the desktop, and they are part of Fix C's blast radius.

**M13 (Medium) — P3.** The repo already has generic not-found keys: `entityNotFoundForId` and `entityNotFoundForName` (`messages_en_US.properties:314-315`), used at 34 `.orElseThrow(() -> new BusinessException(...))` sites across `ReceivingService`, `PutawayDestinationResolver`, `PutawayDestinationValidator` and `SkuPutawayQueryService`. The plan invents three new keys without mentioning them. Diverging is defensible — those render as `"No entity Unitload found for name='UL314581'!"`, which is engineer-speak — but P3 requires the argument to be made, and the plan makes exactly that argument for Fix C ("converge on the sibling rather than inventing a third convention") while skipping it here.

**Correctly enumerated and verified:** all 13 §0.1 line numbers; `bulkTransferStock`'s catch at `:163-167`; `CancellationReversalService:172/:186-187/:203`; `isUnitLoadIdValid` at `:557-564`; the web pre-validation at `transferStock.vue:140-147`; `stockUnits.js:212`; mobile `scanDestination.vue:141-185` and `store/moveStock.js:167-183`. §0.3's three Java test files are right as far as they go (see M9, M10 for what's missing).

---

## 8. FACTUAL AUDIT

**Verified true:** every §0.1 line number; §1.3's DB story (`unitload 21552195` = `UL314581-X-21552195`, `entity_lock=2`, `storagelocation_id=0`, location 0 = `Nirwana`); `GOING_TO_DELETE = 2` at `WmsConstants.java:1259` with `getCodeText` → `"To Delete"` at `:1274-1276`; `ON_HOLD = 104` at `:1262`; the `BusinessException` 1-arg key trap at `:42-47` and the `getKey()` javadoc at `:133-147`; `RestExceptionHandler` mappings at `:145-159`; the base-bundle locale requirement, which is documented in detail at `wms-exception-taxonomy.md:260-282` and is genuinely load-bearing (`messages.properties` is 27 lines and carries `placeholder=%1s`); all three §3 commits; `grep -c` = 34; the 4/21/1 baseline; and both §8.7 script-defect write-ups, which are accurate self-criticism.

**M6 (High) — §12 Q4's second statistic is wrong by five orders of magnitude.** The plan states: *"WineCo dev holds 320,637 unit loads parked at Nirwana with `entity_lock=2` and no stock — the `sendToNirvana` population — beside **210,167 at Nirwana with `entity_lock=0` that do carry stock**."* Measured on `wms2-wineco-dev`:

| Query | Value |
|---|---|
| Nirwana + `entity_lock=2` + no stock | **320,637** ✓ exact |
| Nirwana + `entity_lock=0` | **1** |
| Nirwana + carrying any stock | **1** |
| total unit loads at Nirwana (`storagelocation_id=0`) | 320,638 |
| `entity_lock=104` anywhere | 0 |

The first figure is exact, which makes the second harder to dismiss as a typo. It is the "context, not a blocker" half of the claim that Fix B disturbs nothing — and it invents a 210,167-strong live population at Nirwana that does not exist. Combined with M5, R3's whole clearing needs to be redone rather than reworded.

**M12 (Medium) — a false compiler claim.** §5 Fix A (plan:402): *"`orElseThrow` cannot throw a checked exception from a lambda, so the location site needs the same `Optional` + `isEmpty()` shape."* `Optional.orElseThrow(Supplier<? extends X>) throws X` is generic over `X extends Throwable`; the lambda only *constructs* the exception, so `X` infers to `BusinessException` and the enclosing `transferStock`, which declares `throws BusinessException`, compiles. The repo contains **34** working counter-examples, e.g. `ReceivingService.java:362`, `PutawayDestinationValidator.java:120`, `CancellationReversalService.java:186`. The plan's own "after" block at plan:398-399 is written in the `orElseThrow` form and then contradicted two lines later — an implementer following the prose writes five lines where one would do, and an implementer following the code block is told (wrongly) that it won't compile.

**M21 (Low) — store-module counts.** §5 Fix E says "~10 mobile store modules and ~8 web store modules"; §12 Q3 says "~18 store modules across both UIs." Measured: **12** of 13 mobile store modules contain the blanket toast (the plan's list of 10 omits `store/index.js`), and **30+** web store modules do. Real total is 42+, not ~18. This cuts in favour of deferring Fix E, so it changes no decision — but a stated count that is off 2.3× in a plan whose §0 is built on counting deserves correcting.

**Minor naming drift (no action needed beyond a pass):** §10 row 7 says `BaseControllerTest`; the class is `BaseControllerUnitTest`. §4's key-file range for `transferStock.vue` is `133-155`; the method spans `130-154`.

---

## WHAT WOULD MAKE THIS APPROVABLE

1. Enumerate `MoveStockController.scanDestination` / `MobileMoveStockService.selectDestination` and rule in or out — with a reason (M1). Re-run §0's greps with a method that could have found it.
2. Fix `type` → `field` in §5 and §8.2 (M2).
3. Decide what Fix C actually shows the operator, and stop routing `e.getMessage()` (M3). Add a log-emission assertion so R1 is falsifiable.
4. Price option 4 as one file, ~4 lines, using the `ProblemDetail.detail` the server already sends — then justify the chosen option against it (M4).
5. Redo R3 on a query that can see mangled labels (join on `split_part(tounitload,'-X-',1)`, or work from `unitload_record` where §1.3 already found the `SEND_TO_NIRWANA` trail), include at least one production tenant, and drop or requalify the ON_HOLD half on any tenant with zero ON_HOLD rows (M5).
6. Correct or delete the 210,167 figure (M6).
7. Add a pre-mortem (M7).
8. Rewrite A3, B3, C1, T2, T3; add a `command -v mvn` guard and drop `-q` from `mvn_test_passes` (M8, M11).
9. Add the two regression surfaces — `StockUnitControllerUnitTest.returnsTrueWhenUnitloadExists` and `test/components/move-damaged-reason-payload.spec.js` — to §0.3 and §8.3 (M9, M10).

Items 1-8 are prerequisites for a TDD gate; item 9 can be folded into the gate itself.