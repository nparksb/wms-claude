# SBDEV-3154 fact-check lane — every factual claim and citation

Target plan: `sbdocs/1-Projects/wms2/plan/SBDEV-3154-admin-action-console-gating.md`
Lane scope: **facts and citations only.** Design/approach is another lane's.
Baseline: `origin/develop` @ `2e9ddcfa` ("Merge pull request #256 from SiteBossInc/SBDEV-3153-refill-sargable-not-exists", 2026-09-01 09:20 -0400). Every code claim derived with `git show origin/develop:<path>` / `git grep origin/develop` / `git ls-tree`, never from the local checkout.
DB: all six v2 tenants queried live 2026-09-01 via MCP.
Method note: `mcp__*__execute_sql` truncates long single values; every schema/index claim below was re-run as multi-row output to avoid a truncated string being read as a complete one.

---

## 0. Verdict at a glance

| # | Claim group | Verdict |
|---|---|---|
| 1 | four route→line citations, verbs, paths, ungated | **CONFIRMED** |
| 2 | no class-level `@RequiresFunction`; extends `AdminController`; "~45 controllers" | **CONFIRMED / number imprecise (43 direct)** |
| 3 | absent from `FunctionGuardInterceptor.GUARDED` | **CONFIRMED** |
| 4 | the four §7 siblings exist and are ungated | **CONFIRMED, but the enumeration is INCOMPLETE — five siblings, not four** |
| 5 | `FunctionEnum` at :347, 8 `WEB_UI_ACTION_*`, last at :433 | **CONFIRMED (every sub-claim)** |
| 6 | neither new constant exists in src/main | **CONFIRMED (nowhere in the repo, not just src/main)** |
| 7 | `V2.2.22` taken, `V2.2.23` free on every remote branch | **CONFIRMED (independently re-derived)** |
| 8 | schema claims on `mywms_function` | **3 of 4 CONFIRMED; "exactly the four NOT NULL-no-default columns" is WRONG — there are five** |
| 9 | six-tenant table (82 / 0-of-2 / super-admin / 37-35-7-15-23-9 / Flyway) | **CONFIRMED — every number correct, and the join is the right one** |
| 10 | `Sbdev3017TrancheGateContextTest` 410 lines, `hasSize(123)`, surefire lane | **CONFIRMED (every sub-claim)** |
| 11 | PRD has neither PK nor unique index on `mywms_role_mywms_function` | **WRONG — PRD has `mywms_role_mywms_function_pkey` PRIMARY KEY** |
| ✗ | §2.2/§6.1/§6.4 "no menu entry and no UI caller" | **WRONG, and it is the worst error in the plan** |
| ✗ | §4.2/§4.3 "the pin does not see GUARDED membership / stays green" | **WRONG for the mutation the plan itself proposes** |

**Count claims are in excellent shape** (§9 below: 12 of 12 measured numbers correct). **Completeness claims are where this plan breaks** — four of the five errors are sentences containing *no / only / every / exactly / four*.

---

## 1. The four route→line citations — CONFIRMED

`src/main/java/net/aim_ai/wms/controller/AdminActionController.java` on `origin/develop` (347 lines). Full handler inventory:

| line | verb | path | in plan? |
|---|---|---|---|
| 105 | `@GetMapping` | `/triggerOrderReplenish` | ✅ C31 |
| 113 | `@GetMapping` | `/triggerUpdateStock` | sibling |
| 120 | `@GetMapping` | `/triggerArchiveMessages` | ✅ C32 |
| 127 | `@GetMapping` | `/triggerReleaseExpiredPickingOrdersFromUser` | sibling |
| 134 | `@GetMapping` | `/testCrmConnectivity` | ✅ C33 |
| 180 | `@GetMapping` | `/finishStuckPickingOrder/{number}` | sibling |
| 243 | `@GetMapping` | `/listRecoverableStuckPallets` | sibling |
| 256 | `@PostMapping` | `/recoverStuckPallets` | ✅ C30 |
| 342 | `@GetMapping` | `/accessAudit` | **sibling the plan never names** |

