---
title: "SBDEV-2996 — independent verification lane (evidence + acceptance criteria)"
type: review
lane: verifier
ticket: SBDEV-2996
status: complete
reviewer: verifier-2996
date: 2026-08-28
commits:
  - wms2-api 90146e08
  - wms2-mobile-ui 37e7823
---

# SBDEV-2996 — Verifier lane

**Scope of this lane.** Not a code-style review (a separate `code-reviewer` lane owns that). This lane
adjudicates the three acceptance criteria and tries to *falsify* every evidence claim the author made.

**Overall verdict: the retirement is sound and every load-bearing claim survived falsification.**
All three ACs are MET. Two documentation defects were found — one of them is a table the author added
in this very change, two of whose four rows are wrong. Neither blocks the merge; both should be fixed
before the plan is archived.

---

## 1. Per-AC verdict

### AC1 — "No operator-facing failure on `POST /v3/moveStock/scanDestination` renders as the generic network toast (**or the endpoint and its dead action are removed**)"

**MET**, via the parenthetical (removal), not via the error-contract branch.

Evidence I ran:

| Check | Result |
|---|---|
| `git grep -n "scanDestination\|selectDestination" origin/develop` in `wms2-api` | at `origin/develop` the handler is at `MoveStockController.java:99-100` and the service method at `MobileMoveStockService.java:235`; both are gone in the commit |
| Post-commit `grep` of `MoveStockController.java` | no `scanDestination` member, no `/scanDestination` mapping |
| `MobileMoveStockService.java` line count | 353 → **195** lines; `selectDestination` absent |
| Any *other* controller mapping the route | none — `MoveUnitloadController` maps `/moveUnitload/selectDestination`, a different route on a different service, and is untouched |
| Runtime proof, not just a grep | `MoveStockControllerUnitTest$ScanDestinationRetired.retiredRouteIsUnmapped` performs a real `POST /v3/moveStock/scanDestination` against MockMvc and asserts **404** + `verifyNoInteractions(service)`; I confirmed this assertion is armed (see §3, mutant 5) |

Nothing operator-facing can reach the route, so no failure on it can render as anything.

### AC2 — "The unknown-well-formed-label semantics are the **same** on both Move Stock paths, and the chosen semantics are **written down**"

**MET.**

*Same semantics.* After the retirement there is exactly one destination-scan path on the Move Stock
screen. I read it rather than taking the claim: `StockunitService.transferStock:170-173`
(`v2/wms2-api`, worktree `SBDEV-2996`) —

```java
unitLoad = unitloadRepository.findByLabelid(unitLoadLabelId)
        .orElseThrow(() -> new BusinessException(WmsConstants.MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_FOUND,
                unitLoadLabelId));
```

An unknown-but-well-formed label is a **hard rejection** with a keyed, operator-readable
`BusinessException` naming the container — no auto-create anywhere on the branch. The retired path's
`STRING_PATTERN_SEPARATE_STOCK` validation and its `createUnitload(..., Clearing, ...)` are both
confirmed deleted (`grep` for `noValidString`, `STRING_PATTERN_SEPARATE_STOCK`: zero hits in the
post-commit service). The mobile screen additionally pre-probes the label via
`moveStock/checkContainer` → `GET /v3/stockUnit/isUnitLoadIdValid/{labelId}`, which also answers "no"
for an unknown label — so the operator is refused twice, never auto-created. **One convention, and it
is the rejection one.**

*Written down.* `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md` §4.1
(lines 129-155) states it explicitly and correctly, including why the other convention lost. The
frontmatter `last_verified` / `verified_by` were updated the same day. This satisfies AC2 as written.

**But §4.1's adjacent "guards that lived only on the retired path" table is 50% wrong** — see
finding **D1** below. That table is not what AC2 asked for, so AC2 still passes; it is nonetheless
new documentation shipped by this change that asserts two false things.

### AC3 — "`store/moveStock.js` has no dead action" (checked **literally**, not just "not this one")

**MET.**

I enumerated every action in the post-commit module and searched the whole mobile repo at
`origin/develop` for a dispatcher of each. Five actions remain, five have dispatchers:

| Action | Dispatched at |
|---|---|
| `scanSource` | `components/moveStock/scanSource.vue:49` |
| `selectStockUnit` | `components/moveStock/inputAmount.vue:116` |
| `getLocations` | `components/moveStock/inputAmount.vue:122` |
| `checkContainer` | `components/moveStock/scanDestination.vue:184` |
| `transferStock` | `components/moveStock/scanDestination.vue:251` |

Search was `git grep "dispatch('moveStock/" origin/develop -- components pages store middleware plugins layouts`,
plus a `mapActions` sweep (the repo uses none). **No dead action remains.**

I also swept the module's **mutations**, which AC3 does not require but a "no dead code" reading
invites. `setStock` and `setLocations` have no component-side `commit`, but both are committed by the
store's own actions (`store/moveStock.js:177,180,202,218`) — live, not dead. The remaining eight
mutations all have component commit sites. Nothing else in the module is orphaned.

**Trap worth recording for the next reader:** a naive `git grep scanDestination` in the mobile repo
returns `components/moveUnitload/scanDestination.vue:134`, which *does* dispatch
`moveUnitload/scanDestination`. That is a different store module hitting a different endpoint
(`POST /moveUnitload/selectDestination`) and is untouched by this ticket. Anyone re-deriving the
zero-caller claim will hit this and must not read it as a surviving caller.

---

## 2. Evidence claims — falsification attempts

| # | Claim | Verdict | What I actually ran |
|---|---|---|---|
| E1 | The endpoint had **zero callers** across `wms2-mobile-ui`, `wms2-web-ui`, `wms2-api` at `origin/develop` | **VERIFIED** | `git fetch` then `git grep -n … origin/develop` in all three repos. Mobile: `store/moveStock.js:215` is the *only* reference to the route, and no `dispatch('moveStock/scanDestination')` exists anywhere. Web-ui: **zero** hits for `scanDestination` and zero for `moveStock` other than an unrelated `removeStockUnitLock` helper. API: `MoveStockController.scanDestination` is the sole caller of `MobileMoveStockService.selectDestination`. |
| E2 | The `wms2-web-ui` `.gitignore` `reports/` trap did not hide a caller | **VERIFIED** | Confirmed 32 files under `reports/` **are** tracked (`git ls-files \| grep -c reports/` → 32), and my search was `git grep <rev>`, which reads the tree and is not ignore-aware. Cross-checked with `command grep -rn` over the working tree (bypasses the shell `grep` function): still zero. |
| E3 | Zero unitloads match `^SU-[0-9]{6}$` on WineCo dev and Hydra UAT | **VERIFIED, and widened** | Re-ran on **six** reachable tenants, not two. All six carry `STRING_PATTERN_SEPARATE_STOCK = SU-\d{6}`; all six return **0** matches. WineCo dev 754,813 ULs · WSL WineCo UAT 866,471 · ShipItEZ c1wh UAT 106,503 · Hydra UAT (nywh) 17,612 · ShipItEZ nywh UAT 1,727 · Hydra prd 546. **≈1.75M unit loads, zero matches.** |
| E4 | …and therefore the auto-create branch produced nothing | **VERIFIED with the author's own caveat intact** | There *are* `SU`-prefixed labels — 585 on WineCo dev, 4 on Hydra UAT — but every one is `SU<epoch-millis>` (e.g. `SU1736533823501`), a different generator, and none matches `SU-\d{6}`. The author's caveat that this is **partly tautological** is correct and I would not soften it: the path was unreachable, so a zero footprint is not independent evidence of low demand. What it *does* establish, soundly, is that no operator holds an `SU-######` container today, so the create-vs-reject decision has no live instances on either side. The six-tenant sweep makes that second, weaker claim considerably stronger than the two-tenant version. |
| E5 | API suite: 5680 → **5679**, 0 failures | **VERIFIED** | `mvn -o test` from the API worktree: **`Tests run: 5679, Failures: 0, Errors: 0, Skipped: 67`**, BUILD SUCCESS, 01:51 min. The `-1` also reconciles arithmetically: 6 tests deleted (3 `selectDestination` service tests, 3 `scanDestination` controller tests) minus 5 added (2 replacement controller tests + 3 in the new class) = net −1. |
| E6 | Mobile: 230/19 → **233/20**, 0 failures | **VERIFIED** | `node_modules/.bin/jest` from the mobile worktree: **`Test Suites: 20 passed, 20 total · Tests: 233 passed, 233 total`**, 0 failures. Reconciles: the one new spec file contributes 1 suite / 3 tests. |
| E7 | Affected classes pass in isolation | **VERIFIED** | `mvn -o test -Dtest='MoveStockScanDestinationRetiredUnitTest,MoveStockControllerUnitTest,MobileMoveStockServiceTest'` → `Tests run: 17, Failures: 0, Errors: 0`. |
| E8 | "Every anchor was mutation-checked and each mutant killed exactly one intended assertion" | **VERIFIED** (5 mutants of my own) | See §3. |
| E9 | The deletion removes only unreachable code — no live guard is lost | **VERIFIED, with one correction to the docs** | The commit also deletes **two `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` permission checks** (`MobileMoveStockService` old :181,:186) that neither the commit message nor §4.1 mentions. This is **not** an authz regression: the live path carries the same gate at `StockunitService.java:265`. But it *is* a fifth deleted guard the new §4.1 table omits — see **D1**. |
| E10 | No external non-UI client | **PARTIALLY VERIFIED — no positive evidence of one, no access log to settle it** | See §4. |

