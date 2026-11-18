---
ticket: SBDEV-4002
clickup: 868mrcfmg
tier: T3
artifact: analysis-bundle (input to the plan, NOT the plan)
code_ref: v2/wms2-api origin/develop @ 68a20d76c791dc9b5175a8e2fac7f639e667f4f9 (fetched 2026-11-04)
web_ref: v2/wms2-web-ui origin/develop @ 8eb11fe
date: 2026-11-04
---
# SBDEV-4002: per-caller scoping of `GET /v3/stockrecord/adjustmentAlerts` (analysis bundle)

Code was read from `origin/develop` with `git show` and `git grep`. Citations are a file plus a quoted snippet. All database numbers come from read-only queries run on 2026-11-04 through the MCP server named next to each one.

## TL;DR
1. **Filter in SQL, but the reason is narrower than "post-filtering breaks truncation".**
   - A Java filter placed *before* `truncated = rows.size() >= clampedLimit` breaks the cursor: the caller's own rows past the page are never served.
   - A Java filter placed *after* the trim/`nextSince` block keeps the cursor correct. It still leaks other operators' activity through `truncated` and `nextSince`, and it loads up to 200 other people's rows per poll.
   - Only the SQL predicate is both correct and leak-free (§1.4).
2. **Identity: use `authentication.getName()`, the same lookup `FunctionGuardInterceptor.currentUsername()` uses.**
   - The writers stamp `operator` with `SecurityContextUtils.getUserName()`: `preferred_username`, falling back to the JWT `sub`.
   - The route gate checks `getName()`: `preferred_username`, falling back to `"service-account"`.
   - The two give the same string for every human Keycloak login and differ only for a token with no `preferred_username`.
   - Never use `getAuthorizedName()`. It falls back to `anonymous`, which is a real `mywms_user` on Hydra UAT.
   - `RtsDestinationValidator` already does exactly this inside a service.
3. **Four existing test classes go red on the change and need call-shape updates, not weakening:**
   - `StockrecordRepositoryAdjustmentAlertQueryTest`, which uses `getMethod("findAdjustmentAlerts", Date.class, int.class)`.
   - `StockrecordAdjustmentAlertDoubleToastIT`.
   - `StockrecordServiceUnitTest`: 14 stubs/verifies, plus a new `@Mock AccessService`. The class uses `@InjectMocks`, so an unmocked new constructor argument arrives as null and NPEs.
   - `NameKeyedGrantSeedRailTest`: its ALLOW_LIST reds by design on any new name-keyed `r.name` grant.
4. **The V2.2.19 comment "no test executes SQL … IT harness is down, SBDEV-2217" is out of date.**
   - `AppPostgresDBSetupExtension` now migrates `classpath:db/migration`.
   - Four `*MigrationIT` classes already run grant seeds.
   - The new migration can and should be tested by a Testcontainers IT.
5. **The next free migration version is V2.2.46.**
   - develop's head is V2.2.45, and dev, c1wh PRD and nywh PRD are all at 2.2.45.
   - There are 0 open PRs.
   - No unmerged remote branch committed since 2026-10-01 carries a migration.
6. **This change reduces noise; it is not a confidentiality control.**
   - Every narrowed caller can still read every operator's stockrecords through the Stock Unit Record report (`/stockrecordView/search/*`, `/v3/report/exportStockUnitRecord`).
   - That report is gated by the same `WEB_UI_VIEW_STOCK_UNIT_RECORD`.
7. **The sysprop catalog has drifted.** `wms2-sysprop-catalog.md` says `ADJUSTMENT_ALERT_POLL_ACTIVATED` "is `true` on DEV only". It is also `true` on c1wh PRD and nywh PRD (queried).

## §0 Affected sites (by enumeration)

**How this list was built:** one `git grep -n <literal> origin/develop` over the whole repo per literal:
- `findAdjustmentAlerts`, `getAdjustmentAlerts`, `adjustmentAlerts`, `ADJUSTMENT_ALERT`, `StockAdjustmentAlertView`, `WEB_UI_VIEW_STOCK_UNIT_RECORD`
- `FunctionEnum.class`
- `updateFunctionList|.initDB(`
- `mywms_role_mywms_function` (src/test)
- `setOperator(` and `new Stockrecord(` (src/main)

**What it can miss:** sites that use none of these literals, other branches (swept separately in §3.2), and other repos (the web UI is covered in §1.6).

**Positive control:** every literal returned at least one hit.