- Line numbers: all four cite the **mapping annotation** line (method declaration is +1). Correct and internally consistent.
- Verbs: GET/GET/GET/POST — correct.
- Paths: class carries `@RequestMapping("/v3/adminAction")` (:39), which overrides the inherited `AdminController` `@RequestMapping("/v3")` (:29). So `/v3/adminAction/<name>` — correct.
- **Genuinely ungated (method OR class OR inherited): CONFIRMED.** `grep -c RequiresFunction` on the file = **0**. `AdminController` carries no class-level `@RequiresFunction` (its class annotations are `@Tag`, `@RestController`, `@RequestMapping("/v3")`). `AdminActionController` is not in `GUARDED` (item 3). So `FunctionGuardInterceptor`'s resolution (method → declaring class) finds nothing on any of the four.
- Also true and worth adding to the plan for precision: the only method-security annotation anywhere on the class is `@PreAuthorize(Authority.IS_SB_ADMIN)` at **:341** (guarding `accessAudit` only). None of the four carries one.

### 1a. Context the plan omits — "ungated" ≠ "unauthenticated"
`SecurityConfiguration.java:157-160` has a block labelled **"C. Admin-Only WMS Endpoints"** that matches `"/v3/adminAction/**"` … `.hasAnyAuthority(Authority.WMS_USER_ROLE)`. `WMS_USER_ROLE = "wms_user"` (`Authority.java:136`) — the **same** authority as the catch-all `/v3/**` block at :178. So the "Admin-Only" label is inert: the four routes require only `wms_user`, which every WMS user holds. The plan's "ungated" verdict is correct in substance; stating this explicitly would pre-empt a reviewer thinking the matcher already covers it.

---

## 2. `AdminActionController` / `AdminController` — CONFIRMED, number imprecise

- No class-level `@RequiresFunction` on `AdminActionController`: **CONFIRMED** (0 occurrences in the file).
- `extends AdminController` (:40): **CONFIRMED**.
- "base class for ~45 controllers … registers under all 45 prefixes": **imprecise.** Measured on `origin/develop`:
  - **43** direct subclass declarations (`public class X extends AdminController {`) — the 45 raw `git grep` hits include two comment lines (`ShipperIdController.java:77`, `UnitLoadController.java:63`).
  - **+1 indirect**: `DashboardController extends ReportController` (`DashboardController.java:26`), and `ReportController extends AdminController` (:32) → **44 descendant controllers**.
  - **45 mapping roots** only if you also count `AdminController` itself, which is `@RestController` and therefore its own bean.
  - The repo states 43 twice in its own source: `AdminActionController.java:338` ("all 43 subclass prefixes") and `FunctionGuardStartupAssertion.java:26` ("base class for 43 controllers"). **Use 43 direct / 44 descendants**; "~45" is off by one to two against the repo's own figure. Not material to the conclusion (don't annotate the base class), but it's a citable number that should match the source.

---

## 3. Absent from `GUARDED` — CONFIRMED

`FunctionGuardInterceptor.java:118-149` — `static final Set<Class<?>> GUARDED = Set.of(...)`, **14 entries**: `LookupController`, `PutawayController`, `MoveUnitloadController`, `MoveStockController`, `PickingController`, `PalletizingController`, `TruckLoadingController`, `CycleCountLosController`, `ReplenishController`, `TransferOrderController`, `OrderCancellationController`, `UserRoleController`, `UserGroupController`, `UserController`. `AdminActionController` is **not** among them. (The javadoc at :116 says "The fourteen controllers" — count matches.)

---

## 4. The §7 siblings — the four named are real and ungated, but the enumeration is INCOMPLETE

The plan says, twice (§3.2 second ⛔ bullet, and §7): *"It carries **four** other handlers this ticket does not gate"* / *"The **four** sibling handlers"*, naming `triggerUpdateStock`, `triggerReleaseExpiredPickingOrdersFromUser`, `finishStuckPickingOrder`, `listRecoverableStuckPallets`.

