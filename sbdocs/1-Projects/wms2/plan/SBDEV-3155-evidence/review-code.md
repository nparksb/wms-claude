# SBDEV-3155 — code review

**Reviewed:** `implementation.diff` (5 files, +118/−6) against the worktree
`.claude/worktrees/wms2-api/SBDEV-3155` at `ad681319`.
**Method:** read-only. No maven, no mutating git. Independent re-derivation of the deployed
route table from source (class-level `@RequestMapping` + method mapping + the `AdminController`
inheritance explosion), independent recount of the `EXPECTED` map, live SQL against all six v2
tenant DBs, and `git grep` over `origin/develop` of both UI repos and `oms-laravel-api`.

**Verdict:** the code change is correct. Every defect found is in *prose that ships in the
javadoc* — three false numeric claims and one overstated justification — plus four Lows.
Nothing blocks the gate itself.

---

## Clean categories (stated explicitly, not padded into findings)

- **Annotation placement (Q1) — CLEAN.** All ten are method-level, on the right method, with the
  right constant, and there is no class-level `@RequiresFunction` on any of the three classes
  (verified by reading each class header: `@Tag` / `@RestController` / `@RequestMapping` / `public
  class` with nothing between). The `activateBatch`/`activeBatch` trap is handled — the annotation
  sits on `public ResponseEntity<Object> activeBatch(...)` under `@GetMapping(path=
  "/activateBatch/...")`, and the pin keys on the path. Imports: `PickingOrderPositionController`
  needed and got both `RequiresFunction` and `WmsConstants`; the other two already had
  `RequiresFunction` explicitly and `WmsConstants` via `net.aim_ai.wms.service.*`. No stray or
  unused import. `git diff --stat` confirms nothing else in `src/main` moved.
- **Pin path strings (Q2) — CLEAN.** All 14 keys match the deployed mapping exactly, including the
  class prefixes `/v3/clubLine`, `/v3/transfers`, `/v3/pickingOrderPosition`. The four
  asserted-UNGATED siblings all exist and are genuinely ungated today
  (`ClubLineController:59` `/orderBatch/{orderBatchId}`, `:196` `/openClubRun`;
  `TransfersController:70` `/transferOrder/{customerOrderId}`, `:268` `/openTransfer`).
- **Pin arithmetic (Q2) — CLEAN.** I parsed the whole `static {}` block, expanded the four
  `for (String p : new String[]{…})` loops (8 + 9 + 4 + 3 = 24 rows) and counted:
  **145 row entries, 145 distinct keys, zero duplicate collisions.** 131 + 14 = 145, and the
  javadoc ledger (`145 = 131 + 14 from SBDEV-3155`) agrees with `assertThat(EXPECTED).hasSize(145)`.
- **Sibling sweep for the literal `131` (Q4) — CLEAN.** Repo-wide grep finds `131` only at the two
  intentional javadoc lines (`:515`, `:519`). `src/test/java/net/aim_ai/wms/unit/config/README.md:15`
  ("**131 tests**") is an unrelated per-package test count, not this pin. No `@DisplayName`,
  comment, or doc restates the old size — and the class javadoc already forbids putting a count in
  a `@DisplayName` (`TestIdentifierCountArchTest`).
- **"No mobile caller", verified independently.** `git grep -i clubline` and `git grep "/transfers/"`
  over `origin/develop` of `wms2-mobile-ui` return **zero hits each**, and all ten handler names
  return zero. The claim that mobile's transfer screen uses a different controller checks out:
  `controller/mobile/TransferOrderController.java:29-30` is `@RequestMapping("/v3/transferOrder")`
  with its own class-level `@RequiresFunction(WEB_UI_VIEW_TRANSFER_ORDER)`. Single-function gates
  are the right shape here; no ANY-of is owed.
- **No §0.C / OMS hazard.** `oms-laravel-api` `origin/develop` has zero references to any of the ten
  routes across `app/`, `config/`, `routes/` — `config/wms.php` reaches only `rest/*`,
  `v3/client/*`, `v3/shipperId/create`, `v3/boxType/create` and SDR finders. Gating these cannot
  break facility/catalog sync. (The diff's comment does not mention OMS at all; that turns out to
  be safe, but it is the one hazard class the comment leaves unaddressed.)