---

## 3. Mutation checks I performed myself

I broke five things and confirmed which test went red each time. **Every worktree was restored and
`git status --short` is empty on both** (verified after each mutant and again at the end).

| Mutant | What I changed | Expected kill | Actual |
|---|---|---|---|
| M1 | `MoveStockController.selectSource` → `selectSourceMUT` (method name only) | the handler-name anchor | **1 failure**, `controllerHasNoScanDestinationHandler:85` — *"the live mobile Move Stock reads must survive the retirement"*. Exactly the intended assertion; the other two tests stayed green. |
| M2 | `@GetMapping(path="/selectSource/{input}")` → `/selectSourceMUT/{input}` | the route anchor | **1 failure**, `controllerMapsNoScanDestinationRoute:100` — *"the two live routes must still be mapped"*. Intended assertion only. |
| M3 | `MobileMoveStockService.selectStockUnit` → `selectStockUnitMUT` (+ its call site) | the service anchor | **1 failure**, `serviceHasNoSelectDestination:116` — *"the service methods the two live routes call must survive"*. Intended assertion only. |
| M4 | `@GetMapping("/selectStockUnit/{id}/{input}")` → `/selectStockUnitMUT/…` | the MockMvc non-vacuity anchor | `liveSiblingRouteIsStillMapped:187` went red (`expected:<200> but was:<404>`). Three pre-existing `SelectStockUnit` tests also went red — expected collateral, since the mutant breaks a live route. |
| M5 | **Re-added** a `scanDestination` handler with `@PostMapping("/scanDestination")` — the regression this ticket exists to prevent | all three negatives | **3 failures, precisely the negatives**: `retiredRouteIsUnmapped:171` (`expected:<404> but was:<200>`), `controllerHasNoScanDestinationHandler:89` (*"the retired handler must not come back"*), `controllerMapsNoScanDestinationRoute:106` (*"no verb may map /scanDestination"*). `serviceHasNoSelectDestination` correctly stayed green — I restored the handler, not the service method. |
| M6 (mobile) | `store/moveStock.js` action `checkContainer` → `checkContainerMUT` | the live-actions anchor | **1 failure**, *"still exports every action the Move Stock screen dispatches"*. Other two green. |
| M7 (mobile) | route string `/moveStock/selectSource/` → `/moveStock/selectSourceMUT/` | the source-pin anchor | **1 failure**, *"makes no request to the retired /moveStock/scanDestination route"* (its non-vacuity leg). Other two green. |