- All four exist (:113, :127, :180, :243) and carry no `@RequiresFunction` and no method-security annotation. **CONFIRMED.**
- **But there are FIVE other handlers.** `accessAudit` (`@GetMapping "/accessAudit"`, :342) is a fifth, guarded by `@PreAuthorize(Authority.IS_SB_ADMIN)` at :341. Nine handlers total: 4 gated by this ticket + 5 others.
- Impact: the plan's *conclusion* survives (a class-level `@RequiresFunction` would sweep in five handlers rather than four, so still don't do it — and on `accessAudit` it would stack a function requirement on top of an sb_admin gate). But an enumeration presented as exhaustive that misses a handler is exactly the failure this repo keeps paying for, and §7's "stay ungated" is inaccurate for `accessAudit`, which is not ungated at all.
- Fix: say "five other handlers, one of which (`accessAudit`, :342) is already `@PreAuthorize(IS_SB_ADMIN)`".

---

## 5. `WmsConstants.FunctionEnum` — CONFIRMED, every sub-claim

`src/main/java/net/aim_ai/wms/service/WmsConstants.java` @ `origin/develop`:

- `public static final class FunctionEnum {` at **line 347** ✅ (private ctor at :349 — it is not a Java enum, as the plan says).
- `String` constants ✅ (first is `WEB_UI_LOG_IN` at :352).
- **Exactly 8** `WEB_UI_ACTION_*` constants ✅ — `grep -c 'public static final String WEB_UI_ACTION_'` = 8, at lines 426-433: `DELETE_UNIT_LOAD`, `DELETE_UNIT_LOAD_RECURSIVE`, `ADJUST_AMOUNT`, `ADJUST_RESERVED_AMOUNT`, `ADJUST_LOCK_RELEASE_LOCK`, `ADJUST_LOCK_ON_HOLD`, `ADJUST_LOCK_DAMAGED`, `PRINT_TOTE_LABELS`.
- Last is `WEB_UI_ACTION_PRINT_TOTE_LABELS` at **line 433** ✅.
- "before the `MOBILE_UI_*` block begins" ✅ — `MOBILE_UI_LOG_IN` is line **434**, immediately after.

---

## 6. Neither new constant exists — CONFIRMED (stronger than claimed)

`git grep -n 'RECOVER_STUCK_PALLETS\|SYSTEM_MANAGEMENT' origin/develop` over the **whole tree** (not just `src/main`) → **zero hits**. So neither `WEB_UI_ACTION_RECOVER_STUCK_PALLETS`, nor `WEB_UI_ACTION_SYSTEM_MANAGEMENT`, nor the rejected `WEB_UI_VIEW_SYSTEM_MANAGEMENT` appears in main, test, resources, or migrations. Greenfield.

---

## 7. Flyway version — CONFIRMED, independently re-derived

Re-derived without running the plan's script (the script does `git fetch --all --prune`, out of scope for a read-only lane):

- `origin/develop` migrations end at **`V2.2.22__seed_order_batch_update_priority_sysprops.sql`** → `V2.2.22` **TAKEN**. The plan's correction (a) is right, and the ticket's `V2.2.22` claim is indeed stale.
- Swept **all 195 remote branches** (`git branch -r`, HEAD excluded) × both migration dirs (`db/migration`, `db/landlord-migration`): the highest version anywhere is `V2.2.22`, and it exists under exactly **one** filename (no in-flight collision). **`V2.2.23` is FREE on every remote branch.** ✅
- Also `git ls-tree -r` per branch grepped for `V2.2.2[3-9]` → zero hits anywhere in any tree.
- Script location: `src/main/resources/db/check-migration-version-collision.sh` ✅ — exists there, is **not** in `sbdocs/9-System/scripts/`. Its header documents exit codes 0 = clear / 1 = taken, matching the plan's claim. Its own comment (:38-41) corroborates the plan's re-check-before-merge instruction. **Not executed by this lane** (it fetches); the substantive answer is confirmed independently.
- Precedent claim ✅: `V2.2.21` line 13 — *"If a future constant is added, it needs its own function-row step first — see V2.2.19 STEP 1 for the shape"*. The plan quotes this correctly.

