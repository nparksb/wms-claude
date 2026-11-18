---
title: "Scope adjustment alerts to the caller's own adjustments; new see-all function for super-admin"
ticket: "SBDEV-4002"
ticket_url: "https://app.clickup.com/t/868mrcfmg"
type: "feature"
priority: ""
status: "on dev — #615 08113d9f"
tier: T3
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-11-04"
updated: 2026-11-07
date: 2026-11-04
revision: "ralplan round 1 — revised after Architect+Critic (Critic APPROVE)"
db_verified: true
base_commit: "68a20d76 (wms2-api origin/develop, fetched 2026-11-04)"
related:
  - "[[SBDEV-4002-evidence/analysis]]"
  - "[[SBDEV-3509]]"
  - "[[SBDEV-3606-replenishment-write-endpoints-gated-by-view-function]]"
tags:
  - plan
---

# SBDEV-4002: adjustment-alert audience, per-caller scoping

**Ticket:** [SBDEV-4002](https://app.clickup.com/t/868mrcfmg). Split from SBDEV-3509 (proposals register P55).
**Evidence:** [analysis bundle](SBDEV-4002-evidence/analysis.md). The plan cites its sections as "B§n" and does not restate them. All DB figures are read-only queries from 2026-11-04.
**Shape:** one phase, one PR, wms2-api only. Web UI unchanged (B§1.6).

---

## 0. Affected sites

The sites were enumerated with one `git grep -n <literal> origin/develop` per literal; the literal list is in B§0.

**Blind spots:**
- Sites that use none of those literals.
- Other repos. The web UI was checked separately in B§1.6.
- Unpushed work.
- **Mockito-matcher inventory rails.** The B§4 guard search, which looked for `getDeclaredFields()` + `FunctionEnum`, `hasSize`, and the grant table, did not cover them. Row 35 was found in round-1 review.

**Positive control:** every literal returned at least one hit.

| # (B§0) | Site (quoted snippet) | In scope? | Covered by |
|---|---|---|---|
| 1 | `StockRecordController`: `@RequiresFunction(...WEB_UI_VIEW_STOCK_UNIT_RECORD)` / `adjustmentAlerts(` | gate: **no change**; body: unchanged | §3.4; pinned by #22 |
| 2 | same file, `stockRecordDetailsById` | no | report popup, not the poll |
| 3 | `StockrecordService`: `public Map<String, Object> getAdjustmentAlerts(long sinceEpochMillis, int limit)` | **yes** | §3.2 |
| 4 | same: `stockrecordRepository.findAdjustmentAlerts(new Date(effectiveSince), clampedLimit);` | **yes** | §3.2 |
| 5 | `StockrecordRepository`: `List<StockAdjustmentAlertView> findAdjustmentAlerts(@Param("since") Date since, @Param("limit") int limit);` | **yes** | §3.1 |
| 6–8 | `StockAdjustmentAlertView`; `ADJUSTMENT_ALERT_PAIRS`; `SYSTEM_PROPERTY_ADJUSTMENT_ALERT_POLL_ACTIVATED_KEY` | no | response shape, pair set and sysprop all unchanged |
| 9 | `WmsConstants`: `public static final class FunctionEnum {` | **yes** | §3.3 |
| 10 | `AccessService.updateFunctionList()` | no (automatic) | creates the row only |
| 11 | `UtilRestController.initDB`: `grantFunction(...)` lines | **yes** | §3.3 |
| 12–17 | V2.2.11 / V2.2.00 / V2.2.19 / V1.1.02 / `db/ref/losref*.sql` | no | templates or context only |
| 18 | `db/audit-access-invariants.sql` row 28 | no (run it) | §8 step 4 |
| 19–21 | `ReportController` exportStockUnitRecord; `SdrFunctionRules` StockrecordView; `ClientController` | no | same rows, not scoped → §1.2, §10 P-1 |
| 22 | `Sbdev3017TrancheGateContextTest`: `row("StockRecordController", "/v3/stockrecord/adjustmentAlerts", "WEB_UI_VIEW_STOCK_UNIT_RECORD");` | keep green, **do not edit** | AC-12 |
| 23–24 | `StockrecordResourceWithdrawalContextTest` AC-2 smoke; `SdrUncalledSurfaceNotExportedContextTest` comment | keep green | §7.3 |
| 25 | `StockrecordRepositoryAdjustmentAlertQueryTest`: `.getMethod("findAdjustmentAlerts", Date.class, int.class)` | **yes** | AC-11 |
| 26 | `StockrecordAdjustmentAlertDoubleToastIT`: `findAdjustmentAlerts(since, 1_000_000)` | **yes** (call shape, see-all) | §7.2 |
| 27 | `StockrecordServiceUnitTest` `class GetAdjustmentAlerts`: 14 × `findAdjustmentAlerts(any(java.util.Date.class), anyInt())` | **yes** | §7.2, AC-3…7 |
| 28 | `StockRecordControllerUnitTest` | no | covers `stockRecordDetailsById` only |
| 29 | `UtilRestControllerSeedUnitTest` | **yes** (extend) | AC-8 |
| 30 | `NameKeyedGrantSeedRailTest`: `"V2.2.42__mobile_force_scan_manual_entry.sql", 1);` | **yes** (add entry) | AC-10 |
| 31 | `ReportReadGateUnitTest`, `SdrFunctionRulesUnitTest`, `StockrecordViewHalContextTest` | no | sibling pins, untouched |
| 32–33 | `Stockrecord.operator` `@NotNull`; 8 × `setOperator(SecurityContextUtils.getUserName())` | no | writer side; identity analysis in §2.2 |
| 34 | web `plugins/adjustmentAlerts.client.js` `heldFunctions.includes('WEB_UI_VIEW_STOCK_UNIT_RECORD')` | no | contract unchanged (B§1.6) |
| 35 | `NeverMatcherNullBlindnessArchTest` inventory `"StockrecordServiceUnitTest:1",` ↔ `StockrecordServiceUnitTest` `verify(stockrecordRepository, never()).findAdjustmentAlerts(any(), anyInt());` | **yes** | §7.2 |
| new | `src/main/resources/db/migration/V2.2.46__adjustment_alert_see_all_function.sql` | **yes** (add) | §3.3 |
| new | `integration/schema/AdjustmentAlertSeeAllFunctionMigrationIT`, `integration/repository/StockrecordAdjustmentAlertOperatorScopeIT` | **yes** (add) | AC-1, 2, 9 |

## 1. Problem statement

### 1.1 What's wrong
- `GET /v3/stockrecord/adjustmentAlerts` drives the web toasts and bell. It returns every matching adjustment in the warehouse to every holder of `WEB_UI_VIEW_STOCK_UNIT_RECORD`, including other operators' adjustments and system rows (`oms_integration` DAMAGED/STOCK_CREATED).
- The SQL (B§1.3) has no actor, role or location predicate.
- Live exposure: the poll sysprop is `true` on c1wh PRD and nywh PRD (queried). c1wh produces 1–14 rows a day from 1–3 operators (P55).

### 1.2 Scope: this reduces noise; it is not a confidentiality control
- Every narrowed caller can still read every operator's stockrecords through the Stock Unit Record report: `/stockrecordView/search/*` (SDR) and `/v3/report/exportStockUnitRecord`.
- Both are gated by the same `WEB_UI_VIEW_STOCK_UNIT_RECORD` (B§0 rows 19–21).
- So this ticket changes **who gets alerted**, not who can see. Tests and reviewers must not judge it as an access boundary. See the §10 P-1 proposal candidate.

## 2. Current architecture (summary; detail in B§1–§2)

### 2.1 Request path
- Controller → service order: sysprop gate → clamp(1..200) → 24-hour floor → repo → `serverTime` → truncation, millisecond trim and `nextSince` → 12-key items (B§1.2).
- The method has **no** `@Transactional`, and neither does the class: `StockrecordService` is a plain `@Service`.
- The controller's `@AuthenticationPrincipal Principal` is unusable. It is a `JwtAuthenticationToken` whose principal is the `Jwt` (B§1.1).
- `SyspropService.getSysvalue` is `@Cacheable(value = "sysprops", …)`.

### 2.2 Identity
- The gate reads `authentication.getName()`, which is `preferred_username`, falling back to `"service-account"`.
- `stockrecord.operator` is written with `getUserName()`, which is `preferred_username`, falling back to `sub`.
- The two match for every human Keycloak login (B§2 table).
- Case sensitivity: 0 case-only mismatches on c1wh, nywh and dev. On c1wh, 95 historic rows have no exact user match (all ≤ 2024-05-10, outside the 24-hour floor).
- `operator` is NOT NULL in the database on c1wh and dev (information_schema).

### 2.3 Index and plan
- Measurement: c1wh `explain_query` with inlined literals, so a custom plan.
- Result: the same plan shape with or without the operator term (scan cost 214 → 221).
- Worst-case work for a narrowed caller is the 24-hour window: 10,330 rows on c1wh.
- The generic-plan shape was measured on 2026-11-07 (§15): an index range scan, same shape. O-1 is closed.

## 3. Design (A1)

### 3.1 Repository
- Append one predicate **before** `ORDER BY … LIMIT`, keeping one SQL text so `QueryTest` still guards the pair list (C7):
  ```sql
  AND sr.amount <> 0 
  AND (CAST(:seeAll AS boolean) OR sr."operator" = CAST(:operator AS varchar)) 
  ```
- New signature: `findAdjustmentAlerts(@Param("since") Date since, @Param("limit") int limit, @Param("seeAll") boolean seeAll, @Param("operator") String operator)`.
- `CAST(:seeAll AS boolean)` follows the existing `StockunitRepository` / `UnitloadRepository` idiom, `(… OR CAST(:includeToDelete AS BOOLEAN))`.
- `CAST(:operator AS varchar)` is house style only (`CAST(:clientId AS bigint)`). It is **not** a null-bytea guard, because `operator` is never null: the service passes the non-null caller name in both modes.
- `"operator"` stays quoted because it is a reserved word.

### 3.2 Service, `StockrecordService.getAdjustmentAlerts`
Inject `AccessService` through the constructor. There is no cycle: `AccessService`'s constructor takes only user/role/group repositories and services. Then:

| Step | Behaviour |
|---|---|
| 1 | The sysprop gate is **unchanged and still first**. When the sysprop is off there is no `SecurityContext` read and no `AccessService` call (C2). |
| 2 | Clamp and floor are unchanged. |
| 3 | `Authentication a = SecurityContextHolder.getContext().getAuthentication(); String caller = (a == null \|\| a instanceof AnonymousAuthenticationToken) ? null : a.getName();` |
| 4 | When `caller == null` **or blank** (an empty `preferred_username` is kept as `""` by the customizer; security review L1), return the empty shape `{serverTime, items: [], truncated: false}`, the same as the sysprop-off branch. No repo call and no `AccessService` call. DEBUG log `getAdjustmentAlerts: no authenticated caller — empty`. |
| 5 | `boolean seeAll = accessService.doesUserHaveAnyAccess(caller, FunctionEnum.WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS);` This is one `getAllRoles` query. Do not use `checkAnyAccess`, which adds a `findByName` probe (B§5). |
| 6 | `stockrecordRepository.findAdjustmentAlerts(new Date(effectiveSince), clampedLimit, seeAll, caller)`. Everything after this call is untouched. |

- **Why the anonymous check:** `anonymous()` is not disabled, so a request with no JWT arrives as `anonymousUser`, not null (`UserController`: "`anonymous()` is not disabled … `AnonymousAuthenticationToken`"). Without the check, a narrowed `anonymousUser` would be matched against real `operator='anonymousUser'` rows (149 on dev, none in the alert pairs today).
- **Why there is no `isAuthenticated()` check:** `SecurityConfiguration` `.requestMatchers("/v3/**", …).hasAnyAuthority(Authority.WMS_USER_ROLE)` runs before the controller, so an unauthenticated token never reaches the service on this route. `IdempotencyFilter` (`auth == null || auth instanceof AnonymousAuthenticationToken || !auth.isAuthenticated()`) needs the third clause only because it is a filter that runs ahead of that check.
- Never use `getUserName()` or `getAuthorizedName()` (B§2). The second falls back to `ANONYMOUS`, which is a real `mywms_user` on Hydra UAT.
- **Seam choice (A1 over A5):** see §9 A5 and the ADR. `AccessService` still receives the caller by value.

### 3.3 Function, seed and fresh-database grant ("three things", B§3)

| Item | Change |
|---|---|
| Constant | `public static final String WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS = "WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS";` in `FunctionEnum`. The value equals the name. `VIEW_` widens what a view reads; it is a data scope, not a page. |
| Flyway `V2.2.46__adjustment_alert_see_all_function.sql` | STEP 1: the V2.2.19 function-row template (`COALESCE(MAX(id),0)+1`, 8 columns, `WHERE NOT EXISTS`). STEP 2: the V2.2.42 grant shape (V2.2.21's `WHERE NOT EXISTS` form with the role list as an `IN`), written as **`WHERE r.name IN ('super-admin')`** with `AND NOT EXISTS (…)`; the function is selected by `f.function`, the UNIQUE column STEP 1 guards on (review L4). **Never `ON CONFLICT`** (B§3.3). The header comment must say the "no test executes SQL" note in V2.2.19 is out of date and name AC-9. |
| `initDB` | `grantFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS, role_super_admin);` |
| `NameKeyedGrantSeedRailTest` | `"V2.2.46__adjustment_alert_see_all_function.sql", 1` with a reviewed-rationale comment: keyed by name so the parity test can parse it; role renaming was closed in SBDEV-3545. |

- `V2.2.46` is the next free version (B§3.2).
- **Re-check `ls src/main/resources/db/migration | sort -V | tail -1` immediately before commit.**

### 3.4 Route gate and recorded convention exception
- `@RequiresFunction(WEB_UI_VIEW_STOCK_UNIT_RECORD)` is **unchanged** (C5).
- The new function never gates a route; it widens the row set inside one.
- This deliberately overrides the SBDEV-3017 §9.16 Option B convention, as SBDEV-3606 did (§10 R-5). Record it in role-matrix §3.3 the same way the 3606 row is recorded.

## 4. File change summary (wms2-api, `src/…/net/aim_ai/wms/`)

| File | Type | Change |
|---|---|---|
| `repo/jpa/StockrecordRepository.java` | M | predicate + 2 parameters (§3.1) |
| `service/StockrecordService.java` | M | `AccessService` injection; steps 3–5 (§3.2); javadoc gains an "Audience" paragraph |
| `service/WmsConstants.java` | M | new `FunctionEnum` constant |
| `controller/rest/UtilRestController.java` | M | one `grantFunction` line |
| `resources/db/migration/V2.2.46__adjustment_alert_see_all_function.sql` | A | §3.3 |
| tests: `StockrecordServiceUnitTest`, `StockrecordRepositoryAdjustmentAlertQueryTest`, `StockrecordAdjustmentAlertDoubleToastIT`, `UtilRestControllerSeedUnitTest`, `NameKeyedGrantSeedRailTest`, `NeverMatcherNullBlindnessArchTest` | M | §7 |
| tests: `StockrecordAdjustmentAlertOperatorScopeIT`, `AdjustmentAlertSeeAllFunctionMigrationIT` | A | §7 |

## 5. Implementation plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | Flyway head 2.2.45 on dev, c1wh and nywh (queried). Role `super-admin` present on dev, c1wh and nywh (1 row each). | — | Other 4 tenants unqueried → §10 O-2; §8 step 3 closes it |
| 2 | Flags / sysprops | None new. `ADJUSTMENT_ALERT_POLL_ACTIVATED` stays as is: true on dev, c1wh PRD and nywh PRD. | — | Scoping only runs when the sysprop is on |
| 3 | Config / env | N/A: no property, Keycloak client or env change. | — | |
| 4 | Deploy order | N/A: the web UI contract is unchanged (B§1.6). | — | |
| 5 | Data migration | V2.2.46 runs automatically per tenant. No backfill. | — | |
| 6 | External systems | N/A: no OMS or printer path. | — | |
| 7 | Access | The new `FunctionEnum` constant granted to `super-admin` only (V2.2.46 + `initDB`). No Keycloak change. | executor | §3.3 |
| 8 | Monitoring | N/A (§7.5 row 5). | — | |
| 9 | **Manual-test credential** | A Keycloak login for a DEV user who holds `WEB_UI_VIEW_STOCK_UNIT_RECORD` without `super-admin` (`truckloading` or `danielvalentim`). The dev-probe kit holds `panderson` only. | **Nam** | Blocks only the §7.4 narrowed scenario. Not the TDD gate or the PR: AC-1, 2, 4 and 5 prove narrowing. |

### 5.2 Phase 1, the only phase

- **Branch:** `feature/SBDEV-4002-adjustment-alert-audience` off freshly fetched `origin/develop`.
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-4002`. Claim the ticket lease first.
- **Merge target:** `develop` only.
- **Risk:** medium.
- **Effort:** about ½ day plus review.

**Gate mechanics.** The `wms-tdd-gate` skill says "A test that fails to compile is not a failing test — it is broken scaffolding". It also requires every test to fail "for the right reason (assertion failures)". So the work splits by what compiles against develop today.

1. **TDD gate (tests that compile on develop today; each red at an assertion):**

   | AC | Why it compiles and reds at an assertion |
   |---|---|
   | AC-8 | Refer to the function by its string literal and reflection, following the RTS precedent in `UtilRestControllerSeedUnitTest` (`getDeclaredField(RTS_DESTINATION)`). Assert presence as `assertThat(fieldNames(FunctionEnum.class)).contains(NEW)` so it reds at an assertion, not with `NoSuchFieldException`. |
   | AC-9 | Migration IT, SQL only. |
   | AC-10 | Rail entry. Confirm at the gate that a file-less entry reds at an assertion. |
   | AC-11 | Rewritten so it does not use `getMethod`: `NoSuchMethodException` is not a right-reason red. Scan `getDeclaredMethods()` by name "findAdjustmentAlerts", assert exactly one with parameter types `[Date, int, boolean, String]`, then the SQL substring. |

   AC-12 is a green guard. Then pause for approval.

2. **Executor commit 1, inert scaffold (no behaviour change; full build green):**
   - Add the 4-arg signature. Its SQL references both parameters inertly: `AND (CAST(:seeAll AS boolean) OR TRUE OR CAST(:operator AS varchar) IS NULL)`. Spring Data rejects an `@Param` the query does not use (MEDIUM confidence; verify on the first build).
   - Add the constant and the `AccessService` injection.
   - The service passes `seeAll=true` and the operator `caller` (or `""` when there is no caller).
   - Apply the §7.2 call-shape and setup changes in the same commit.
   - AC-8, 9 and 10 can go green here (constant, migration, `initDB`, rail), or in commit 2. AC-11 stays red until commit 2.

3. **Write AC-1…7 against the scaffold.** Show each one red at its assertion before the behaviour commit:

   | AC | Red on the scaffold because |
   |---|---|
   | AC-1, 2a, 2b | see-all is forced on |
   | AC-3 | no `AccessService` call happens |
   | AC-4 | `seeAll` is `true` |
   | AC-5 | the repository is called |

   **AC-6 and AC-7 are green guards by construction** (the scaffold neither calls access nor changes keys). They are proven by mutation after commit 2: move the access check above the gate; add or rename a key.

4. **Commit 2, behaviour:** the real predicate (§3.1) and service steps 3–5 (§3.2). Everything is green. Mutation-check every new assertion against the mutant named in §7.1.

5. **Sibling sweep:**
   - `git grep -n "Date.class, int.class"`.
   - `git grep -nE '\b86\b' src/test` for function-count literals.
   - `git grep -n "never()).findAdjustmentAlerts"`.
   - Run the docs sweep in §8 step 5.

6. **Baseline and review:**
   - Run a full `mvn verify` on a **detached `origin/develop` worktree at the branch's base commit**, then on the branch, and compare the **failure sets**.
   - Before calling a red new, check the known-flaky-IT hub.
   - Then code review (fix every finding, including Low), the verifier lane, and a PR into `develop`.

## 6. Backward compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| Response JSON (`serverTime, items, truncated, nextSince?`, 12 item keys) | — | identical | none (AC-7) |
| Row set for a holder of the new function | all matching rows | all matching rows | none |
| Row set for everyone else | all matching rows | only `operator = caller` | intended narrowing |
| `truncated` / `nextSince` | computed over all rows | computed over the caller's own rows | correct per-caller cursor; no leak (AC-2) |
| Sysprop off | empty, no DB | empty, no DB, no access check | none (AC-6) |
| No or anonymous authentication | n/a (route gate denies) | empty in the service as well | defence in depth |
| Repository method signature | `(Date, int)` | `(Date, int, boolean, String)` | internal only; test callers updated |
| Schema | — | +1 `mywms_function` row, +1 grant per tenant that has `super-admin` | additive |

**What does NOT change:**
- the route path and its `@RequiresFunction`
- the sysprop key and its semantics
- the `ADJUSTMENT_ALERT_PAIRS` and SQL pair clauses
- the 24-hour floor, clamp and millisecond-trim logic
- the projection
- the web UI
- the Stock Unit Record report, SDR search and export, which stay unscoped (§1.2)
- other roles' grants
- Keycloak

**Effect per tenant** (users holding `WEB_UI_VIEW_STOCK_UNIT_RECORD`, from the B§5 queries):

| Tenant | Holders | See all (via `super-admin`) | Narrowed |
|---|---|---|---|
| c1wh PRD | 26 | 23, incl. `rfernandez`, `jfernandez`, `bcampbell` | **3** inventory-manager-only users, incl. `cloverdale-qa1` (a live alert operator) |
| nywh PRD | 9 | 9 | **0**: no visible change |
| dev `dev_wh01_om1` | 45 | 38 | **7**: `danielvalentim`, `daniilandriyenko`, `jovanyaguilera`, `markchilcote`, `truckloading`, `ursulajimenez`, `Z-mariaortiz(archived)` |
| other 4 tenants | unqueried | — | §8 step 3 |

System rows (`oms_integration`, 8 on c1wh between 2026-09-23 and 2026-10-15) now reach see-all holders only (R-2).

## 7. Testing strategy

### 7.1 Acceptance criteria → tests → mutant killed

| AC | Test class (new = N) | Asserts | Kills |
|---|---|---|---|
| 1 | N `integration/repository/StockrecordAdjustmentAlertOperatorScopeIT` (`BasePostgresIntegrationTest`), repository level | Seed matched rows for `alice`, `bob` and `oms_integration`, plus 1 `alice` row **inside the since window that fails the pair predicate** (`activitycode='PACKAGING'`). Narrowed `alice` → only her matched row. See-all as `carol` (who matches no seeded operator) → exactly the 3 matched rows. | predicate dropped; `OR` written as `AND`; wrong column |
| 2a | same class, **service level**: calls `StockrecordService.getAdjustmentAlerts` | `alice` has 1 row; `bob` has `limit+1` rows. Narrowed `alice` → `truncated=false`, no `nextSince`, items == exactly her id. | **option C** (Java filter after truncation): leaks bob's burst through `truncated` / `nextSince` |
| 2b | same, service level | `alice` has more than `limit` rows with distinct milliseconds, interleaved with `bob`'s. Loop the way the client does: use `nextSince` when truncated, else stop. The deduped union of ids equals her full set, and no `bob` id appears on any page. Ids are served at least once; re-serving is by design. | **option B** (Java filter before truncation): her rows past the first page are never served |
| 2c | same, service level (added in review, L7) | The base dump's `admin` (group `super-admin` → role `super-admin` → V2.2.46 grant), resolved by the REAL `AccessService`/`getAllRoles` join, polls in see-all mode → all 3 seeded ids (alice, bob, system). A precondition query proves the join first. | a broken see-all path through the real role join (only mocked in AC-3) |
| 3 | `StockrecordServiceUnitTest` | Holder → repo called with `seeAll=true`. The `doesUserHaveAnyAccess` captor asserts arg 0 `== getName()` and that the walked varargs are exactly `[WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS]`. | hard-coded `false`; wrong constant; wrong identity passed to the check |
| 4 | same | Non-holder → `seeAll=false`, `operator == getName()`. Tokens built as `JwtAccessTokenCustomizer.convert` builds them, `new JwtAuthenticationToken(jwt, authorities, name)`. (i) `preferred_username` set. (ii) **no `preferred_username`**: name `"service-account"`, `sub` a UUID. Only (ii) kills the `getUserName()` mutant. | `getUserName()` used |
| 5 | same | `authentication == null`, **and** an `AnonymousAuthenticationToken` → empty items, `truncated=false`, `verifyNoInteractions(stockrecordRepository, accessService)`. | null or anonymous fallback (`getAuthorizedName()` → `ANONYMOUS`); null read as "all"; anonymous check dropped |
| 6 | same (extends the sysprop-off test) | With an authenticated context installed (once as a holder, once as a non-holder) and the sysprop off → `verifyNoInteractions(accessService)`. | access check moved above the gate |
| 7 | same | In both modes: response keys `== {serverTime, items, truncated}` (`+ nextSince` when truncated); each item's keys `== {id, created, clientNumber, clientName, sku, location, amountChange, amountAfter, operator, activityCode, type, reason}`. These are **literal** sets, not compared between modes. | key added, renamed or dropped |
| 8 | `UtilRestControllerSeedUnitTest` | (a) the constant is declared (by literal) with value equal to its name; (b) `initDB` grants exactly `{super-admin}`, with a sibling function as positive control; (c) exactly one migration seeds the literal, it starts `V2.2.46__`, and its `r.name IN` set equals `initDB`'s | missing `initDB` line; extra role; silent renumber |
| 9 | N `integration/schema/AdjustmentAlertSeeAllFunctionMigrationIT` (shaped like `ManualEntryOverrideMigrationIT`) | Target 2.2.45 → no row. Then 2.2.46 → 1 row with `name=number=function`, `version=0`, `client_id=0`, granted to exactly `{super-admin}`. Re-running adds 0 rows. | `ON CONFLICT`; 2-column insert; extra role; missing `NOT EXISTS` |
| 10 | `NameKeyedGrantSeedRailTest` | V2.2.46 entry, count 1 | rail |
| 11 | `StockrecordRepositoryAdjustmentAlertQueryTest` | The declared-methods scan finds exactly one `findAdjustmentAlerts(Date, int, boolean, String)`. Pair-set equality still holds. The SQL contains the exact substring `(CAST(:seeAll AS boolean) OR sr."operator" = CAST(:operator AS varchar))`, and its `indexOf` is `< indexOf("ORDER BY")`. | pair drift; predicate removed or altered; predicate moved after `ORDER BY` / `LIMIT` |
| 12 | `Sbdev3017TrancheGateContextTest` (**no edit**) | Route still gated only by `WEB_UI_VIEW_STOCK_UNIT_RECORD`; `hasSize(234)` unchanged | route gated on the new function |

**Notes:**
- The B and C kills in AC-2 are **design substitutions**: an alternative implementation, not a one-token mutant. AC-1 owns the dropped-predicate mutant.
- **AC-2 setup:**
  - `@MockitoBean SyspropService` returns `"true"` for the poll key. A mock is chosen over seeding plus cache eviction because `getSysvalue` is `@Cacheable("sysprops")` and V2.2.11 seeds `'false'`. A mock removes both the seed and the cross-test cache state. Precedent: `MessageServiceCallerTxIT` `@MockitoBean private SyspropService syspropService;`.
  - `SecurityContext` holds `alice`, and `alice` has **no** roles, so the real `AccessService` returns `false`.
  - Seeds use **explicit, distinct, increasing `created`**. `BasePostgresIntegrationTest` is `@Transactional("tenantTransactionManager")`, so `now()` is constant and every row would otherwise share one millisecond.
  - Clear the context in `@AfterEach`.

### 7.2 Existing tests changed by design (scaffold commit; setup and call shape only, never weakening)

| Test | Change |
|---|---|
| `QueryTest` | Becomes AC-11 (declared-methods scan; no `getMethod`). |
| `DoubleToastIT` | `findAdjustmentAlerts(since, 1_000_000, true, "sbdev3382")`: see-all mode keeps its original intent. |
| `StockrecordServiceUnitTest` `class GetAdjustmentAlerts` | **Setup:** `@Mock AccessService` (with `@InjectMocks`, an unmocked argument arrives null and NPEs). A nested `@BeforeEach` installs an authenticated token built as the customizer builds it, `new JwtAuthenticationToken(jwt, authorities, name)`. `@AfterEach SecurityContextHolder.clearContext()`. Unstubbed `doesUserHaveAnyAccess` returns `false`, so existing cases run narrowed, which they don't observe. The 14 stubs and verifies widen to `findAdjustmentAlerts(any(), anyInt(), anyBoolean(), any())`. |
| same, `never()` site | Replace `verify(stockrecordRepository, never()).findAdjustmentAlerts(any(), anyInt());` with `verifyNoInteractions(stockrecordRepository)`, consistent with AC-5 and AC-6. |
| `NeverMatcherNullBlindnessArchTest` | Remove the inventory entry `"StockrecordServiceUnitTest:1",` because the count goes 1 → 0. **Rule:** never `anyString()` inside `never()`; wherever matchers are needed, the operator position is a bare `any()`. |
| `NameKeyedGrantSeedRailTest` | AC-10. |

### 7.3 Must stay green, not edited
`StockrecordResourceWithdrawalContextTest`, `FunctionGuardArchTest`, `SdrRuleStartupAssertion`, `ActionGuardAnnotationContractUnitTest`, `ReportReadGateUnitTest`, `SdrFunctionRulesUnitTest`, `Sbdev3017TrancheGateContextTest`.

### 7.4 Manual test plan (DEV `dev_wh01_om1` via `wms2-wineco-dev`; wms-dev-probe; snapshot and restore proof)

| Scenario | Env | Precondition query → dev count (2026-11-04) | Steps | Expected | P/F |
|---|---|---|---|---|---|
| Migration applied | dev DB | `SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1` → `2.2.45` | after deploy, re-run | `2.2.46`, success | |
| Grant correct | dev DB | `SELECT count(*) FROM mywms_role WHERE name='super-admin'` → 1 | `SELECT r.name FROM mywms_role r JOIN mywms_role_mywms_function x ON x.rolelist_id=r.id JOIN mywms_function f ON f.id=x.functionlist_id WHERE f.name='WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS'` | exactly `super-admin` | |
| See-all poll | dev | alert-pair rows inside the 24-hour floor → **0**, so seed: 1 adjustment as `panderson`, 1 as `truckloading`, 1 `oms_integration` DAMAGED/STOCK_CREATED via the dev-probe seed | poll as `panderson` | all 3 seeded ids | |
| Narrowed poll | dev | holders of the view function without super-admin → 7 | poll as `truckloading` (**needs §5.1 #9**) | only its own id; `truncated:false` | |
| Contract | dev | — | diff the key sets of the two responses | identical | |
| UI smoke | dev web | sysprop `true` (queried) | log in as `panderson`, adjust; then as the narrowed user | panderson gets the toast; narrowed user gets no toast for others' rows | |
| Restore | dev DB | snapshot before seeding | `snapshot.sh` diff | seeded rows removed; diff empty | |

### 7.5 v2 constraint checklist

| # | Constraint | Verdict | Rationale |
|---|---|---|---|
| 1 | OSIV disabled | No | Projection plus `List<String>`; no lazy associations |
| 2 | Tenant transaction manager | N/A | No writes; both reads are tenant-routed repositories. `AccessService`'s javadoc warns that a bare `@Transactional` would bind to the landlord transaction manager. |
| 3 | `readOnly=true` | No (deliberate) | The method has no `@Transactional` on develop. Two single-statement auto-commit reads; adding a transaction widens the diff and gains nothing. |
| 4 | Caffeine invalidation | N/A | No cached entity is written; `getAllRoles` is uncached, the same path as the gate. |
| 5 | Micrometer | No | A per-user poll is not a business hot path. The DEBUG log covers the no-caller branch. |
| 6 | Jakarta | N/A | Nothing ported from v1 |
| 7 | H2 SQL | N/A | The native query is exercised only by Testcontainers ITs (AC-1, 2, 9); `QueryTest` reads the text and doesn't execute it |
| 8 | Controller test | No | The endpoint signature and gate are unchanged (AC-12 + MVC smoke); the behaviour is in the service (AC-2…7). |

### 7.6 Horizontal scalability

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | stateless |
| 2 | Pool math | No | +1 short query per poll; no connection held across calls |
| 3 | Scheduled jobs | No | — |
| 4 | Long transactions | No | no transaction |
| 5 | Request affinity | No | the cursor is client-held |
| 6 | Retry / idempotency | No | read-only. The migration is idempotent through `NOT EXISTS` (AC-9). |
| 7 | Tenant context | No | request thread only; no async |
| 8 | Distributed locks | No | — |
| 9 | Cache invalidation | No | nothing cached |
| 10 | External notifications | No | — |

### 7.7 Verify script: opted out
Every invariant here is visible to a test that runs in CI:
- SQL text: AC-11
- migration: AC-9
- seed parity: AC-8, AC-10
- route gate: AC-12
- cursor: AC-2

No cross-file invariant needs a grep row.

## 8. Rollout

1. PR into `develop` only. Release and main are DevOps.
2. Dev deploy → run the §7.4 table.
3. **Post-deploy query on EVERY tenant:** dev, c1wh PRD, nywh PRD, Hydra PRD/UAT, ShipItEz UAT and WSL UAT.
   - Run the §7.4 grant query; expect `super-admin`.
   - **Also record `max(mywms_function.id)` against `seqentities.last_value`.** The `max+1` id must stay below the sequence so a later `nextval` seed can't collide (B§3.3; c1wh: 122,348,918 < 122,380,159).
   - **Zero grant rows** means no `super-admin` role. That fails closed: everyone is narrowed. Report it and don't hand-patch.
4. Run `db/audit-access-invariants.sql`: its "what the deploy GRANTS" check and **SET 11**, per tenant.
5. Doc updates (`sbdocs` is not in git):

   | Doc | Change |
   |---|---|
   | `data-dictionary/wms2-sysprop-catalog.md` | Add the audience rule to `ADJUSTMENT_ALERT_POLL_ACTIVATED`. **Fix the drift**: it says "`true` on DEV only", but the sysprop is also true on c1wh and nywh PRD. |
   | `architecture/wms2-keycloak-role-matrix.md` | §3.3 row with the Option-B exception noted as for 3606; §3.9.3 reverse-gap entry: "data scope, not a page"; §4 super-admin persona |
   | `architecture/wms2-function-to-docs-map.md` | `StockRecordController` / `StockrecordService` line: `adjustmentAlerts` and its audience |
   | `design/wms2-rest-api-reference.md` | **N/A (corrected 2026-11-04 after conformance review)**: that doc's scope is `net.aim_ai.wms.controller.rest` (`/rest/**`, OMS-facing). The alert poll is a `/v3` web route, so it is documented in the role matrix, function-to-docs map and sysprop catalog instead |
   | `2-Areas/proposals-register.md` | P55 status: plan pending approval |
   | sweep | `grep -rnE '86 (functions\|constants)\|8[0-9] grants' sbdocs/3-Resources`; bump any hit |

6. **Rollback:**
   - **Revert the Java only. KEEP `V2.2.46` in the tree**; its row and grant are inert once no code reads the constant.
   - Never delete the file after it has been applied, and **never reuse version 2.2.46**.
   - `StartupFlywayMigrator` runs with `validateOnMigrate` and the default `ignoreMigrationPatterns` `*:future`. `*:future` doesn't cover an applied migration that is missing locally, so deleting the file would likely fail validation per tenant. That conclusion comes from the class javadoc and is partly unverified for the "missing" case. Remove the row later with a new, higher migration only if asked.

## 9. Alternatives considered

| # | Option | Why rejected |
|---|---|---|
| A2 | Two `@Query` methods (scoped and see-all) | Duplicates the pair list; `QueryTest` guards one method, so the copies drift |
| A3 | Filter in Java (before or after truncation) | Before: breaks the cursor, so the caller's later rows are never served. After: correct but leaks others' bursts through `truncated` / `nextSince` and loads up to 200 foreign rows per poll (B§1.4). AC-2 kills both. |
| A4 | One nullable operator parameter, null meaning "all" | Fails open |
| A5 | **Synthesis:** the controller resolves the caller from `SecurityContextHolder` and passes it to the service by value; the service computes `seeAll` | **Viable; not chosen.** For: it mirrors `AccessService`'s by-value design ("keeps a ThreadLocal out of the check … a test can state 'this user, these functions' without installing a security context"), and the service unit tests would need no `SecurityContext` setup (§7.2). Against: the null/anonymous fail-closed rule would sit at each caller instead of inside the service, so a future second caller (job, async, another route) could pass a borrowed or `ANONYMOUS` name; the RTS precedent (`RtsDestinationValidator`) resolves in the service; the controller unit test has no guard harness. `AccessService` still receives the caller by value under A1, so its design is kept. |
| A6 | Reuse `WEB_UI_ACTION_ADJUST_AMOUNT` | Nam rejected it (R-4). Measured useless: the same 26 holders on c1wh, diff 0, control 3. |
| A7 | `lower(operator)` match to use the operator index | Diverges from the gate; 0 case-only mismatches; `created` is the right driving index |

## 10. Decisions, open items, proposals

### Resolved (Nam, 2026-11-04; do not reopen)

| # | Decision |
|---|---|
| R-1 | Audience: a caller sees only rows where `stockrecord."operator"` equals the caller. Holders of `WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS` see all. |
| R-2 | System-generated adjustments (e.g. `oms_integration` DAMAGED/STOCK_CREATED) follow the same rule. |
| R-3 | V2.2.46 grants to `super-admin` **only**, written `r.name IN ('super-admin')`, plus the `initDB` `grantFunction` line. |
| R-4 | Reusing `WEB_UI_ACTION_ADJUST_AMOUNT` is rejected (A6). |
| R-5 | This overrides the Option-B convention for a data-scope function. Recorded as an exception like SBDEV-3606. |

### Open, not blocking the TDD gate

| # | Item | Closed by | Why it doesn't block |
|---|---|---|---|
| O-1 ✅ closed 2026-11-07 (§15) | Generic-plan shape of `(CAST(:seeAll…) OR …)` under pgjdbc server-side prepare is unmeasured; the MCP refuses `EXPLAIN ANALYZE` | Executor after the dev deploy: `EXPLAIN (GENERIC_PLAN)` if the server is PG ≥ 16, else `pg_stat_statements` mean_exec_time before and after, recorded in §11 | It affects performance, not correctness. The 24-hour floor bounds the worst case (~10k rows on c1wh) whatever plan is chosen. |
| O-2 | `super-admin` existence on Hydra PRD/UAT, ShipItEz UAT, WSL UAT | §8 step 3 | A missing role fails closed. The base dump V2.2.00 carries the role. |
| O-3 ✅ closed 2026-11-04 (§14, grant toggle) | DEV credential for a narrowed user | Nam (§5.1 #9) | Manual test only; AC-1, 2, 4 and 5 prove narrowing. |
| O-4 ✅ closed 2026-11-04 (first build of commit 1 compiled and the full suite passed, §12) | Spring Data's handling of an unused `@Param` in the scaffold commit (MEDIUM confidence) | Executor, first build of commit 1 | The scaffold SQL references both parameters anyway. |

### Proposal candidate (PROPOSED, not filed; per ticket policy a T3 authz finding is proposed and Nam confirms)
**P-1: the Stock Unit Record report is unscoped by operator.**
- **Evidence:** `/stockrecordView/search/*` (`SdrFunctionRules` StockrecordView) and `/v3/report/exportStockUnitRecord` (`ReportController`) return every operator's stockrecords to every holder of `WEB_UI_VIEW_STOCK_UNIT_RECORD` (B§0 rows 19–21).
- **Blast radius:** 26 / 9 / 45 users on c1wh / nywh / dev.
- **Cost:** T3. It would gate 3 read surfaces and change supervisors' reporting.
- **Recommendation: do not file under the current intent.** R-1 is about alert noise, and a report showing all adjustments is that screen's purpose. Raise it only if Nam intends adjustment activity to be confidential per operator.

## Layer-2 completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | All callsites enumerated | ✓ §0: every B§0 row plus row 35 and the 2 new files; Mockito-rail blind spot named |
| 2 | Adjacent shapes | ✓ §1.2 / P-1; §5.2 step 5 sibling sweep |
| 3 | Backward compatibility | ✓ §6 table + "What does NOT change" + per-tenant table |
| 4 | Concurrency | ✓ read-only; the cursor per caller is AC-2; the migration is idempotent (AC-9) |
| 5 | Multi-tenant | ✓ §7.6; §8 step 3 queries every tenant |
| 6 | Error handling | ✓ no new throw path; no-caller returns the empty shape (§3.2 step 4) |
| 7 | DB verified | ✓ §2, §6, §7.4 counts; frontmatter `db_verified: true` |
| 7b | Observability | ✓ DEBUG log on the no-caller branch; no metric (§7.5 row 5) |
| 8 | Rollout / migration | ✓ §3.3, §8 including the version-keeping rollback |
| 9 | Test coverage | ✓ §7.1 (AC-1…12, mutants), §5.2 gate mechanics, §7.4 manual |
| 10 | Cross-version | no — v1 is reference-only (no client on v1 since 2026-10-02) |
| 11 | Alternatives | ✓ §9 (A2–A7) |

## ADR

- **Decision:** scope the alert poll in SQL with `(CAST(:seeAll AS boolean) OR sr."operator" = CAST(:operator AS varchar))` before `LIMIT`. `seeAll` comes from the new `WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS`, granted to `super-admin` only. **The service** resolves the caller as `authentication.getName()`, fails closed on null or anonymous, and passes the caller to `AccessService` by value.
- **Drivers:** cursor correctness with no leak through `truncated` / `nextSince`; one SQL text guarded by `QueryTest`; identity that matches the route gate; fail-closed for every caller.
- **Alternatives considered:** A2–A7 (§9).
- **Why chosen:**
  - It is the only option that is correct, leak-free and fail-closed with an unchanged contract.
  - Resolving the caller in the service (A1) beats the A5 synthesis because the fail-closed rule lives in one place for any future caller, and it follows the RTS precedent.
  - The Architect judged either acceptable.
- **Consequences:**
  - On c1wh, 3 users lose others' alerts; on dev, 7.
  - **Tension accepted:** every poll makes **2 uncached `getAllRoles` queries** (route gate and see-all check), per open browser tab. The alert SQL's generic plan is shared between see-all and narrowed callers (O-1).
  - The service now reads `SecurityContextHolder`, so its unit tests install a context (§7.2). `AccessService` stays by-value.
  - The route keeps its screen gate while a second function scopes the rows: a recorded Option-B exception.
  - Not a confidentiality control (§1.2).
- **Follow-ups:** O-1, O-2 and O-4; P-1 if Nam asks; doc updates per §8 step 5. If the role-query cost shows up, request-scope the `getAllRoles` result as a separate ticket.

## 11. TDD gate baseline (2026-11-04)

- **Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-4002`, branch `feature/SBDEV-4002-adjustment-alert-audience`, base `68a20d76` (origin/develop, fetched 2026-11-04). Lease claimed by tdd-gate. Gate tests are **uncommitted** in the worktree.
- **Gate scope per §5.2:** AC-8, AC-9, AC-10 and AC-11. AC-12 is a green guard (untouched). AC-1…7 are written by the executor after the scaffold commit.

| AC | Test | Red at (assertion message, abbreviated) |
|---|---|---|
| 8a | `UtilRestControllerSeedUnitTest.declaresTheSeeAllAdjustmentAlertsConstant` | `FunctionEnum.WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS does not exist` |
| 8b | `…initDB_shouldGrantSeeAllAdjustmentAlertsToExactlySuperAdmin` | `initDB must grant … to exactly {super-admin}` (the control, manual-entry grants, is non-empty) |
| 8c | `…seeAllAdjustmentAlertsMigrationAndInitDB_shouldGrantTheSameRoleNameSet` | `exactly one db/migration script must seed … found none or several` |
| 9 | `AdjustmentAlertSeeAllFunctionMigrationIT.seeAllFunctionSeed_shouldGrantExactlySuperAdmin_andSecondApplyShouldBeANoOp` | `no V2.2.46__*.sql migration exists`. It reached this assertion after the 2.2.45 absence check and the 2-role positive control both passed. |
| 10 | `NameKeyedGrantSeedRailTest.everyNameKeyedSeedIsAllowListedAtItsExactCount` | allow-list mismatch (V2.2.46 entry pinned, file absent) |
| 11 | `StockrecordRepositoryAdjustmentAlertQueryTest.findAdjustmentAlerts_shouldScopeByOperatorBeforeLimit_whenDeclared` | `must declare exactly one findAdjustmentAlerts(Date, int, boolean, String) — found [[Date, int]]` |

- **Run counts:**
  - Surefire, three classes, comma-separated: `Tests run: 32, Failures: 5, Errors: 0`. The 27 tests that already existed stay green, including the 2 pair tests whose lookup moved to a by-name scan so they survive the signature change.
  - Failsafe: `Tests run: 1, Failures: 1`. Report files were written in both lanes.
- **Verify script:** none (§7.7 opt-out).
- **Mutation checks are owed after implementation** (§5.2 step 4). Specifically: AC-11's "before ORDER BY" (move the predicate after `ORDER BY`), AC-8c (add `'inventory-manager'` to the `IN` list), AC-9 (`ON CONFLICT` form; drop `NOT EXISTS`), AC-10 (count 2).

## 12. Implementation status (2026-11-04)

- **PR:** [SiteBossInc/wms2-api#615](https://github.com/SiteBossInc/wms2-api/pull/615) into `develop`, branch `feature/SBDEV-4002-adjustment-alert-audience`. Not merged.
- **Commits:**

  | SHA | What |
  |---|---|
  | `e53c6b68` | inert scaffold + gate tests |
  | `f710f3d4` | behaviour + AC-1…7 |
  | `4ee46d23` | review fixes: 1 Medium, 8 Low |
  | `1cbfecab` | re-review Low |

- **Tests:**
  - Full `mvn clean verify -Pci` at `4ee46d23` (private container): 9685/0 unit, 1194/0 IT.
  - Baseline at `68a20d76`: 9676/0 unit; IT 1189 with 17 failures in 3 classes, caused by the reused container's `seqentities` (19/0 on a fresh container).
  - Verifier at `1cbfecab`: 94/0 unit, 7/0 IT on the touched classes.
- **Test-first order:**
  - AC-3…5 and AC-8…11 failed at assertions before the code that satisfies them.
  - AC-1/2a/2b were committed with the behaviour, then shown red against the scaffold's repository and service (3/4 red; AC-2c is green there by design).
  - AC-6/7 are guards.
- **Mutation:**
  - PIT on `StockrecordService`: every mutant in the new lines was killed. The 2 survivors are on a pre-existing WARN-log condition.
  - Hand mutants, all killed by the intended assertion: predicate `OR`→`AND`, predicate dropped, predicate after `ORDER BY`, `+inventory-manager` grant, STEP 2 `NOT EXISTS` dropped, rail count 2, access check via `getUserName()`, blank-caller check dropped.
- **Reviews:**
  - code review @`f710f3d4`: 1 Medium + 7 Low, all fixed;
  - security @`f710f3d4`: APPROVE, 1 Low fixed;
  - scoped @`4ee46d23`: APPROVE, 1 new Low fixed;
  - scoped @`1cbfecab`: APPROVE, no findings;
  - conformance verifier @`1cbfecab`: code matches every §0 row and AC-1…12; 3 doc gaps closed in this plan (§3.2 step 4 blank caller, AC-2c row, §8 REST-reference row → N/A).
- **Landmines found during implementation:**
  - **Flyway version collision with a peer session's unpushed work.** SBDEV-4007 also claimed `V2.2.46`. `check-migration-version-collision.sh` scans remote branches only, so it reported "FREE". Nam decided SBDEV-4007 moves to V2.2.47. The peer's ITs had applied its V2.2.46 into the shared Testcontainers DB, so every reuse-mode IT failed with a 2.2.46 checksum mismatch. **Workaround:** `TESTCONTAINERS_REUSE_ENABLE=false` gives each run a private container.
  - `seqentities` drift in the reused container (known memory) produced the baseline's 17 IT failures.
- **Live data check:** c1wh and nywh PRD have 0 users named `service-account` or with a blank name (control: `admin` = 1 each).
- **Not done here:** merge, `on dev`, the post-deploy grant query on every tenant, the dev manual test (needs a non-super-admin DEV credential, O-3), and the O-1 generic-plan measurement.

## 13. Merge and deploy (2026-11-04, wms-merge)

- **Merged:** #615 into `develop` as `08113d9f`, pinned to the graded head `1cbfecab`.
- **Base and conflicts:** develop had not moved since the PR base `68a20d76`, so there were no conflicts and no re-grade was needed.
- **CI:**
  - PR check `test` (`mvn clean verify -Pci`) passed on `1cbfecab`.
  - Develop push run 41817413395 passed (test + build).
- **Deploy:** dev serves `develop-08113d9f`. `post-merge-verify.sh` printed ALL PROVEN.
- **Flyway on `dev_wh01_om1`:** `2.2.46 adjustment alert see all function`, `success=true`. The grant is held by exactly `super-admin` (queried 2026-11-04).
- **ClickUp:** `on dev`, with both ACs ticked. Markers: 5 flipped to `✓ merged(SBDEV-4002: #615 08113d9f, 2026-11-04)`.
- **Next:**
  - the §7.4 manual test via `wms-dev-probe` (O-3: needs a non-super-admin DEV credential);
  - the post-deploy grant query on each other tenant as it deploys (O-2);
  - O-1 measurement;
  - then `archive-plan`.

## 14. Dev manual test (2026-11-04, wms-dev-probe): 3/3 pass

| # | Scenario | Result |
|---|---|---|
| S1 | See-all: `panderson` sees all 3 seeded rows (including `oms_integration`) | ✅ keys are the literal contract |
| S2 | Narrowed: the super-admin see-all grant is removed for 5 s (Nam-approved) | ✅ only `panderson`'s own row, `truncated:false` |
| S3 | Grant restored | ✅ all 3 rows again, immediately |

- **Build:** `develop-3b77a3c0`.
- **Seed:** ids 9900000001–3, `SKU-T4002`, client 52200.
- **Restore proof:** both `restored` (the grant row, and the seed range after deletion).
- **Side effects:** none (raw SQL seeds; no `stockrecord` triggers). O-3 is resolved by the grant toggle instead of a second login.
- **#616 tooling, checked the same day** with `origin/develop` `3b77a3c0`'s script:
  - self-test 26/26 under `/bin/bash` 3.2;
  - real repo: V2.2.46 is TAKEN (merged), V2.2.47 is TAKEN (in flight, SBDEV-4007), V2.2.48 is FREE;
  - audit is clear, and the highest claimed version is V2.2.47.
- **Remaining:** O-2 (grant query per tenant on deploy), then `archive-plan`. O-1 was closed in §15.

## 15. O-1 generic-plan measurement (2026-11-07): closed

The query is the shipped SQL from `origin/develop` `StockrecordRepository.findAdjustmentAlerts`, with the same predicates and order.

| DB | PG | Plan | Result |
|---|---|---|---|
| dev `dev_wh01_om1` (9.7M rows) | 16.10 | `EXPLAIN (GENERIC_PLAN)`, all 4 params unbound | Parallel Index Scan on `index_stockrecord_created` (`created > $1`). `($3 OR operator = $4)` is a filter. Limit cost 4235..43405 |
| c1wh-shipitez-prd (1.84M rows; 12,217 in the last 24 h) | 14.23 | custom, narrowed (`false OR operator = 'nobody-x'`, `created > now()-24h`) | Index Scan on `index_stockrecord_created`, cost 166 |
| c1wh-shipitez-prd | 14.23 | generic | **Not measurable.** PG 14 has no `GENERIC_PLAN`, the read-only MCP rejects `PREPARE`/`SET`, and `pg_stat_statements` is not installed on either DB |

- **Verdict:** both plan modes produce the same shape: an index range scan on `created`, bounded by the 24-hour floor, with the operator term as a row filter. The `seeAll` OR does not stop the planner from using the index.
- **Inference, not measured on c1wh:** with `plan_cache_mode=auto` (both DBs), PG uses the generic plan only if its estimated cost is at or below the average custom-plan cost. The generic plan has to guess the selectivity of the unbound `created > $1` (dev estimate about 43k), while the stats-backed custom plan on c1wh costs 166. So c1wh should keep using custom plans.
- **Dev-only finding (environment, not code):** dev `stockrecord` has **no statistics**: no `pg_stats` row for `created`, `last_analyze` and `last_autoanalyze` both null, and `reltuples` is about 9.7M while `n_live_tup` is 10,772. Because of that, the **narrowed** custom plan on dev picks a **Parallel Seq Scan of all 9.7M rows** (cost about 373k), while see-all keeps the index (estimated 381 rows ≥ LIMIT 200, so it can stop early). This is not a code defect: c1wh has stats (autoanalyze 2026-10-28) and gets the index. **Fixed 2026-11-07** (Nam approved): `ANALYZE stockrecord` ran on dev. `pg_stats` now has `created`, and the same narrowed query now uses an Index Scan on `index_stockrecord_created`, cost 4.5 (was a seq scan at about 373k).

## 16. O-2 per-tenant check (2026-11-07): not deployed yet on any reachable PRD

| DB | V2.2.46 applied | `super-admin` role exists | Function row | Grant holders |
|---|---|---|---|---|
| dev `dev_wh01_om1` | ✅ (2026-11-04) | ✅ | ✅ | exactly `super-admin` |
| c1wh-shipitez-prd `wh01_shipitez_v2` | ❌ (at 2.2.45) | ✅ 1 | none yet | — |
| nywh-shipitez-prd `wh02_shipitez_v2` | ❌ (at 2.2.45) | ✅ 1 | none yet | — |
| nywh-hydra-prd `wh01_hydra_v2` | ❌ (at 2.2.45) | ✅ 1 | none yet | — |
| wsl-wineco-prd and all UAT DBs | not checked: their database connections timed out this session | | | |

- **Ready to deploy on these 3 PRD DBs:** `super-admin` exists on all of them, so V2.2.46's grant will land when it's applied. It can't fail closed there. Hydra PRD was one of O-2's unknowns and is now resolved.
- **Still open:** re-run the grant-holders query on each PRD after it deploys. Check WSL PRD and the UAT DBs once their connections are back.