- **Grant populations — VERIFIED, exact.** I re-ran the user→group→role→function walk on all six
  DBs. Every figure in the comment reproduces to the digit, and all three constants exist in all six:

  | DB | CLUB_LINE | TRANSFER_ORDER | PICKING_POSITION | total users |
  |---|---|---|---|---|
  | wms2-wineco-dev | 45 | 45 | 45 | 100 |
  | wsl-wineco-uat | 43 | 43 | 43 | 94 |
  | nywh-hydra-uat | 15 | 15 | 15 | 19 |
  | c1wh-shipitez-uat | 25 | 25 | 25 | 36 |
  | nywh-shipitez-uat | 9 | 9 | 9 | 11 |
  | wms2-hydra (**PRD**) | 7 | 7 | 7 | 9 |

  No tenant fails closed.
- **"Nothing else in the repository forbids a class-level annotation on these two."** Confirmed.
  `FunctionGuardArchTest.SHARED_CONTROLLERS` is exactly
  `StockUnitController, DashboardController, ReplenishOrderController, UnitLoadController`
  (`:111-116`), and AC-1/AC-2/AC-3 all iterate `GOLDEN_MAP.keySet()` — the 14 GUARDED controllers —
  so none of them sees `ClubLineController` or `TransfersController`.
  `FunctionGuardStartupAssertion` is likewise scoped to `FunctionGuardInterceptor.GUARDED`, so this
  change adds no boot-time requirement. The four UNGATED rows really are the only tripwire.
- **Enforcement is real for a non-GUARDED class.** `FunctionGuardInterceptor.preHandle:238-252`
  resolves the method-level annotation before the `GUARDED` membership branch, so the ten routes are
  denied for a caller without the function regardless of GUARDED. `PickingOrderPositionController`
  being new to gating introduces no fail-open.
- **`WEB_UI_VIEW_PICKING_POSITION` is a first live enforcement.** Confirmed: outside `WmsConstants`
  its only `src/main` references are `UtilRestController:309,386` (which is `@Service`, so nothing
  routes) — and those are `initDB` grant calls, not mappings. `AccessAuditService.GATED_WORKFLOWS`
  maps `transfer-order` but has no picking-position entry.
- **Style consistency with SBDEV-3142 / SBDEV-3154 (Q5) — CLEAN on the annotations.** One
  method-level line, no per-method comment, all explanation carried in the pin's block comment —
  identical to `ClubLineController:260,268,305` and `TransfersController:338,345,367,375` from 3142
  and to the `AdminActionController` block from 3154. Comment density in the pin matches too.
  (The one place it *diverges* from both predecessors is M3 below.)

---

## Findings

### M1 · Medium — "from 9 to 15 matches" is arithmetically wrong; it is 9 → 19

`SurfaceInventoryContextTest` javadoc:

> Five tokens were added ({@code /assign}, {@code /reassign}, {@code /unlink}, {@code /activate},
> {@code /run}), taking it **from 9 to 15 matches** out of 792 registrations with zero new false
> positives.

The same diff, thirty lines lower, says:

> `/assign (2) /reassign (1) /unlink (3) /activate (2) /run (2)` — **10 matches, 10 true.**

9 + 10 = **19**, not 15. This is decidable from the diff alone — no measurement needed.