---

## 8. `mywms_function` schema claims — 3 of 4 confirmed, one WRONG

Measured on **all six** tenants; all six agree on every row below.

| claim | verdict | evidence |
|---|---|---|
| "`number`, `version`, `function`, `client_id` are NOT NULL with no default … **exactly the four such columns**" | **WRONG — there are FIVE** | `information_schema.columns` where `is_nullable='NO' AND column_default IS NULL` → **`client_id, function, id, number, version`** on all six tenants. `id` is NOT NULL with no default too. |
| unique index on `(function)` named `uk_hxqe1tp0v5sk4le8ij6wmtrq1` | **CONFIRMED** | `pg_indexes`: `UNIQUE INDEX uk_hxqe1tp0v5sk4le8ij6wmtrq1 ON public.mywms_function USING btree (function)` — **identical name on all six**. Only two indexes exist: that one + `mywms_function_pkey` on `(id)`. |
| no sequence default | **CONFIRMED** | `pg_get_serial_sequence('mywms_function','id')` → NULL on all six. |
| `number = function = name` for all 82 rows | **CONFIRMED, and fleet-wide** | `count(*) WHERE number IS DISTINCT FROM function OR name IS DISTINCT FROM function` = **0 on all six**, not just dev. Bonus: `version <> 0` = 0 and `client_id <> 0` = 0 on all six, so the plan's `version = 0` / `client_id = 0` shape claims also hold fleet-wide. |
| "Eight columns, always" | **CONFIRMED** | `id, created, modified, name, number, version, function, client_id`. |

**On the "exactly four":** the plan inherited this from `V2.2.19` line 50-51, which states it **correctly** — *"FOUR NOT NULL columns with NO DEFAULT **beyond the id**"*. The plan dropped "beyond the id" and added the completeness assertion "(confirmed: they are exactly the four such columns)", converting a true statement into a false one. Practical impact is nil (the plan supplies `id` explicitly anyway, and the eight-column INSERT is correct), but the parenthetical claims a verification that contradicts the measurement. Fix: restore "beyond the id", or say five.

Also CONFIRMED: the plan's "Guard on `function`, not `name`" reasoning is a faithful reproduction of `V2.2.19` STEP 1's own comment (`V2.2.19` lines 74-77), and `name` is indeed nullable with no unique index.

---

## 9. The six-tenant table — CONFIRMED, all 12 numbers, and the join is right