| # | file + quoted snippet | construct | in scope? | why |
|---|---|---|---|---|
| 1 | `controller/StockRecordController.java`: `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_RECORD)` / `public Map<String, Object> adjustmentAlerts(` | route gate + handler | YES (body only) | Gate stays as is (pinned by #22) |
| 2 | same file, `stockRecordDetailsById` | sibling handler | no | Report popup, not the poll |
| 3 | `service/StockrecordService.java`: `public Map<String, Object> getAdjustmentAlerts(long sinceEpochMillis, int limit)` | service | YES | Resolve the caller and the see-all flag; fail closed with no caller |
| 4 | same: `stockrecordRepository.findAdjustmentAlerts(new Date(effectiveSince), clampedLimit);` | repo call | YES | Gains scope parameters |
| 5 | `repo/jpa/StockrecordRepository.java`: `List<StockAdjustmentAlertView> findAdjustmentAlerts(@Param("since") Date since, @Param("limit") int limit);` | native `@Query` | YES | Add the operator predicate |
| 6 | `repo/projection/StockAdjustmentAlertView.java` | projection | no | Response shape unchanged |
| 7 | `WmsConstants.java`: `ADJUSTMENT_ALERT_PAIRS = {` | match set | no | — |
| 8 | `WmsConstants.java`: `SYSTEM_PROPERTY_ADJUSTMENT_ALERT_POLL_ACTIVATED_KEY` | sysprop | no | Checked before any scoping |
| 9 | `WmsConstants.java`: `public static final class FunctionEnum {` (86 String constants) | registry | YES | New constant goes here |
| 10 | `AccessService.java`: `public void updateFunctionList() {` (reflects `FunctionEnum.class.getFields()`) | fresh-DB row creator | no (automatic) | Creates the row, grants nothing |
| 11 | `UtilRestController.java`: `@Service` … `accessService.updateFunctionList();` (in `initDB`) | fresh-DB seed | YES | Needs a hand-written `grantFunction(<NEW>, role_super_admin);` line |
| 12–17 | `V2.2.11` sysprop seed; `V2.2.00` row `(529,…'WEB_UI_VIEW_STOCK_UNIT_RECORD'…)`; `V2.2.19` STEP 3; `V1.1.02__wms_data.sql`; `db/ref/losref*.sql` | seeds / dumps | no | Context or templates only |
| 18 | `db/audit-access-invariants.sql`: `(28,'Stock Unit Record', ARRAY['WEB_UI_VIEW_STOCK_UNIT_RECORD'])` | read-only audit | no | Run its "what the deploy GRANTS" check and SET 11 after deploy |
| 19–21 | `ReportController` (exportStockUnitRecord), `SdrFunctionRules` (StockrecordView), `ClientController` | sibling reads of the same data | no | Same rows, not scoped → this is not a security boundary |
| 22 | `Sbdev3017TrancheGateContextTest`: `row("StockRecordController", "/v3/stockrecord/adjustmentAlerts", "WEB_UI_VIEW_STOCK_UNIT_RECORD");` | route pin | keep green; do not edit | Guards against gating the route on the new function |
| 23 | `StockrecordResourceWithdrawalContextTest`: `"AC-2 · MVC GET /v3/stockrecord/adjustmentAlerts still answers 200"` | MVC smoke | keep green | — |
| 24 | `SdrUncalledSurfaceNotExportedContextTest` | comment | no | — |
| 25 | `StockrecordRepositoryAdjustmentAlertQueryTest`: `.getMethod("findAdjustmentAlerts", Date.class, int.class)` | SQL/constant sync test | YES (call shape) | Throws `NoSuchMethodException` on a signature change; its `CLAUSE` regex must still parse |
| 26 | `StockrecordAdjustmentAlertDoubleToastIT`: `stockrecordRepository.findAdjustmentAlerts(since, 1_000_000)` (seeds `operator` `"sbdev3382"`) | Postgres IT | YES (call shape) | Call it in see-all mode |
| 27 | `StockrecordServiceUnitTest`: `@DisplayName("getAdjustmentAlerts (SBDEV-2658)")`, 14 `findAdjustmentAlerts(any(java.util.Date.class), anyInt())` | unit | YES | Add `@Mock AccessService` |
| 28 | `StockRecordControllerUnitTest`: `setupMockMvc(controller);` | unit | no | Covers `stockRecordDetailsById` only; uses the helper with no guard |
| 29 | `UtilRestControllerSeedUnitTest` (RTS precedent `initDB_shouldGrantRtsDestinationFunctionToExactlyOutboundManagerAndSuperAdmin`) | seed parity | YES (extend) | — |
| 30 | `NameKeyedGrantSeedRailTest`: `"V2.2.42__mobile_force_scan_manual_entry.sql", 1);` | rail | YES (add entry) | — |
| 31 | `ReportReadGateUnitTest`, `SdrFunctionRulesUnitTest`, `StockrecordViewHalContextTest` | sibling pins | no | — |
| 32–33 | `model/Stockrecord.java` `@NotNull private String operator;`; 8 × `setOperator(SecurityContextUtils.getUserName())` (7 in `StockrecordService`, 1 in `StockunitBusinessService.createStockUnitCore`) | writers | no | Context for §2 |
| 34 | web `plugins/adjustmentAlerts.client.js`: `if (!heldFunctions.includes('WEB_UI_VIEW_STOCK_UNIT_RECORD')) return` | client guard | no | Contract unchanged |

## §1 Current architecture

**1.1 Controller.**
- `StockRecordController extends AdminController` and is not in `GUARDED`. Its only gate is the method-level `@RequiresFunction(...WEB_UI_VIEW_STOCK_UNIT_RECORD)`. The handler ends `return losStockUnitRecordService.getAdjustmentAlerts(since, limit);`.
- The handler accepts `@AuthenticationPrincipal Principal principal` but never uses it, and it shouldn't be relied on:
  - The token is a `JwtAuthenticationToken`; `JwtAccessTokenCustomizer.convert` builds it with `new JwtAuthenticationToken(jwt, authorities, username)`.
  - That token's `getPrincipal()` is the `Jwt`, not a `Principal`.
  - Read `SecurityContextHolder` instead.

**1.2 Service order of operations.**
1. Sysprop gate: `if (!Boolean.parseBoolean(syspropService.getSysvalue(...ADJUSTMENT_ALERT_POLL_ACTIVATED_KEY)))` returns `{serverTime, items:[], truncated:false}` without touching the DB. Scoping must go after this step.
2. Clamp: `Math.max(1, Math.min(limit, 200))`.
3. 24-hour floor: `MAX_ALERT_LOOKBACK_MS = 24L * 60 * 60 * 1000`, applied as `Math.max(since, floor)`.
4. The repo query.
5. `serverTime` is sampled after the query.
6. `truncated = rows.size() >= clampedLimit`. When truncated, trailing rows that share the last row's millisecond are trimmed and `nextSince = boundary - 1L`. If every row shares that millisecond, `nextSince = boundary + 1L` and a WARN is logged.
7. Each row becomes a 12-key item: `id, created, clientNumber, clientName, sku, location, amountChange, amountAfter, operator, activityCode, type, reason`. The response keys are `serverTime, items, truncated, nextSince?`.

**1.3 SQL.**
- `… FROM stockrecord sr JOIN client c ON sr.client_id = c.id WHERE sr.created > :since AND ((CYCLE_COUNT/STOCK_ALTERED) OR (MANAGE_INVENTORY/ALTERED,REMOVED) OR (MANUAL_REMOVAL/REMOVED,ALTERED) OR (DAMAGED/STOCK_CREATED)) AND sr.amount <> 0 ORDER BY sr.created ASC, sr.id ASC LIMIT :limit`.
- `operator` is a reserved word and is quoted as `sr."operator"`. The new predicate must quote it too.

**1.4 How a per-caller filter interacts with the cursor.** This confirms the SQL approach and refutes the strong form of "post-filter breaks truncation".

| Option | Cursor | Leak | Cost |
|---|---|---|---|
| A. SQL predicate before `LIMIT` | Correct: the existing truncation, millisecond-trim and `nextSince` logic is reused verbatim over the caller's own rows | none | one more filter on an existing index scan |
| B. Java filter **before** the truncation block | **Broken.** A 100-row page filtered to 3 rows gives `truncated=false`. The client's `anchorFor(serverTime, items, pageLimit)` then returns `serverTime` when `items.length < pageLimit`, so the caller's own rows beyond that page are never served | — | — |
| C. Java filter **after** the truncation block | Correct | **Leaks:** `truncated` and `nextSince` reveal other operators' bursts | up to 200 other people's rows per poll per user |

Recommendation: option A.

**1.5 Index and plan on c1wh PRD** (`explain_query`, estimates only):
- There are 14 indexes, including `index_stockrecord_created btree (created)` and `index_stockrecord_operator btree (lower(operator))`.
- `EXPLAIN ANALYZE` was refused by the MCP server's read-only validator.
- Baseline plan: Limit → Sort → Nested Loop → Index Scan on stockrecord (cost 0.43..214.44), with the pairs and amount in the `Filter`.
- With `AND (false OR sr."operator"='rfernandez')` the plan shape is identical and the scan costs 0.43..221.03; the operator check is just one more term in the same `Filter`.
- What I could not measure:
  - Literals were inlined, so this is a custom plan.
  - A generic plan under pgjdbc server-side prepare cannot fold `(:seeAll OR …)`. I expect the same shape, but that is unmeasured.
- Exact `=` cannot use the `lower(operator)` index, and doesn't need to.
- Worst case for a narrowed caller is a scan of the full 24-hour window: 10,330 rows on c1wh, out of 1,877,195 in the table.

**1.6 Web UI** (`v2/wms2-web-ui` `origin/develop` 8eb11fe): **no change needed.**
- The only function the poller checks is `WEB_UI_VIEW_STOCK_UNIT_RECORD`, alongside the `functionsLoaded` and `functionsError` guards.
- It reads `serverTime`, `items`, `truncated`, `nextSince`, and the item fields `id`, `created`, `operator` and `sku`. All of these are unchanged under option A.
- `util/adjustmentAlertCursor.js` `anchorForResponse` uses `nextSince + OVERLAP_MS` when the page is truncated and `anchorFor(...)` otherwise.
- Nothing in the non-test UI code enumerates `WEB_UI_VIEW_*` by prefix (`git grep` returned 0). Control: the literal `WEB_UI_VIEW_STOCK_UNIT_RECORD` is found 3 times in the plugin and once in `appMenuList.js`. A dynamically built name such as `'WEB_UI_' + x` would not be caught.

## §2 Identity

**Reader side (the gate).**
- `currentUsername()` returns `authentication == null ? null : authentication.getName()`.
- `JwtAccessTokenCustomizer` sets that name to `Objects.toString(jwt.getClaimAsString("preferred_username"), "service-account")`.
- `getAllRoles` joins user → group → role → function and ends `where u.name = :username`.
- `mywms_user_mywms_role` (direct user-to-role rows) has 0 rows on both dev and c1wh.

**Writer side (`stockrecord.operator`).**
- There are 8 `new Stockrecord(` constructions, and each one calls `setOperator(SecurityContextUtils.getUserName())`.
- `git grep -i "insert into stockrecord"` in src/main returns 0. Control: the IT's own seed insert is found in src/test.
- Not covered by this search: triggers and OMS-side direct inserts.

`getUserName()` resolves as follows:

| Situation | `getUserName()` returns |
|---|---|
| JWT has `preferred_username` | that value |
| JWT has no `preferred_username` | the JWT `sub` |
| principal is a `UserDetails` | its username |
| principal is a `String` | that string |
| none of the above | `"anonymous"` |

**Do the two match?**

| Token | reader: `getName()` | writer: `getUserName()` | Match? |
|---|---|---|---|
| Human Keycloak login | `preferred_username` | `preferred_username` | yes |
| JWT without `preferred_username` | `"service-account"` | `sub` (UUID) | **no** (see below) |
| Job or no authentication | — (no poll) | `anonymous`, or `anonymousUser` | n/a |

- The mismatched case would need a `mywms_user` named `service-account` holding the function just to pass the gate, so it is not a realistic poller.
- `anonymousUser` appears in 149 dev rows over 365 days. They are all `PACKAGING` or `CANCELLED_ORDER_FROM_WEBSERVICE` and none match the alert pairs.
- **Recommendation:** copy `RtsDestinationValidator`. Use `getName()`; if it is null, return empty items and make no repository or `AccessService` call.

**Case sensitivity.** Both comparisons are exact `=`.

| DB | Measurement | Result |
|---|---|---|
| c1wh | alert-pair rows, all time | 4,078 |
| c1wh | mixed-case operators | 0 |
| c1wh | mixed-case user names | 0 of 37 |
| c1wh | rows with no exact user match | 95 |
| c1wh | rows matching a user only case-insensitively | 0 |
| nywh | mixed-case users | 0 |
| nywh | matched rows in last 60 days | 0 |
| nywh | orphan-operator rows in last 60 days | 0 |
| dev | mixed-case users | 44, all `Z-…(archived)` |
| dev | matched rows with no exact user match, last 24 h | 0 |

- The 95 c1wh rows belong to `dstevenson`, `jcerven`, `jwarcate` and `sthompson`. The latest is 2024-05-10, far outside the 24-hour floor.
- Exact matching is correct.

**NULL operator.**
- `stockrecord.operator` is NOT NULL in the database on c1wh and dev (information_schema), and the entity field is `@NotNull`.
- Measured on c1wh matched rows: null 0, empty 0, sentinel values 0. The NOT NULL constraint is what makes those zeros trustworthy.

**System rows.**
- `oms_integration` wrote 8 DAMAGED/STOCK_CREATED rows on c1wh (2026-09-23 to 2026-10-15).
- It holds no roles on c1wh or dev, so it never polls. After the change only see-all holders get those alerts, which is the decided behaviour.

## §3 Flyway and seeding

**3.1 Name: `WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS`.**
- Existing patterns:
  - `WEB_UI_VIEW_<SCREEN>`
  - `WEB_UI_ACTION_<VERB>_<OBJ>`
  - `MOBILE_UI_*`
  - `MOBILE_UI_NEVER_TIME_OUT`, a capability flag rather than a screen
- This function widens what a view can read, so `VIEW_` fits better than `ACTION_`.
- The constant's value must equal its field name.
- c1wh has no existing function matching `%ADJUSTMENT%`.
- Add it to role-matrix §3.9.3 ("WEB_UI_VIEW_* with no page") with a "data scope, not a page" note.

**3.2 Version: V2.2.46.**
- develop's latest migrations are `V2.2.44__parcel_monitor_view_manifest_location.sql` and `V2.2.45__location_default_fla_bounds.sql`.
- Live Flyway heads:
  - dev: `2.2.45`, `2.2.44`, `2.2.43`, all successful.
  - c1wh: `2.2.45`, `2.2.44`, `2.2.43`, `2.2.42`.
  - nywh: max `2.2.45`.
- In-flight sweep:
  - **Open PRs:** `gh pr list --state open` returned 0. Control: `--state all` returned #610–614, all merged 2026-11-03.
  - **Remote branches:** there are 512 remote refs. For each ref with commits not on develop, I diffed it against its merge-base, filtered to migration, `StockRecordController`, `StockrecordService`, `StockrecordRepository`, `WmsConstants`, `UtilRestController`, `AccessService` and `StockAdjustmentAlertView`.
    - Hits were only on stale branches: `feature/SBDEV-2001` (2026-07-19), `port/SBDEV-2488` and `port/SBDEV-2481` (2026-06-25), and `feature/utc-timezone` (2026-06-17).
    - Control: refs committed since 2026-10-01 → 12 unmerged refs (`release` and the `claude/owl-v2.0.15x-*` promote/recut branches). None carries a migration.
  - **Local worktrees:** the ticket worktrees (3552, 3922, 3947, 3987 and the develop baseline) have 0 dirty files and no migrations.
  - **sbdocs:** no plan reserves `V2.2.4[6-9]`.
- Not covered: unpushed work and the Linux box. Re-check develop's migration directory right before committing.

**3.3 Templates.**
- V2.2.19 STEP 1, the function row:
  ```sql
  INSERT INTO mywms_function (id, created, modified, name, number, version, function, client_id)
  SELECT COALESCE((SELECT MAX(id) FROM mywms_function), 0) + 1, now(), now(),
         '<F>', '<F>', 0, '<F>', 0
  WHERE NOT EXISTS (SELECT 1 FROM mywms_function WHERE function = '<F>');
  ```
- V2.2.21, the role grant:
  ```sql
  INSERT INTO mywms_role_mywms_function (rolelist_id, functionlist_id)
  SELECT r.id, f.id
    FROM mywms_role r
    JOIN mywms_function f ON f.name IN (…)
   WHERE r.name = 'inventory-manager'
     AND NOT EXISTS (SELECT 1 FROM mywms_role_mywms_function x
                      WHERE x.rolelist_id = r.id AND x.functionlist_id = f.id);
  ```
- Why never `ON CONFLICT` (from the V2.2.19 header):
  - The base dump has no unique constraint on the grant table → error 42P10.
  - Tenants with a key carry it under drifting names: `_pkey` on WineCo dev, `_pk` on Hydra UAT.
  - Hydra PRD has neither a primary key nor a unique index on it.
- ⚠ The newest seed (V2.2.42) uses a different pattern: `nextval('seqentities')` and `r.name IN ('inventory-manager','outbound-manager','super-admin')`.
  - Nam's chosen `max+1` id is safe. On c1wh, `seqentities.last_value` (122,380,159) is already past `max(mywms_function.id)` (122,348,918), so the sequence can't later issue the same id.
  - Write the grant as `r.name IN ('super-admin')`, not `r.name = 'super-admin'`. The parity tests parse `(?is)r\.name\s+IN\s*\(([^)]*)\)`.

**3.4 Fresh-database path.**
- `UtilRestController` is annotated `@Service`, so `/initDB` never routes, and nothing in src/main calls it. `initDB` is unreachable in production, but it is the unit-tested definition of what a fresh tenant gets.
- `initDB` calls `updateFunctionList()`, which creates the `mywms_function` row automatically.
- **The grant is not automatic.** `initDB` creates its own `role_super_admin` and lists its grants one line at a time. The PARCEL_PICKING comment says super-admin "does not come for free".
- So add `grantFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS, role_super_admin);`. The memory "a new FunctionEnum constant needs THREE things" covers this.

**3.5 `mywms_function` columns on c1wh.**
- NOT NULL: `id`, `number`, `version`, `function`, `client_id`.
- Nullable: `created`, `modified`, `name`.
- These are exactly V2.2.19's eight columns, with no extra NOT NULL ones.
- c1wh, nywh and dev each have 86 rows, matching the 86 constants on develop.

**3.6 Does role `super-admin` exist?**

| DB | Result |
|---|---|
| dev `dev_wh01_om1` | 1 row |
| c1wh PRD | 1 row (83 grants) |
| nywh PRD | 1 row |
| base dump `V2.2.00` | present: `(585, … 'super-admin', … 'ROLE000006')` |

- Not queried: Hydra PRD/UAT, ShipItEz UAT and WSL UAT.
- A tenant without the role is skipped silently, so run the post-deploy query on every tenant.

**3.7 ITs run migrations.**
- `AppPostgresDBSetupExtension` sets `MIGRATION_LOCATION = "classpath:db/migration"`.
- Precedents to copy: `ManualEntryOverrideMigrationIT`, `CancellationRtsDestinationMigrationIT`, `CancellationWaiveMigrationIT`, `ReplenishmentOrderActionFunctionMigrationIT`.

## §4 Guard tests

**How I searched:** files containing both `getDeclaredFields()` and `FunctionEnum` (7 files), `FunctionEnum.class`, `hasSize(NN)` in security tests, and `mywms_role_mywms_function` in src/test.

**Not covered:** an IT that pins a `count(*)` of `mywms_function` (not searched).

| Test | What it pins | Effect |
|---|---|---|
| `FunctionGuardArchTest` AC-3 (`declaredFunctionConstants()`) | annotation values are a subset of declared constants | no break |
| `SdrRuleStartupAssertion`, `SdrFunctionRulesUnitTest`, `SdrRuleStartupCheckUnitTest` | SDR rule values are a subset of declared constants | no break |
| `UtilRestControllerSeedUnitTest` | per-function grant sets | no break; extend |
| `NameKeyedGrantSeedRailTest` ALLOW_LIST: `V2.2.18`=2, `V2.2.19`=5, `V2.2.21`=1, `V2.2.34`=1, `V2.2.38`=1, `V2.2.42`=1 | every name-keyed role/group seed, at its exact count | **reds by design**; add `V2.2.46__…`=1 |
| `Sbdev3017TrancheGateContextTest`: route row plus `assertThat(EXPECTED).hasSize(234)` | route → function map | no break while the annotation is untouched |
| `ActionGuardAnnotationContractUnitTest` `hasSize(14)` | ACTION gate inventory | no break |
| `QueryTest`, `DoubleToastIT`, `ServiceUnitTest` (the stockrecord ones) | method signature | **red**; update call shapes only |

The `NameKeyedGrantSeedRailTest` entry needs a reviewed-rationale comment: the seed is keyed by name so the parity test can parse it, and role renaming was closed in SBDEV-3545.

**Constraints from the authz memory hub:**
- "Three things": the constant, the Flyway row plus grant, and the `initDB` line.
- Gate tests must walk Mockito varargs fully, because Mockito expands varargs.
- `setupMockMvc` installs no interceptor, so it cannot exercise a gate.
- The "gate a route on its screen's existing function" rule (Option B) is overridden here by Nam's decision. Record that exception in the plan, as SBDEV-3606 did.
- After deploy, run `audit-access-invariants.sql` SET 11.

## §5 Design constraints and alternatives

**Constraints:**
- **C1** Response shape is identical.
- **C2** The sysprop-off path is unchanged and makes no queries.
- **C3** The filter is applied before `LIMIT`.
- **C4** The caller is `getName()`; if it is null, fail closed.
- **C5** The route gate is unchanged.
- **C6** The grant goes to super-admin only, in both V2.2.46 and `initDB`, with a parity test.
- **C7** There is one SQL text, so `QueryTest` keeps guarding the pair list.
- **C8** This is not a confidentiality control.

| # | Design | Verdict |
|---|---|---|
| **A1** | One query with `AND (:seeAll OR sr."operator" = CAST(:operator AS varchar))`. The service computes `seeAll` with `accessService.doesUserHaveAnyAccess(name, NEW)` | **Recommended.** `CAST` is the repo's existing `CAST(:clientId AS bigint)` idiom; it guards against Hibernate 6 binding an untyped null as bytea. Or pass `""` in see-all mode. |
| A2 | Two `@Query` methods | Rejected: duplicates the pair list, which drifts because `QueryTest` reflects on one method only |
| A3 | Filter in Java | Rejected for the reasons in §1.4 |
| A4 | A single nullable operator parameter, where null means "all" | Rejected: fails open |
| A5 | Resolve see-all in the controller | Viable. The service is preferred, following the RTS precedent and because `ControllerUnitTest` uses no guard |
| A6 | Reuse `WEB_UI_ACTION_ADJUST_AMOUNT` | Rejected by Nam's decision, and measured useless: the same 26 holders on c1wh |
| A7 | `lower()` match to use the operator index | Rejected: diverges from the gate; 0 case-only mismatches; `created` is the right index |

**Cost and effect:**
- Use `doesUserHaveAnyAccess` (one query) rather than `checkAnyAccess`, which adds a `findByName` probe on every narrowed poll.
- Each poll then makes 2 `getAllRoles` calls.

| Tenant | Effect |
|---|---|
| c1wh | 23 super-admin users see everything. 3 inventory-manager-only holders become narrowed, including `cloverdale-qa1`, a live alert operator. `rfernandez`, `jfernandez` and `bcampbell` are super-admin. |
| nywh | All 9 holders are super-admin → no visible change. |
| dev | 45 holders: 38 via super-admin, 7 not. The 7 are `danielvalentim`, `daniilandriyenko`, `jovanyaguilera`, `markchilcote`, `truckloading`, `ursulajimenez` and `Z-mariaortiz(archived)`. Granting roles: `CS-REP`, `inventory-manager`, `super-admin`. |

## §6 Acceptance-criteria candidates

| AC | Test class | Kind | What it checks | Mutation it kills |
|---|---|---|---|---|
| 1 | new `StockrecordAdjustmentAlertOperatorScopeIT extends BasePostgresIntegrationTest`, copying DoubleToastIT's seed/wipe | Postgres IT | Seed matched rows for `alice`, `bob` and `oms_integration`, plus one unmatched `alice` row. Narrowed `alice` gets only her matched row; see-all gets all 3 | drop the predicate; change OR to AND; put the predicate on the wrong column |
| 2 | same | IT | Interleave `limit+1` rows for `bob` with `limit` rows for `alice`. Narrowed `alice` sees `truncated` computed over her own rows, and following `nextSince` serves every one of her rows exactly once (dedup by id) | the before-truncation Java filter (option B) |
| 3 | `StockrecordServiceUnitTest` | unit | A holder of the new function → repo called with `seeAll=true`; assert which function was checked | hard-coding false; checking the wrong constant |
| 4 | same | unit | A non-holder → `seeAll=false` and `operator == getName()`. Use one token where `preferred_username` differs from `sub`, and one with no `preferred_username` | using `getUserName()` or `getAuthorizedName()` |
| 5 | same | unit | No authentication → empty `items`, `truncated=false`, and neither the repo nor `AccessService` is called | the ANONYMOUS fallback; null treated as "all" |
| 6 | same, extending the sysprop-off test | unit | Sysprop off → no `AccessService` call | access check moved above the sysprop gate |
| 7 | same | unit | Identical key sets in both modes (response keys and the 12 item keys) | an added or renamed key |
| 8 | `UtilRestControllerSeedUnitTest` | unit | (a) the constant is declared with value equal to its name; (b) `initDB` grants exactly `{super-admin}`, checked against a sibling function as a positive control; (c) exactly one migration seeds the literal, its file starts with `V2.2.46__`, and its `r.name IN` set equals `initDB`'s set | missing initDB line; an extra role; a silent renumber |
| 9 | new `integration/schema/AdjustmentAlertSeeAllFunctionMigrationIT`, shaped like `ManualEntryOverrideMigrationIT` (Flyway target 2.2.45, then 2.2.46) | Postgres IT | No row at 2.2.45. After 2.2.46: one row with `name=number=function`, `version=0`, `client_id=0`, granted to exactly `{super-admin}`; a second apply adds 0 rows | `ON CONFLICT`; a 2-column insert; an extra role; a missing `NOT EXISTS` |
| 10 | `NameKeyedGrantSeedRailTest` | rail | The V2.2.46 entry has count 1 | — |
| 11 | `StockrecordRepositoryAdjustmentAlertQueryTest` | unit | Pair-set equality still holds on the new signature, and the SQL contains `sr."operator" =` OR'ed with the see-all parameter | pair drift; predicate removed |
| 12 | `Sbdev3017TrancheGateContextTest` (no edit) | context | The route is still gated only by `WEB_UI_VIEW_STOCK_UNIT_RECORD` | gating the route on the new function |

## §7 Manual test preconditions on DEV (read-only queries)

| Precondition | Value |
|---|---|
| Database | `dev_wh01_om1` |
| Flyway head | `2.2.45`, all successful |
| Poll sysprop | `true` |
| `super-admin` role | 1 row |
| Holders of `WEB_UI_VIEW_STOCK_UNIT_RECORD` | 45 of 100 users (38 via super-admin, 7 not) |
| Direct user→role rows | 0 |
| See-all tester | `panderson` (group `super-admin`) |
| Narrowed tester | `truckloading` (group `inventory-manager`) or `danielvalentim`. A Keycloak credential is needed; the wms-dev-probe kit holds only `panderson` |
| Matched rows, last 30 days | `panderson` 13 (latest 2026-11-02 12:31Z), `oms_integration` 2 (latest 2026-11-01) |
| Matched rows inside the 24 h floor today | **0** → fresh rows must be created |
| Null or empty operator | 0 |

Steps:
1. Create test rows:
   - an adjustment as `panderson`;
   - an adjustment as `truckloading`;
   - one `oms_integration` DAMAGED/STOCK_CREATED row via the dev-probe seed, with snapshot restore proof.
2. Poll as `panderson` → 3 rows.
3. Poll as `truckloading` → only its own row, `truncated:false`.
4. Check that the key sets are identical between the two responses.
5. After deploy, confirm the grant: `SELECT r.name … WHERE f.name='WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS'` → `super-admin` only.

## §8 Docs to update

**How I searched:**
- `grep -rln -i "adjustmentAlert|ADJUSTMENT_ALERT" sbdocs/3-Resources` found only `data-dictionary/wms2-sysprop-catalog.md`. Docs that describe the bell or toast without either literal would be missed.
- The same grep for `WEB_UI_VIEW_STOCK_UNIT_RECORD` found `wms2-function-to-docs-map.md`, `wms2-keycloak-role-matrix.md` and the sysprop catalog. It also found `wms1-function-permission-map.md`, which is out of scope.

Changes:
- **`wms2-sysprop-catalog.md`:**
  - Add the scoping rule to the `ADJUSTMENT_ALERT_POLL_ACTIVATED` row.
  - Fix the false "`true` on DEV only": c1wh and nywh PRD both return `sysvalue='true'`.
- **`wms2-keycloak-role-matrix.md`:**
  - §3.3: add a row for the new constant.
  - §3.9.3: add it to the reverse-gap list.
  - §4: add it to the super-admin persona row.
- **`wms2-function-to-docs-map.md`:** mention `adjustmentAlerts` and its scoping on the `StockRecordController` / `StockrecordService` line.
- **`design/wms2-rest-api-reference.md`:** the endpoint isn't documented there at all (grep found 0); add it or record the gap.
- Before claiming no other doc needs a bump, grep the architecture docs for function-count literals ("86 functions", "81 grants"). I didn't do this.

## Open evidence gaps
1. Plan behaviour of `(:seeAll OR …)` once pgjdbc switches to a generic prepared plan: unmeasured, because the MCP server refuses `EXPLAIN ANALYZE`.
2. Whether `super-admin` exists on the four other tenants: not queried.
3. A Keycloak credential for a DEV user who holds the view function but not super-admin, needed for the manual test.