I measured it anyway, to be sure the "9" and the "10" are the halves that are right. I rebuilt the
GET-only registration set from source, including the `AdminController` alias explosion (761 MVC
registrations, 364 GET-only; the comment's 792 presumably also counts actuator/SDR handlers):

- old token set (`/delete /remove /cancel /reset /create`) → **9** matches ✓ exactly the nine the
  comment implies (6 × `/delete`, 3 × `/cancel`);
- with the five new tokens → **19** matches, the 10 added being exactly the ten the comment lists,
  all true positives ✓.

So the per-token measurement is sound and **"zero new false positives" is correct**; only the
running total is wrong. Fix the sentence to `from 9 to 19 matches`.

**Why this is Medium and not Low:** this class's own javadoc rejects a frozen allowlist because
stale entries "train readers to re-baseline without auditing", and the new paragraph explicitly
instructs the next slice not to "re-run it and trust a zero". A wrong baseline in the sentence
issuing that instruction is the exact failure it warns about.

### M2 · Medium — "precision from 15/15 to 16/24" contradicts the same paragraph

> ⚠ `/fix` was measured and DELIBERATELY REJECTED: 1 true positive (fixPickingPosition) against 8
> false … Adding it would drop precision **from 15/15 to 16/24**.

Two problems:

1. **`15/15` asserts zero false positives**, while the paragraph immediately above it says the
   heuristic "produced 2 false positives (`OrderCancellationController.listPendingReversals` and
   `.detail`, matched on 'cancellation')". Those two still match — `/cancel` was not removed. The
   file contradicts itself within five lines.
2. The totals inherit M1's error. Measured today: **17/19**. With `/fix`: **18/28**.

The `/fix` sub-measurement itself is **exactly right** and I reproduced it including the alias
registrations — 9 added matches, 1 true (`/v3/pickingOrderPosition/fixPickingPosition/{id}`) and 8
false: `/v3/fixedAssignment/{detailView, getFlowBinHavingNoFixedAssignment, toggleActiveStatus/{id},
user/findUsers, user/findUserByUsername, user/findUserGroupsByUsername, admin/importUsersFromCsvText}`
(7) plus `/v3/replenish/fixedLocationUpperBound/{locationId}` (1). The **decision to reject `/fix`
is correct and well-evidenced**; only the ratios framing it are wrong. Suggested replacement:
`would drop precision from 17/19 to 18/28`.

### M3 · Medium — no 403 test, unlike both prior tranches

Both predecessors shipped a behavioural test alongside the reflection pin:

- SBDEV-3142 → `unit/controller/ReportReadGateUnitTest.java`, whose **T2c** and **T2d** assert
  `403` for `ClubLineController` and `TransfersController` routes specifically;
- SBDEV-3154 → `unit/controller/AdminActionConsoleGateUnitTest.java`.

SBDEV-3155 ships annotation-presence pinning only. `Sbdev3017TrancheGateContextTest` proves the
annotation *is on the method*; nothing in this change proves a caller without the function actually
receives 403 on any of the ten routes.

This is cheap to close because `ReportReadGateUnitTest` already constructs both controllers with
every mock these handlers touch — `customerorderBatchRepository.findById`, `locationRepository`,
`customerorderRepository.findByOrderbatchId`, `transferOrderService` — so a `T2e`/`T2f` loop over
the nine new ClubLine/Transfers paths is roughly fifteen lines, and its `T0`
`endpointListsCoverTheDeclaredScope` is scoped to 3142's 20 handlers so it will not go stale from
the addition.