Measured 2026-09-01. `super-admin` is matched on `mywms_role.name` (**not** `mywms_role.number` — on dev that role's `number` is `ROLE000007`, and keying on `number` returns 0 rows fleet-wide). The plan's "Grants keyed by role *name*" is therefore not merely a safety preference, it is the only key that works; worth stating that way.

| tenant | database | `mywms_function` rows | new constants | `super-admin` | users via group | users via direct | Flyway max | `max(id)` |
|---|---|---|---|---|---|---|---|---|
| WineCo dev | `dev_wh01_om1` | **82** | **0** | id 51806 | **37** | 0 | **2.2.22** | 30,704,227 |
| WineCo UAT | `wh01_om1_v2` | **82** | **0** | id 51806 | **35** | 0 | **2.2.21** | 34,421,425 |
| Hydra **PRD** | `wh01_hydra_v2` | **82** | **0** | id 585 | **7** | 0 | **2.2.21** | 132,923 |
| Hydra UAT | `wh01_hydra_v2` | **82** | **0** | id 50356 | **15** | 0 | **2.2.21** | 3,331,573 |
| ShipItEZ c1wh | `wh01_shipitez_v2` | **82** | **0** | id 50406 | **23** | 0 | **2.2.21** | 5,565,804 |
| ShipItEZ nywh | `wh02_shipitez_v2` | **82** | **0** | id 585 | **9** | 0 | **2.2.21** | 926,408 |

- 82 everywhere ✅ · 0 of 2 everywhere ✅ · `super-admin` present on all six ✅
- **37 / 35 / 7 / 15 / 23 / 9 = 126 — all six correct, sum correct** ✅
- Flyway: **only dev at 2.2.22, the other five at 2.2.21** ✅ (`has_2_2_22` = 1 on dev, 0 on the other five). §2.3 is right, including that five tenants will receive `V2.2.23` while still owing `V2.2.22`.
- `app.flyway.out-of-order` default-ON ✅ — `StartupFlywayMigrationRunner.java:60` `@Value("${app.flyway.out-of-order:true}")`; `StartupFlywayMigrator.java:38-49` documents exactly the late-merge case §2.3 relies on.
- id span "132,923 → 34,421,425" ✅ exact. Risk 3's "dev: 30,704,228/229" ✅ (dev `max(id)` = 30,704,227).
- **Is the join the right one? Yes.** `mywms_role → mywms_group_mywms_role(rolelist_id, grouplist_id) → mywms_group_mywms_user(grouplist_id, userlist_id)` is the group path, and per this repo's authorization model `UserRepository.getAllRoles` only walks user→group→role→function, so a direct grant confers nothing. I cross-checked the direct path anyway (`mywms_user_mywms_role(user_id, roles_id)`): **0 users on all six**, so the group join loses nobody. AC-2′ (count users, not roles) is satisfied.

---

## 10. `Sbdev3017TrancheGateContextTest` — CONFIRMED, every sub-claim

`src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` @ `origin/develop`:

- **410 lines** ✅ (`wc -l` = 410).
- `class Sbdev3017TrancheGateContextTest extends BaseRollbackIntegrationTest` at :56 ✅.
- `assertThat(EXPECTED).hasSize(123)` at **:408** ✅, in its own `@Test` (`thePinHasNotBeenQuietlyShrunk`) — the plan's "bump to 127" is a one-line change at :408.
- Resolves via `AnnotatedElementUtils.findMergedAnnotation` on method then **declaring** class (:284-286) ✅; keyed `declaringClass + " " + path` (:64-65) ✅.
- **Surefire lane: CONFIRMED.** `pom.xml:514-521` — surefire excludes only `**/*IntegrationTest.java` and `**/*E2ETest.java`. `…ContextTest` matches surefire's default `**/*Test.java` include and neither exclude. Failsafe's `<includes>` (`pom.xml:662-665`) are `**/*IntegrationTest.java` + `**/*E2ETest.java`, so it does not pick this class up either. The plan's contrast with SBDEV-3153's `*IntegrationTest` is correct.
- **"Add four `row(...)` entries" is the right count** — nothing extends `AdminActionController` (`git grep 'extends AdminActionController'` → 0 hits), so each of the four routes registers under exactly one prefix. This is the trap that made SBDEV-3142 need 26 rows for 13 `ReportController` handlers (two prefixes via `DashboardController`); it does not apply here. Plan is correct, though it never says why — worth one sentence.
- Minor wording: the plan says the pin "compares **every live handler** against an `EXPECTED` map". The loop direction is `EXPECTED → actual` (:360); a live handler absent from `EXPECTED` is not flagged. "compares every EXPECTED row against the live mapping" is the accurate phrasing.

### 10a. §4.2 / §4.3's GUARDED claims are WRONG
- §4.3 bullet 2: *"`FunctionGuardInterceptor.GUARDED` membership is not covered by this pin (its own javadoc says so). If GUARDED changes, this test stays green."*
- The javadoc it cites says the opposite of the second sentence. `Sbdev3017TrancheGateContextTest` :312-315: GUARDED membership is *"caught instead by `FunctionGuardStartupAssertion:74` — it fail-closes unannotated handlers, so **the context refuses to boot and this test cannot load**"*.
- Verified in source: `FunctionGuardStartupAssertion` is an unconditional `@Component` (:55) implementing `SmartInitializingSingleton`, and `afterSingletonsInstantiated` **throws `IllegalStateException`** when a GUARDED class has handlers resolving no function (:73-82). Its own javadoc (:50-53) names this precise case: *"The genuinely un-bootable split is … adding a class to `FunctionGuardInterceptor.GUARDED` without its class-level `@RequiresFunction`."* And `BaseRollbackIntegrationTest` is `@SpringBootTest(classes = StartApplication.class)` (:29), so that bean runs in this test's context.
- **Consequence:** the mutation §4.2 lists as *"covered elsewhere — the pin does not see GUARDED membership"* would in fact make `AdminActionController`'s five unannotated siblings boot-time violations, the context would fail to start, and **this very test would go red** (as an initialization error, not an attributable row failure). The plan's mutation table predicts the wrong outcome for one of its five mutants, and §4.3 tells a future reader the test stays green when it will not even load.
- The plan's *design* choice (don't add it to GUARDED) is unaffected; the stated reason and the predicted mutant behaviour are wrong.

