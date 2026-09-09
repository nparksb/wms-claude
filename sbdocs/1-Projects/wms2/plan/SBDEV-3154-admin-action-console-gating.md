---
title: "Gate the 6 AdminActionController operator-console routes on the existing WEB_UI_VIEW_IMPORT_DATA — zero new constants, no migration"
ticket: "SBDEV-3154"
ticket_url: "https://app.clickup.com/t/868ky26k5"
type: "bugfix"
priority: "normal"
status: "ON DEV 2026-09-01 — merged to develop as ad681319 (PR #259, commit 205e3034). Verified on origin/develop post-merge: 6 annotations, no class-level, not in GUARDED, accessAudit untouched, pin 131. Zero new constants, no migration, T2. NOT on main/prd. All 7 ACs resolved (5 met, 2 struck)."
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-01"
updated: "2026-09-01"
tier: "T2 — was T3 while a Flyway migration was in scope; deleting the migration removes that trigger. Authorization remains, hence T2 not T1."
db_verified: true
db_verification_note: >
  Verified 2026-09-01 across all SIX v2 tenant DBs and independently re-measured by a fact-check
  lane, which confirmed every number: dev_wh01_om1, wh01_om1_v2 (WineCo UAT), wh01_hydra_v2 on the
  PRD server (Hydra PRD -- the only v2 production client), wh01_hydra_v2 on the UAT server (same
  database NAME, different server -- do not conflate), wh01_shipitez_v2, wh02_shipitez_v2.
  THE DECISIVE MEASUREMENT: on every one of the six, the set of users holding
  WEB_UI_VIEW_IMPORT_DATA is IDENTICAL to the set reachable via super-admin --
  37/35/7/15/23/9, difference 0 on all six, PRD included. So gating on the existing screen
  function changes the reachable set by zero users, which is exactly what a new constant granted
  to super-admin would have achieved, at the cost of a Flyway run on every tenant.
  Counted by USER population through mywms_function -> mywms_role_mywms_function ->
  mywms_group_mywms_role -> mywms_group_mywms_user (AC-2'), never by role name. Blind spot: the
  direct mywms_user_mywms_role path is not walked, correctly -- direct user->role assignment
  confers nothing in v2, since getAllRoles only walks user->group->role->function.
related:
  - "[[SBDEV-3017-B1-mvc-write-surface-gating]]"
---

# SBDEV-3154 — gate the 6 AdminActionController operator-console routes

## 0. Triage verdict, and the re-scope

```
TRIAGE SBDEV-3154
  reproduces:     yes — all 6 routes ungated on origin/develop 2e757457; grep -c RequiresFunction
                  on AdminActionController.java = 0. Citations :105/:120/:134/:243/:256 exact.
  already fixed:  no
  real cause:     as reported
  tier:           T2  (was T3; the Flyway migration that made it T3 is deleted — see §1)
  needs a plan:   marginal. This document exists to carry the §9.16 reversal rationale, which the
                  ticket contradicts. The change itself is 6 annotations and two tests.
```

**This plan reverses the ticket's central premise.** The ticket's own title says it "needs 2 new
FunctionEnum constants and Flyway V2.2.22". It needs neither.

## 1. The re-scope — §9.16 Option B

**Decision: Nam, 2026-09-01.** All six routes gate on the **existing** `WEB_UI_VIEW_IMPORT_DATA`.
Zero new constants, no migration, no grants.

### 1.1 Why the ticket was wrong

SBDEV-3017 **§9.16** (Nam, 2026-08-27) already set the rule: *"each of the six putaway sites takes
the function that already gates the screen it is reached from. No … constant is created."* **§9.17.1**
then traced the consequence — *"`V2.2.22` is not needed at all … the tier drops T3 → T2."*
SBDEV-3154 revived that same constant, renamed, without engaging §9.16 anywhere.

The screen five of these six routes are dispatched from is **Admin → System Management**, gated by
`WEB_UI_VIEW_IMPORT_DATA`:
- `wms2-web-ui pages/admin.vue:56` — `{ text: 'System Management', fn: 'WEB_UI_VIEW_IMPORT_DATA', component: 'SystemManagement', canonical: 0 }`
- `wms2-web-ui util/appMenuList.js:132` — `'WEB_UI_VIEW_IMPORT_DATA', // System Management`

**And the populations are identical.** On all six tenants the holders of `WEB_UI_VIEW_IMPORT_DATA`
are exactly the users reachable via `super-admin` — 37/35/7/15/23/9, difference **0** everywhere,
PRD included. A new constant granted to `super-admin` would therefore have produced the *same
reachable set* as the constant that already exists, while adding two near-irreversible seeded rows
and a Flyway run on six databases.

### 1.2 The convention objection, withdrawn

An earlier revision of this plan argued that a `WEB_UI_VIEW_*` constant gating a mutation reads as
read-only and should be `WEB_UI_ACTION_*`. **That objection is withdrawn.** §9.16.2 examined exactly
it and settled it with a review lane's verification: *"`WEB_UI_VIEW_*` constants name **screens**,
not entities and not read-only-ness … So this is within the convention."* The precedent is not
theoretical — §9.15 decision 4 sent `ItemDataController:105` onto `WEB_UI_VIEW_ITEM_DATA`, and R6
gated `ShipperIdController` on `WEB_UI_VIEW_CLIENT`, both writes on VIEW constants.

### 1.3 Option B also removes a real over-gating hazard

Because the gate **is** the screen's own gate, AC-2′ holds trivially: anyone who can open the tab
already holds the function. `components/admin/systemManagement/actions.vue` performs **no per-button
function check**, so under the two-new-constant design a `WEB_UI_VIEW_IMPORT_DATA` holder without
the new grants would have seen five buttons and had four of them 403. Under Option B that state is
unreachable by construction.

That also disposes of a contingency a review lane raised against the two-constant design: the
"0 users lose access" figure is not structural, because three non-`super-admin` roles
(`ROLE000068`, `ROLE000113`, `ROLE000132`) already hold `WEB_UI_VIEW_IMPORT_DATA` on WineCo dev and
WineCo UAT. ⚠ The lane described them as *"attached to no group"*; measured, each **is** attached to
exactly one group — the *groups* are empty (`groups_attached = 1`, `users_reached = 0`). So the drift
path is one step shorter than reported: adding a single user to an existing group, not attaching a
role. Under the two-constant design that user would immediately have hit four 403s. **Under Option B
they simply pass the gate**, because the gate is the function they hold.

The residual, stated so nobody is surprised later: Option B makes the gate *exactly as wide as the
screen*, which is the intent — but the screen's function is held by three roles beyond
`super-admin`, and populating any of their groups widens who can trigger these five routes. That is
a grant-administration decision, visible in User Management, not a code change.

### 1.4 A hidden cost the two-constant design carried, found only by the migration lane

Worth recording because it is the strongest practical argument for Option B and it was in nobody's
acceptance criteria. A new constant needs **three** things shipped, not two:

`AccessService.updateFunctionList()` reflects over `FunctionEnum` and creates the `mywms_function`
**row**, but grants nothing. `UtilRestController.initDB` enumerates super-admin's grants as **77
individually hand-written `addFunctionToRole` lines**, and it builds its *own* `super-admin` rather
than the base dump's. So on the fresh-provisioning path the migration would have granted one
`super-admin` while `initDB` created another without the two new lines — and **every tenant
provisioned from that point would have had all four routes 403 for everyone, permanently, with no
menu change to signal it.** The immediate precedent (`WEB_UI_VIEW_PARCEL_PICKING`, SBDEV-2967-B)
shipped constant + migration + `initDB` line; this plan's §3 had only the first two. The repo already
treats the divergence as a rule with its own test (`UtilRestControllerSeedUnitTest` C-8d), and
nothing in the suite would have caught the omission.

**Option B has no such surface**: no constant, no row, no grant, so no seeding path to diverge.

## 2. What ships

Six method-level annotations. Nothing else.

| id | route | site | gate |
|---|---|---|---|
| C30 | `POST /v3/adminAction/recoverStuckPallets` | `AdminActionController:263` | `WEB_UI_VIEW_IMPORT_DATA` |
| C31 | `GET /v3/adminAction/triggerOrderReplenish` | `:107` | `WEB_UI_VIEW_IMPORT_DATA` |
| C32 | `GET /v3/adminAction/triggerArchiveMessages` | `:123` | `WEB_UI_VIEW_IMPORT_DATA` |
| C33 | `GET /v3/adminAction/testCrmConnectivity` | `:138` | `WEB_UI_VIEW_IMPORT_DATA` |
| C34 | `GET /v3/adminAction/listRecoverableStuckPallets` | `:249` | `WEB_UI_VIEW_IMPORT_DATA` |
| C35 | `GET /v3/adminAction/finishStuckPickingOrder/{number}` | `:185` | `WEB_UI_VIEW_IMPORT_DATA` |

All line numbers here are **post-change** (the diff inserts 7 lines above the originals: 1 import +
6 annotations). The ticket's pre-change citations were `:105/:120/:134/:256`, all confirmed exact
before the edit.

C31–C33 are mutating GETs; C34 is a genuine read. **C34 was added to scope on Nam's decision
2026-09-01**: it is the list feeding the very modal whose confirm is C30, so gating the confirm while
leaving the list readable by any `wms_user` is a split state. It costs one annotation and no
migration. No `WmsConstants` change, no `V2.2.23`, no `mywms_function` INSERT, no
grant, no `UtilRestController.initDB` concern, no per-tenant migration verification.

### 2.1 The gate does fire — verified, because this is the whole ticket

A method-level `@RequiresFunction` on a plain `@RestController` **is** enforced without `GUARDED`
membership. `FunctionGuardInterceptor` (around :238-260) resolves the annotation method-first then
class, and `GUARDED` governs only the branch where **no** annotation resolved:

```java
if (annotation == null) { if (!GUARDED.contains(declaring)) { return true; } ... }
AccessDecision decision = accessService.checkAnyAccess(username, annotation.value());
```

Three supporting conditions, all satisfied: the interceptor is registered as a `MappedInterceptor`
bean on `/**` (`WebConfig.java:86-87`), so every `AbstractHandlerMapping` collects it;
`SecurityConfiguration` already admits an authenticated `wms_user` to `/v3/adminAction/**`, so the
request reaches MVC; and the mechanism is **already shipped** — `ReportController` is not in
`GUARDED` and carries 15 method-level `@RequiresFunction` annotations (SBDEV-3142, `on dev`). Source
plus shipped precedent: two instruments.

## 3. Where to put the annotations — the prohibitions still stand

- ⛔ **Never annotate `AdminController`.** It is a base class for **43** controllers (measured; the
  ticket's "~45" is imprecise), so an annotation there registers under all of them.
- ⛔ **No class-level `@RequiresFunction` on `AdminActionController`.** Nine handlers total; after
  this change six are gated here and **three** are not: `triggerUpdateStock` (:115),
  `triggerReleaseExpiredPickingOrdersFromUser` (:130), and `accessAudit` (:349) — the last
  **already** `@PreAuthorize(IS_SB_ADMIN)` at :348, so it is not ungated and a class default would
  stack a function requirement on top of an sb_admin gate. Line numbers are POST-change.
- ⛔ **Never add `AdminActionController` to `FunctionGuardInterceptor.GUARDED`.** Membership
  fail-closes unannotated handlers, and `FunctionGuardStartupAssertion:74` turns that into a
  **boot-time failure** — the Spring context refuses to start.

## 4. Tests

### 4.1 Extend the presence pin

Add six gated `row(...)` entries plus two UNGATED sibling rows to `Sbdev3017TrancheGateContextTest`
(`src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java`, 410 lines, surefire
lane) and bump `assertThat(EXPECTED).hasSize(123)` → `131` (8 new rows: 6 gated + 2 asserted UNGATED).

### 4.2 Add the denial half — the pin alone is not enough

The pin resolves annotations reflectively; it proves **presence**, never a 403. SBDEV-3017's own AC
for this class was *"a caller denied the function receives 403"* and inspection never satisfied it.
Templates exist in-repo: `unit/controller/ReportReadGateUnitTest.java` (SBDEV-3142) and
`security/SdrReadGateEnforcementContextTest.java`, which asserts `status().isForbidden()`. Add one
denial test per route, or one parameterised over the six.

### 4.3 Mutation checks — with corrected predictions

| mutant | expected outcome |
|---|---|
| delete C30's annotation | that row reports `[]` vs expected; only that row |
| delete C31's annotation | that row only |
| replace all six with one class-level default | ⚠ **SURVIVED at first.** Only the two UNGATED sibling rows catch it — with gated rows alone, a class annotation resolves identically for every one of them and the whole suite stayed green. The ungated rows are load-bearing |
| add `AdminActionController` to `GUARDED` | ⚠ **the context refuses to boot and the pin fails to LOAD** — an initialization error, not an attributable row failure. An earlier revision of this plan predicted "stays green", citing the test's javadoc as saying the opposite of what it says (:312-315) |
| drop one `row(...)` from `EXPECTED` | `hasSize(131)` fails |
| deny the function for the caller | the §4.2 denial test 403s; the presence pin stays green — which is the point of adding §4.2 |

### 4.4 What no test here sees

- **No arch rail inspects these five sites.** `FunctionGuardArchTest`'s AC-3 iterates the 14
  `GUARDED` controllers plus four `SHARED_CONTROLLERS`; `AdminActionController` is in neither. So no
  rail will break, and none will cover them.
- The presence pin cannot distinguish a granted from a denied caller. Hence §4.2.

## 5. Acceptance criteria

- [x] **AC-1** All six routes carry a method-level `@RequiresFunction(WEB_UI_VIEW_IMPORT_DATA)`
- [x] **AC-2** `AdminController` carries none; no class-level annotation on `AdminActionController`;
      `AdminActionController` not in `GUARDED`
- [x] **AC-3** A denied caller receives **403** on each of the six (§4.2), not merely an assertion
      that an annotation exists
- [x] **AC-4** Presence pin extended to 131 rows; every new assertion mutation-checked with an
      attributable red
- [x] **AC-5** Full suite compared against a freshly measured baseline **by failure name, not
      count** — the count moved 5846 → 5937 in one day on 2026-09-01
- [ ] ~~AC-6 Flyway version re-checked before merge~~ — **struck: there is no migration.**
- [ ] ~~AC-7 Per-tenant grant verification~~ — **struck: no grants are written.** The population
      evidence in the frontmatter is what replaces it, and it is already measured on all six.

## 6. Siblings — two folded in, two deliberately not

**`listRecoverableStuckPallets` (C34) is IN scope** (Nam, 2026-09-01). It is the list behind the
Recover Stuck Pallets modal whose confirm is C30; gating the confirm while leaving the list readable
by any `wms_user` is a split state. ⚠ A security lane rates the *value* here modest and it is worth
being precise: `findRecoverableStuckPallets` is `@RestResource(exported = false)`
(`UnitloadRepository:281`) so the *query* has no SDR route, but the **rows** remain reachable by
chaining two ungated SDR GETs — `/v3/location/search/findByName?name=Nirwana` then
`/v3/unitload/search/findByStoragelocationId`. So C34 closes the **triage computation**, not the
data. It is coherence, not containment, and should not be described as closing a read.

**`finishStuckPickingOrder` (C35) is IN scope, added after a security lane rated it HIGH.** It was
in the "stays ungated" set until that review, and leaving it there would have been the worst call in
this plan. `GET /v3/adminAction/finishStuckPickingOrder/{number}` reaches
`PickingorderBusinessService.finishPickingOrder`, which in one transaction flips the linked
`Customerorder` to `PICKED`/`PENDING`, transfers unfinished totes, returns unpicked positions to the
pool, **and enqueues a `PICKING_FINISHED` outbox notification to OMS** — so the damage leaves WMS.
`SecurityConfiguration` admits any `wms_user` to `/v3/adminAction/**`, so before this change every
operator, including a mobile picker, could call it. Measured on `dev_wh01_om1`: **100 `mywms_user`
rows could reach it; after this change 37 can** — the holders of `WEB_UI_VIEW_IMPORT_DATA`.

⚠ **Why `WEB_UI_VIEW_IMPORT_DATA` for a route with no screen.** Option B says "take the function that
gates the screen you are dispatched from", and C35 has **no UI caller in either UI** — so there is no
screen to inherit from and Option B does not decide it. The reasoning is different and is stated here
rather than left implicit: the function is chosen because C35 is a **handler on the operator-console
controller**, so the console's own entitlement is the closest existing fence, and because minting a
constant for it would reintroduce the migration, the `initDB` grant line and the T3 tier that §1
exists to avoid — for a route nothing in either UI calls. If a screen is ever built for it, revisit.
The same argument would apply to `triggerReleaseExpiredPickingOrdersFromUser`; it stays ungated only
because it is outside SBDEV-3017's §1 slice, which is a scope boundary and not a safety claim.
✅ **Closed 2026-09-02 by SBDEV-3198 AC13**, on exactly this reasoning — the console controller's own
entitlement, no new constant — after a live dev probe measured a non-super-admin `wms_user` reaching
it at HTTP 200. Authorization only: its cross-tenant fan-out (§5.2a of the 3198 plan) is still open.

What made C35 worse than the siblings that stay open is that it has **no `/rest/**` twin**, so the
cosmetic-gating rationale that legitimately spares `triggerUpdateStock` does not transfer to it — and
its zero UI callers meant nothing signalled it was reachable at all. The exploit needs only an
ungated SDR read
(`GET /v3/pickingorder?size=1000` — `Pickingorder` is write-withdrawn but readable) to find a
`number` at state 500. Measured on Hydra PRD: `pickingorder` states are `500 → 1`, `700 → 38`,
`800 → 78`, so the window is narrow today, non-empty, and refills as orders are picked.

**`triggerUpdateStock` (:115) stays ungated, deliberately.** Gating it on `AdminActionController`
alone would be **cosmetic**: `StockCountRestController:103` exposes
`GET /rest/stockcount/triggerStockCount` onto the same `stockSummaryExportJob` (`:110`), and
`SecurityConfiguration:150-154` `permitAll()`s `/rest/**`. Per Nam's 2026-08-27 decision `/rest/**`
is internal-only WMS↔OMS and not a live exposure, so this is **not** an escalation and no ticket is
proposed — but any future ticket gating `triggerUpdateStock` must scope the `/rest/` twin or it
achieves nothing.

~~**`triggerReleaseExpiredPickingOrdersFromUser` (:130) stays ungated** (not in SBDEV-3017's §1
slice).~~ **GATED 2026-09-02 by SBDEV-3198 AC13.** **`accessAudit` (:349) is already
`@PreAuthorize(IS_SB_ADMIN)`** and must not be touched.

⚠️ **The "two ungated rows make the prohibition enforceable" claim is now stale, and its successor is
different in kind.** After AC13 there is **one** ungated row (`triggerUpdateStock`), which is still
sufficient — verified, not assumed: a class-level annotation makes that row resolve to
`WEB_UI_VIEW_IMPORT_DATA` against an expected `[]` and the drift test reddens.

But the row-based mechanism is a **proxy that is being consumed**: two rows → one → and SBDEV-3124
will gate the last one, at which point the bucket is empty and the class-level mutation goes invisible
again. `thePinHasNotBeenQuietlyShrunk` cannot catch that either, because moving a row between buckets
leaves the total at 145 exactly — which is literally what AC13 did. So AC13 added a **direct**
assertion, `adminActionControllerCarriesNoClassLevelFunctionGate`, which asserts the absence of the
class-level annotation itself and survives the last ungated row being gated. Verified by mutation:
with a class-level annotation added *and* `triggerUpdateStock` gated, that new test is the **only** one
of three that fails. Prefer it to the row proxy when reasoning about this prohibition.

## 7. Recorded and deliberately deferred

- **Audit-erasure bundling.** `triggerArchiveMessages` → `MessageRepository.archiveMessages` empties
  the `message` table, which **is** the Service Log — the record of having triggered the other
  routes. A review lane recommended a dedicated constant so that triggering jobs and deleting the
  log of triggering them are separately grantable. Deferred because under Option B the populations
  are identical on all six tenants, so the split would be theoretical today; mint it when a real
  delegation is wanted. **Recorded here so it is not re-derived from scratch.**
- **`testCrmConnectivity` is not SSRF-closed by this gate.** The target URL is read from a sysprop at
  call time, and `sysprop` is deliberately excluded from the SDR write withdrawal
  (`RestConfiguration:306-310`). The gate closes *who can press the button*, not *who can change
  where WMS calls out*. ⚠ A security lane found the payload is worse than "an outbound GET":
  `HttpRestService.applyHeaders` attaches the **OMS Basic-Auth credential** to the call, so a
  rewritten URL exfiltrates that credential to a host of the attacker's choosing. What this gate
  does close is the *self-service* variant — one `wms_user` could previously both rewrite the URL and
  press the button; now it degrades to a stored, confused-deputy shape needing a function holder to
  trigger it. The SSRF class itself is untouched and has 19+ other producers on paths needing no
  function. Pre-existing, out of scope, and not measured exploitable — a 400 from an SDR write verb
  proves nothing either way.
- **Per-item replenishment is not fenced.** `StockunitService.triggerReplenishmentMaintenance` and
  `FixLocationAssignmentService.triggerReplenishmentMaintenance` reach
  `recalculateForItem`, swallowed in `catch (Exception e) { LOG.warn }`, as a side effect of ordinary
  writes. C31 fences the warehouse-wide sweep only. The **order-release** half *is* fully fenced:
  `orderReleaseJob.doCalculation(` appears at exactly two sites — `AdminActionController:108` and
  `SchedulingConfiguration:204` (the cron).

## 8. Corrections to earlier revisions of this document

Kept because the errors are instructive, not to pad the record.

1. **"No menu entry and no UI caller" was FALSE** — inherited from the ticket and asserted twice.
   `actions.vue` has five live buttons and `store/admin/mgmt/action.js` calls all four routes; there
   is a Cypress suite exercising them. Two independent lanes caught it. The conclusion (0 users lose
   access) survived, but for a different reason — a grant coincidence, not the absence of a UI.
2. **"Exactly four NOT NULL-no-default columns" on `mywms_function` was wrong — there are five.**
   Moot now that no INSERT is written, recorded so it is not copied forward.
3. **"Production has neither a PK nor a unique index on `mywms_role_mywms_function`" was WRONG** —
   PRD *does* have `mywms_role_mywms_function_pkey`. This claim was inherited from V2.2.21's own
   header comment, so **the error is upstream and still live in that file**; anyone reasoning about
   fleet constraint shapes from V2.2.21 will inherit it. ⚠ It **cannot be fixed in place**: Flyway
   checksums the whole migration file including comments, so editing an applied migration fails
   `validate` on every database that ran it. The correction has to live outside the file — here, and
   in whatever doc a future migration author actually reads.
4. **"Nothing executes the migration" was FALSE** — eight `*IntegrationTest` classes already run the
   whole `classpath:db/migration` chain. Moot here, but it means future migrations *do* have a cheap
   instrument that V2.2.19's header comment claims does not exist.
5. **"~45 controllers"** → 43 direct subclasses. **"Four other handlers"** → five, one already
   sb_admin-gated. **The `GUARDED` mutant** does not stay green; it prevents the context booting.

Review evidence: `SBDEV-3154-evidence/{fact-check,migration-review,authz-review,design-critique}.md`.