Two traps if you do add it: use **`setupMockMvcWithGuard(controller, guard)`**, never
`setupMockMvc` — the latter installs no interceptor and the test is vacuous; and give
`fixPickingPosition` a stubbed `pickingorderPositionRepository.findById` so the allow path lands on
2xx rather than a servlet 500 that would satisfy `isNotEqualTo(403)` for the wrong reason (the same
trap `ReportReadGateUnitTest`'s `BATCH_BODY` javadoc records).

Not High: the 403 mechanism itself is proven by `FunctionGateEnforcementPointContextTest` and the
interceptor path is shared, so the residual risk is that a *route-specific* fault (a mapping that
never reaches the interceptor) would go unseen. Real, but small.

### M4 · Medium — "Option B" is claimed for all ten; it holds for nine

> Each takes the function that **ALREADY gates its screen** — SBDEV-3017 §9.16 Option B

For the nine ClubLine/Transfers routes this is exactly right, and I verified it end-to-end rather
than taking it on trust — every web caller sits on a screen the menu already gates:

| route | caller | screen | menu gate |
|---|---|---|---|
| `activateBatch` | `components/outbound/club/activate/confirmationPop.vue:66`, `components/processes/clubRuns/activate/confirmationPop.vue:84` | `/outbound/club`, `/processes/club-run` | `WEB_UI_VIEW_CLUB_LINE` (`appMenuList.js:60,69`) |
| `runClubLine` | `components/processes/clubRuns/itemsTable.vue:230` | `/processes/club-run` | `WEB_UI_VIEW_CLUB_LINE` |
| `activateTransferOrder` | `components/outbound/transfer/activate/confirmationPop.vue:84`, `components/processes/transferPicking/activate/confirmationPop.vue:85` | `/outbound/transfer`, `/processes/transfer-picking` | `WEB_UI_VIEW_TRANSFER_ORDER` (`:61,70`) |
| `runTransfer` | `components/processes/transferPicking/itemsTable.vue:126-128` | `/processes/transfer-picking` | `WEB_UI_VIEW_TRANSFER_ORDER` |
| `assignStagingLane` / `assignTransferLane` | 1 file each, same screens | — | same |
| `unlinkStagingLane`, `unlinkTransferLane`, `reassignTransferLane` | no caller in either UI | — | — |

For the tenth it does **not** hold. `WEB_UI_VIEW_PICKING_POSITION` gates **no screen at all**: it has
no `appMenuList.js` entry, and its only occurrences in `wms2-web-ui` on `origin/develop` are two
lines in `test/support/webFunctionConstants.js`; `wms2-mobile-ui` has zero. And
`/v3/pickingOrderPosition/fixPickingPosition/{id}` has no caller in either UI or in OMS.

The gate is **safe** — nothing can 403 on a button that no screen renders, and grants exist
fleet-wide — but the justification offered is name-association, not screen-precedent, and the
comment tells a future reader that a screen precedent exists. Since the same block already says
this constant's first enforcement "deserves the extra scrutiny that implies", say the rest of it:
that the constant names an operator capability with no screen, and that the route has zero callers,
so no user population loses a working action.

### L1 · Low — "12 of §1's rows" is now stale

The diff strikes `{@code unlinkSelectedPallet},` from the enumeration of GET-mutators labelled
`read` but leaves the count:

> GET handlers that genuinely mutate are labelled {@code read} here — **12** of §1's rows, including
> `closeInboundBol`, `closeOutboundBol`, `triggerOrderReplenish`, `printLabel`, `setDefault`,
> `toggleActiveStatus`, `acceptHubAndSpokeBol`, `closeIntraCompanyTransfer`.

The widening moved ten rows off that miss-list (the nine ClubLine/Transfers GETs plus
`unlinkSelectedPallet`); `fixPickingPosition` is the one that stays. Whatever "12" was measured
against on 2026-08-28, it cannot still be 12 after removing a member from its own enumeration.
Re-derive it or drop the number and say "several".

### L2 · Low — the `(a)` / `(b)` clause pair is now split by a paragraph

The inserted `<p><b>SBDEV-3155 widened that heuristic…</b>` lands *between* `(a)` and `(b)`, so the
rendered javadoc reads `…(a) GET handlers… advisory. [new paragraph about 3155] …a future gating
slice must enumerate by hand rather than re-run it and trust a zero. (b) POST-as-query handlers…`.
Move the new paragraph after `(b)`, or promote `(a)`/`(b)` to a `<ul>`.

### L3 · Low — the same bolded sentence twice in five lines

`<b>Human classification is still not replaceable by this tool</b>` (new) and
`<b>Human classification is not replaceable by this tool.</b>` (existing, closing `(b)`) now both
render. Drop one.

### L4 · Low — import order in `PickingOrderPositionController`

```java
import net.aim_ai.wms.service.KeycloakService;
import net.aim_ai.wms.service.WmsConstants;
import net.aim_ai.wms.service.PickingorderPositionService;
```

`WmsConstants` was inserted mid-run, breaking the alphabetical ordering the rest of the block keeps.
Move it after `PickingorderPositionService` (the two sibling controllers sidestep this entirely with
`net.aim_ai.wms.service.*`).

### L5 · Low — the four new UNGATED rows inherit the §0.C failure message

`row(class, path)` with no functions produces `EXPECTED == ""`, and the drift test's message for
that case is hard-coded to the OMS carve-out story:

> expected NO GATE (§0.C OMS carve-out) but carries a method-security annotation … an OMS service
> principal holds no role, so this breaks facility sync as surely as a @RequiresFunction would

For `/v3/clubLine/orderBatch/{orderBatchId}` and the other three that is false — they are ordinary
web reads deferred to SBDEV-3158, with no OMS caller (verified above). The block comment gets this
right in prose ("a red here is the pin working, not drift") but the assertion message a future
engineer actually reads will send them hunting a sync break that does not exist. Pre-existing shape
— 3142's five `DashboardController` rows have it too — but this change adds four more instances, so
it is worth one sentence in the message distinguishing "carve-out" from "not yet in scope", or a
third `row()` overload carrying a reason string.

### L6 · Low (pre-existing, but you are in the file) — limitation §3 looks wrong

> **3. Spring Data REST is entirely absent.** `RepositoryRestHandlerMapping` is not a
> `RequestMappingHandlerMapping`, so no SDR endpoint appears here.

`RepositoryRestHandlerMapping extends BasePathAwareHandlerMapping extends RequestMappingHandlerMapping`,
so `context.getBeansOfType(RequestMappingHandlerMapping.class)` should pick it up — which is why the
test prints `mappingBeans=` as a set rather than a single name. `FunctionGuardInterceptor`'s own
javadoc contradicts §3 directly ("Spring Data REST DOES reach here"), and the estate has already
recorded that six `src/main` javadocs claiming SDR is structurally unreachable were wrong. Not
introduced by this diff, and I could not run the test to confirm the bean set — but the new text
cites the `792 registrations` total that this claim bears on, so it is worth either correcting or
demoting to "SDR rows are generic templates (`/{repository}/{id}/{property}`), so no domain type
appears here". The latter is the practically important point and is true either way — it is also
why the five new tokens cannot collide with an SDR association path.

### L7 · Low (advisory, no action required) — `/run` and `/activate` are unbounded prefixes

Measured zero collisions today, and I confirmed the specific claim you flagged: **`/assign` does not
subsume `/reassign`** — the literal `/assign` is absent from `/reassignTransferLane` because the
slash is followed by `r`, so both tokens are genuinely needed. Also confirmed no collision with
`/v3/clubLine/activeClubRun`, `/v3/transfers/activeTransfer`, `/v3/clubLine/openClubRun`
(`active` ≠ `activate`; `/run` needs the leading slash). But `/run` would match a future
`/runtime*` or `/runningTotals*`, and `/activate` a future `/activateUser`. That is the same
exposure the existing `/create` and `/delete` tokens carry, and the heuristic is explicitly
advisory with no assertion attached — noting it only so the next slice does not re-derive it.

### Informational — `harness.md` now disagrees with what shipped

`SBDEV-3155-evidence/harness.md:132-133` prescribes `hasSize(141)` and `141 = 131 + 10`. The
implementation correctly went to 145 by adding the four UNGATED sibling rows, which is the better
call. Expected drift in a pre-implementation research note; flagging only so nobody later reads
141 as the intended number.

---

## Q6 — dead or redundant work

Nothing dead. Every one of the fourteen pin rows does work the others do not: the ten gated rows
catch annotation deletion and path rename, the four UNGATED rows are the only thing in the
repository that catches a class-level annotation on these two classes (verified against
`FunctionGuardArchTest` and `FunctionGuardStartupAssertion`, both scoped elsewhere). The stated gap
— that no such row is possible for `PickingOrderPositionController` because `fixPickingPosition` is
its only declared handler — is accurate; I read the whole file to confirm.

The overstatements are the four claims in M1, M2, M4 and L1. Everything else the comments assert,
I was able to reproduce.