---

## 11. Join-table constraints — WRONG on production

Claim (§2.1, fifth bullet): *"on a tenant missing it (production `wh01_hydra_v2` has **neither a PK nor a unique index** on the join table — recorded in V2.2.21) it inserts **silently** and leaves two rows sharing an id."*

Measured `mywms_role_mywms_function` today:

| tenant | primary key | unique index | `V2.2.20` applied |
|---|---|---|---|
| WineCo dev | `mywms_role_mywms_function_pkey` (`p`) | yes | ✅ |
| WineCo UAT | `mywms_role_mywms_function_pkey` (`p`) | yes | ✅ |
| **Hydra PRD** | **`mywms_role_mywms_function_pkey` (`p`)** | **yes** | ✅ |
| Hydra UAT | `mywms_role_mywms_function_pk` (`p`) | yes | ✅ |
| ShipItEZ c1wh | `mywms_role_mywms_function_pk` (`p`) | yes | ✅ |
| ShipItEZ nywh | `mywms_role_mywms_function_pkey` (`p`) | yes | ✅ |

- **PRD has a real PRIMARY KEY.** `V2.2.20__authorization_join_table_primary_keys.sql` (SBDEV-3010) is applied on **all six** tenants (`flyway_schema_history` `version='2.2.20'` present everywhere), and that is the migration that created it. The plan's premise is stale — and `V2.2.21`'s comment line 20, which the plan cites as the source, was already stale when written (it copied a 2026-08-22 measurement taken before `V2.2.20` ran).
- The drifting-name half **is** right: `_pkey` on WineCo dev ✅, `_pk` on Hydra UAT ✅. But there is no longer any "none at all" shape, so the "three constraint shapes exist in this fleet" premise is now two, and the specific 42P10 argument ("column inference raises 42P10 where no constraint exists") no longer describes any live tenant.
- **Second, independent error in the same bullet — a table mix-up.** The bullet's stated consequence is *"leaves two rows sharing an **id**"*. That risk is about `mywms_function.id`, which is protected by `mywms_function_pkey` on **all six** tenants (item 8). The constraint state of `mywms_role_mywms_function` — a `(rolelist_id, functionlist_id)` join table with no `id` column at all — cannot produce or prevent a duplicate `mywms_function.id`. So the argument for "TWO separate INSERT statements" is supported by the wrong evidence.
- **What survives:** the two-separate-INSERTs instruction is still correct, for the reason the bullet gives first — a single two-row `INSERT ... SELECT` computes `MAX(id)+1` once, and on every tenant `mywms_function_pkey` then raises **23505** and aborts the file. No tenant would take it silently. And `WHERE NOT EXISTS` remains safe and re-runnable, it is just no longer the *only* universally safe guard. The plan should keep the code and replace the justification.

---

## 12. ⛔ The worst error: "no menu entry and no UI caller" — WRONG