**Conclusion: the anchors are load-bearing, the negatives are armed, and nothing is vacuous.** The
author's claim that each mutant killed exactly one intended assertion holds for every anchor I could
isolate (M4's extra kills are a property of the mutant, not of the anchor). The reflection-based
class in particular is the *good* version of an "absent member" test — it would otherwise be exactly
the vacuous shape that has burned this repo before (a `getDeclaredMethods()` assertion that passes
against an emptied class); the paired positive anchors are what stop that, and M1/M3 prove they work.

One methodological note in the harness's favour: `sed -i` updates mtime, so `mvn -o test` genuinely
recompiled each mutant. I confirmed the mutants took effect by grepping the mutated line before each
run rather than trusting the edit — the failure mode where a skipped recompile produces a fake green.

---

## 4. The gap the author could not close — external non-UI client

The author flagged that a non-UI client calling `/v3/moveStock/scanDestination` directly cannot be
excluded by a repo grep. I looked for evidence either way and found **no positive evidence of such a
client**, and several independent reasons to think there isn't one. I could not find anything that
*settles* it.

| Source | Finding |
|---|---|
| `v2/oms-laravel-api` | `command grep -rn "moveStock\|scanDestination"` over all PHP/JSON/YAML (excluding `vendor`): **zero hits**. |
| `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` | §1 "Inbound — OMS Calls WMS2" is entirely under the `/rest/` base path via `AbstractRestController`. The only `/v3/**` calls OMS makes are printer lookups (`GET /v3/printer/search/findByType`) using a Keycloak service-account JWT. **No `/v3/moveStock/*` anywhere in the map.** |
| Committed OpenAPI artifact | None. `wms2-api` has `OpenApiConfig.java` (springdoc generates at runtime) but no checked-in spec, so there is no published contract a third party could have been coded against from the repo. |
| Gateway / CI config | `.gitlab-ci.yml` and the three GitHub Actions workflows are build/deploy only — no route allowlist that would enumerate consumers. |
| Function gate | The route was `@RequiresFunction(MOBILE_UI_VIEW_STOCK_TRANSFER)` at `MoveStockController.java:29`, so any hypothetical client also had to hold that function — it was never an open surface. |

**Assessment: low risk, and the deletion is a revert away.** The honest answer remains the author's:
only an access log would settle it. If one is reachable, a single query for the path over the
retention window would close this permanently — that is the one piece of evidence not available to me.

---

## 5. Findings

### D1 — MEDIUM (documentation, shipped by this change). §4.1's "guards that lived only on the retired path" table has two wrong rows and one omission.

`sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md:146-153`. I checked each row
against `StockunitService.transferStock` in the post-commit worktree:

| Row | Doc says | Reality |
|---|---|---|
| Destination is Nirvana | "no — tracked by SBDEV-2995" | **Wrong for the existing-container branch.** `StockunitService.java:178` calls `destinationEligibilityService.assertCanReceiveStock(unitLoad)`, and `DestinationEligibilityService:114,157` refuses a Nirvana destination **ungated** (its own javadoc at :57 says so, and §6 of this same document says "The Nirvana-sentinel branch is ungated"). It *is* absent on the new-container (`locationName`) branch. The flat "no" contradicts §6 of the same file. |
| Source stock unit `ON_HOLD` | "no" | **Correct** — no lock/hold check on the source stockunit anywhere in `transferStock:157-320`. |
| Destination must be a FLOWBIN when it is a Location | "no" | **Correct** — the `else` branch at `:238` accepts a non-flowbin location and creates a UL there. |
| Flowbin `FixLocationAssignment` SKU match | "no" | **Wrong.** Present on the live path at `StockunitService.java:229-232` (`"Flow bin has different SKU "`) and `:218-224` (`"SKU already assigned to flow bin "`). The retired path spelled it `"Flowbin has different SKU"` (no space), which is probably why a string-based sweep missed it. |

Also **omitted**: the retirement deleted two `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` permission checks
(old `MobileMoveStockService:181,186`, visible as `-` lines in `90146e08`). Harmless — the live path
gates the same function at `StockunitService.java:265` — but a reader auditing "what did the
retirement remove" from §4.1 will not learn that a permission check was among it.

*Why this matters more than a typo:* this table is the artifact a future ticket will use to decide
which guards to port onto the live path. Two false "no" rows invite someone to re-add a guard that
already exists, and the Nirvana row could get SBDEV-2995 mis-scoped.

**Recommended fix:** correct rows 1 and 4, add a row for the damaged-stock permission check noting it
is duplicated on the live path.

### D2 — MEDIUM (documentation, pre-existing but made wrong by this change). §6's "Move Stock" guard table now documents four guards that no longer exist.

`sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md:207-215`. The table cites line
numbers into `MobileMoveStockService.java`, which is now **195 lines** — three of the six cited lines
are past EOF:

| Row | Cited line | State after `90146e08` |
|---|---|---|
| Source UL on NIRVANA/SHIPPED | 147, 153 | guard **survives**, now at :109-124 — line numbers stale |
| Stock unit `ON_HOLD` | 228 | **deleted** (`"Stock unit is locked on hold!"` is a `-` line in the commit) |
| `transfer > available` | 78 | survives, but it lives in **`MoveStockController.java:79-80`**, not the service — a pre-existing mis-attribution, now off by one line too |
| Destination not flowbin | 279 | **deleted** |
| Flowbin itemdata mismatch | 273 | **deleted** |
| Destination label fails regex → `noValidString` | 288 | **deleted** |

So **four of six rows describe code that no longer exists anywhere**, while §4.1 forty lines earlier
correctly says those guards are gone. The document now contradicts itself. §4.1 was updated; §6 was
not. Related: **§10 landmine 9** still says the damaged-stock permission gate is "checked in both
flows (unitload lines 232–238, **stock lines 240–247**)" — the stock half is now false. And **§12's
verification log** still lists `selectDestination` in its 2026-04-19 row with "all file:line refs
confirmed", with no 2026-08-28 entry added (the dated italic notes below it stop at SBDEV-2994).

**Recommended fix:** rewrite §6's Move Stock table to the two guards that survive, correct §10 item 9,
and add the SBDEV-2996 row to §12.

### D3 — LOW (observation, pre-existing, out of scope). Boxed-`Long` reference comparison in the live flowbin SKU guard.

`StockunitService.java:229`:

```java
} else if (itemdataService.getById(fixedLocationAssignmentOpt.get().getItemdataId()).getId() != stockUnitItemData.getId()) {
```

`!=` on two boxed `Long` ids is a reference comparison. It currently behaves correctly only because
the two lookups return the *same* entity instance from the persistence context when the SKUs match.
If `ItemdataService.getById` is ever served from the Caffeine layer (or from a second session), two
equal-valued but distinct `Long`s make this `true` and the guard would throw *"Flow bin has different
SKU"* on a **matching** SKU — a false rejection on a live operator path. Not touched by this ticket
and not a reason to hold the merge; worth a ticket note. This is the same boxed-id pattern recorded
elsewhere in this vault.

### D4 — INFORMATIONAL. Commit message slightly under-describes the test change.

`90146e08` says it removed "the 3 selectDestination unit tests and the 3 controller scanDestination
tests" without mentioning that the controller class gained **2 replacement tests**
(`retiredRouteIsUnmapped`, `liveSiblingRouteIsStillMapped`). The stated net figure (5679) is right; the
narrative just makes the delta look like −6 rather than −6/+5. Also, "all five anchors" is only
reachable by counting the two-string `contains(...)` in `controllerMapsNoScanDestinationRoute` as two
anchors — there are four assertion sites. Cosmetic.

---

## 6. Tree state

Both worktrees are clean at the end of this lane — every mutation was reverted from a byte-identical
backup and re-verified:

```
.claude/worktrees/wms2-api/SBDEV-2996        git status --short → (empty)   HEAD 90146e08
.claude/worktrees/wms2-mobile-ui/SBDEV-2996  git status --short → (empty)   HEAD 37e7823
```

No committed code was modified by this lane.

---

## 7. Recommendation

**Ship it.** The retirement is correct, the zero-caller derivation holds independently, the DB claim
holds on three times as many tenants as claimed, both suites reproduce the stated counts exactly, and
every test anchor is provably load-bearing with the negatives armed against the exact regression the
ticket exists to prevent.

Before archiving the plan, fix **D1** and **D2** — both are in
`sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md`, and D1 is documentation this
change itself introduced. Consider a one-line ticket note for **D3**.