The plan asserts this three times, and it carries the entire over-gating risk argument:
- §2.2: *"consistent with C30-C33 being an operator console with **no menu entry and no UI caller**"*
- §6.1 (Risk 1 mitigation): *"the console has **no menu entry and no UI caller**"*
- §6.4: *"the constants are deliberately **not** added to `wms2-web-ui util/appMenuList.js` — **there is no menu entry to gate**"*

All false. Measured on `wms2-web-ui` @ `origin/develop`:

**There is a menu entry.** `util/appMenuList.js:132` — the Admin menu's function list opens with `'WEB_UI_VIEW_IMPORT_DATA', // System Management`. `pages/admin.vue:26` imports `~/components/admin/systemManagement/systemManagementMain.vue` as admin tab 0 of 7.

**There are UI callers — a full button panel.** `components/admin/systemManagement/actions.vue`, five live buttons (a sixth, "Reset Process Timer", is commented out at :26-31):

| button label | line | handler | endpoint | plan status |
|---|---|---|---|---|
| "Manual Allocation / Replenishment" | :10 | `allocate` | `GET /adminAction/triggerOrderReplenish` | **C31** |
| "Manual Full Stock Update" | :16 | `updateStock` | `GET /adminAction/triggerUpdateStock` | out-of-scope sibling |
| "Archive Old Messages" | :22 | `archiveMessage` | `GET /adminAction/triggerArchiveMessages` | **C32** |
| "Test SiteBossOWL Connectivity" | :34 | `testConnectivity` | `GET /adminAction/testCrmConnectivity` | **C33** |
| "Recover Stuck Pallets" | :40 | `recoverStuckPallets` | `POST /adminAction/recoverStuckPallets` (+ `GET /listRecoverableStuckPallets`) | **C30** |

Axios calls: `store/admin/mgmt/action.js` lines 17, 27, 37, 47, 63, 74 — all six `adminAction` endpoints. There is also a Cypress suite that drives them: `cypress/e2e/wms/admin/admin.cy.js:113-115, 128, 138` ("the 4 adminAction triggers", each labelled "(gated)").

**`actions.vue` has no client-side permission check** — grep for `WEB_UI`, `permission`, `hasFunction`, `v-if` inside it returns nothing. So after this change, a user who can reach the tab but lacks the new function sees a normal, enabled button that 403s.

**Blast radius, measured (this is the number the plan needs instead):** users holding `WEB_UI_VIEW_IMPORT_DATA` (the tab's gate) who are **not** reached by `super-admin`, via the group path:

| tenant | IMPORT_DATA users | super-admin users | **IMPORT_DATA but NOT super-admin** |
|---|---|---|---|
| `dev_wh01_om1` | 37 | 37 | **0** |
| `wh01_om1_v2` | 35 | 35 | **0** |
| `wh01_hydra_v2` (PRD) | 7 | 7 | **0** |
| `wh01_hydra_v2` (UAT) | 15 | 15 | **0** |
| `wh01_shipitez_v2` | 23 | 23 | **0** |
| `wh02_shipitez_v2` | 9 | 9 | **0** |

So the plan's **conclusion** — over-gating hurts nobody today — happens to hold on all six tenants. But it holds for a completely different reason than the one given: not because the console is unreachable from the UI (it is a labelled admin tab with five buttons), but because the `WEB_UI_VIEW_IMPORT_DATA` holder set is currently *identical* to the `super-admin` set on every tenant. That is a **contingent data coincidence**, not a structural property: the moment any tenant admin grants `WEB_UI_VIEW_IMPORT_DATA` to a non-`super-admin` role, five visible buttons start 403ing with no client-side hiding and no test able to see it.

Required corrections:
1. Delete "no menu entry and no UI caller" everywhere; replace with the button/store/menu citations above.
2. Replace Risk 1's mitigation with the measured 0-of-6 delta table, stated as a coincidence that must be re-measured at deploy time, plus the standing risk if `IMPORT_DATA` is ever granted more widely.
3. §6.4's premise collapses. If the four gated buttons should stay visible only to holders, the web UI needs either the new constants in its per-button gating or an explicit decision (recorded) that the buttons stay unhidden and 403 instead. Whether that is in scope is the design lane's call — but "there is no menu entry to gate" cannot be the reason for omitting it.
4. Two of the four "out of scope" siblings (`triggerUpdateStock`, `listRecoverableStuckPallets`) are **also** driven by live UI buttons, which changes the §7 characterisation of them as an untouched operator surface.

Note also `cypress/e2e/wms/admin/admin.cy.js:150` claims "the current WMS UI has no button that calls `triggerUpdateStock` (verified via HAR 2026-07-08)" — contradicted by `actions.vue:16` + `action.js:27` on today's `origin/develop`. Pre-existing repo drift, not the plan's error, but it may be where the plan's "no UI caller" belief came from.

---

## 13. Not verified by this lane

- **AC-5's "the count moved 5846 → 5937 in a single day on 2026-09-01."** Requires running the suite; out of scope for a read-only lane. Unverified in either direction. (For calibration, in-repo comments cite 5691/5692 as of SBDEV-3017 — `Sbdev3017TrancheGateContextTest` :303, :306.)
- **`check-migration-version-collision.sh`'s exit codes for `V2.2.22`/`V2.2.23`.** Not executed (it runs `git fetch --all --prune`). The substantive answer was re-derived independently in item 7 and agrees with the plan.
- The plan's §2.1 claim that `V2.2.19` STEP 1 is "the template" — the shape does match; whether it is the *best* template is a design question.

---

## 14. Fix list, ordered by severity

1. **§2.2 / §6.1 / §6.4** — "no menu entry and no UI caller" is false. Five live buttons on the System Management admin tab (`WEB_UI_VIEW_IMPORT_DATA`) call these endpoints. Replace with the measured 0-of-6 over-gating delta and its contingency. *(item 12)*
2. **§2.1 fifth bullet** — production `wh01_hydra_v2` **has** `mywms_role_mywms_function_pkey`; `V2.2.20` is applied on all six. Also, the join table cannot cause a duplicate `mywms_function.id`. Keep the two-INSERT rule; replace the justification with `mywms_function_pkey` → 23505 on every tenant. *(item 11)*
3. **§4.2 / §4.3** — adding `AdminActionController` to `GUARDED` makes the context refuse to boot, so the pin fails to load rather than staying green. Correct the mutant's predicted outcome and stop citing the javadoc as saying the opposite of what it says. *(item 10a)*
4. **§3.2 / §7** — five other handlers, not four; `accessAudit` (:342) is `@PreAuthorize(IS_SB_ADMIN)`. *(item 4)*
5. **§2.1 first bullet** — five NOT NULL-no-default columns, not "exactly the four"; restore `V2.2.19`'s "beyond the id". *(item 8)*
6. **§3.2 first ⛔** — use 43 direct subclasses / 44 descendants, matching `AdminActionController:338` and `FunctionGuardStartupAssertion:26`. *(item 2)*
7. **Additions worth making, all measured:** `super-admin` is keyed on `mywms_role.name` and returns 0 rows on `.number`; `/v3/adminAction/**` is already matched by `SecurityConfiguration:157` at `wms_user` (the "Admin-Only" label is inert); direct `mywms_user_mywms_role` grants are 0 on all six, so the group-path count loses nobody; four `row(...)` entries is correct because nothing extends `AdminActionController`.

## 15. Score

- **Count claims: 12 of 12 correct** — 82 rows ×6, 0-of-2 ×6, 37/35/7/15/23/9, 126 total, id span 132,923→34,421,425, dev next ids, 8 `WEB_UI_ACTION_*`, line 347, line 433, 410 lines, `hasSize(123)`, `V2.2.22` taken / `V2.2.23` free. The one number that is off is "~45 controllers" (43).
- **Completeness claims: 5 errors, and every one of them is a sentence containing *no*, *only*, *exactly*, *neither*, or *four*.** The DB work behind this plan is genuinely solid; the failures are all assertions of exhaustiveness that were reasoned rather than measured — and one of them (item 12) was measurable in one `git grep` against a sibling repo.
