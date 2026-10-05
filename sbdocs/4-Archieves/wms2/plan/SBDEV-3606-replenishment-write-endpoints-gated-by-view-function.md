---
title: "Replenishment-order write endpoints are gated by the VIEW function"
ticket: "SBDEV-3606"
ticket_url: "https://app.clickup.com/t/868mbjaue"
type: "bugfix"
priority: "normal"
status: "archived"
tier: T3
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-30"
updated: "2026-10-01"
db_verified: true
base_commit: "043e7163 (wms2-api origin/develop) · 299cec1 (wms2-web-ui) · 108b2f5 (wms2-mobile-ui) · 90b90348 (oms-laravel-api)"
related:
  - "[[SBDEV-3017-B1-mvc-write-surface-gating]]"
  - "[[SBDEV-3381-cancellation-reversal-waive]]"
  - "[[SBDEV-3561-change-source-stock-unit-state-guard]]"
  - "[[SBDEV-3545]]"
tags:
  - plan
---

# Replenishment-order write endpoints are gated by the VIEW function

**Ticket:** [SBDEV-3606](https://app.clickup.com/t/868mbjaue)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix (authz) | **Tier:** T3 (authz, a Flyway grant on PRD, and a convention reversal) | **Priority:** normal
**V1/V2:** v2 only. v1 is reference-only and is not ported.
**Status:** pending approval. Ralplan round 1: Architect SOUND-WITH-CHANGES, Critic ITERATE (§13). Round 2: Critic APPROVE, Architect SOUND-WITH-CHANGES, with every one-edit fix applied (§14).
**Evidence:** `scratchpad/SBDEV-3606-analysis.md`, `SBDEV-3606-architect-review.md`, `SBDEV-3606-critic-review.md`. Every code claim was checked with `git show/grep origin/develop` at `043e7163`.

---

## 0. Affected Sites

**Method:** a full read of `ReplenishOrderController.java` (347 lines, 11 `@*Mapping`), each handler's service call traced, and `git grep` for each pin. **Blind spot:** the reads' transitive callees were traced one level only.

| # | Site (`src/main/java/net/aim_ai/wms/…` unless test) | Construct | In scope |
|---|---|---|---|
| 1–6 | `controller/ReplenishOrderController`: `/update`, `/updateStockUnit`, `/updatePriority`, `/changeSourceStockUnit`, GET `/cancelReplenishOrder/{id}`, `/create` | `@RequiresFunction(WEB_UI_VIEW_REPLENISHMENT_ORDER)` on a **write** (SBDEV-3017 B23–B28) | **yes** |
| 7–11 | same class: `/loadOrderByDestination`, `/getPickableLocations`, `/detailView` (ANY-of VIEW+MOBILE), `/replenishorderDetailsById`, `/stockUnitInfoForReplenishment` | read gates | no; unchanged |
| 12 | 9 `AdminController` mappings inherited under `/v3/replenishOrder/*` | `@PreAuthorize(IS_SB_ADMIN)`; the interceptor resolves them by the declaring class | no |
| 13 | `service/WmsConstants.FunctionEnum` | new constant | **yes** |
| 14 | `resources/db/migration/V2.2.35__seed_replenishment_order_action_function.sql` | function row + derived grant | **yes** |
| 15 | `controller/rest/UtilRestController.initDB` | `grantFunction(...)` line | **yes** |
| 16 | test `unit/config/FunctionGuardArchTest.REVIEWED_SHARED_GATE_FUNCTIONS` (6 entries) + the two Replenishment comment lines | pin | **yes** |
| 17 | test `security/Sbdev3017TrancheGateContextTest`: 6 `row("ReplenishOrderController", …)` | pin | **yes** |
| 18–20 | test `UtilRestControllerSeedUnitTest` (extend), `ReplenishOrderControllerGateH2Test` (new), `integration/schema/ReplenishmentOrderActionFunctionMigrationIT` (new) | tests | **yes** |
| 21 | mobile `controller/mobile/ReplenishController`: `POST /requestAmount`, `PUT /order/{id}`, `POST /multi-unitloads` | the same "VIEW gates a write" pattern; **also reachable by `receiving`** (§1, F1) | no; proposal P1 (§11) |
| 22 | `CustomerOrderController /batchUpdatePriorityByOrderIds` and `CustomerorderBatchService` → `updateReplenishmentOrderPriority` | side-effect write under `WEB_UI_VIEW_ORDER` | no; P3 |
| 23 | web-ui `components/internalOps/replenishment/open/*` buttons | no per-button function check | no; P2, which is sub-T3 on this ticket |

---

## 1. Problem Statement

> ⚠ **WineCo PRD was NOT measured.** The `wsl-wineco-prd` MCP timed out on 2026-09-30, and WineCo UAT was also unreachable from the Critic lane. The derived grant (§5.4) covers WineCo by construction. However, both the "nobody loses access" count and the pre-PRD probe (§5.1 #5) are **still owed** there. Retry the MCP before merge and record the outcome in §6.4.

Six handlers on `ReplenishOrderController` create orders, cancel them, change their priority and redirect source stock-unit reservations. All six are gated by `WEB_UI_VIEW_REPLENISHMENT_ORDER`. That is the same function that gates the screen and the five reads, so no function separates "may view" from "may change" on these routes.

**Who holds VIEW (read-only, 2026-09-30).** The query below takes the group→role→function path, which is the same path `UserRepository.getAllRoles` reads. The control, run in the same session, was `WEB_UI_VIEW_RECEIVING`, which resolved to the known role set {receiving, super-admin}. The query is the §6.4 SQL.

| DB | Roles holding VIEW | Users | `*ACTION*REPLENISH*` rows | direct user→role | Flyway head |
|---|---|---|---|---|---|
| dev_wh01_om1 | receiving#51805, super-admin#51806 | 41 | 0 | 0 | 2.2.34 |
| wh01_hydra_v2 (hydra nywh PRD) | receiving#584, super-admin#585 | 7 | 0 | 0 | 2.2.33 |
| wh02_shipitez_v2 (shipitez nywh PRD) | receiving#584, super-admin#585 | 9 | 0 | 0 | 2.2.33 |
| wh01_shipitez_v2 (shipitez c1wh PRD) | receiving#50405, super-admin#50406 | 34 (8 receiving-only) | 0 | 0 | 2.2.33 |
| WineCo PRD | **not measured** | — | — | — | — |

- Role ids differ per tenant, so a hardcoded id is wrong by construction.
- The 8 receiving-only users on c1wh are the users a "super-admin only" grant would lock out.
- **What the split does and does not buy (Architect F1).** On c1wh PRD, `receiving` also holds `MOBILE_UI_VIEW_REPLENISHMENT` and `MOBILE_UI_VIEW_REPLENISH_REQUEST`. Those two functions let it **create** replenishment orders through `POST /v3/replenish/requestAmount` (`@RequiresFunction(MOBILE_UI_VIEW_REPLENISH_REQUEST)`, which calls `requestReplenish` and then `replenishorderRepository.save`). They also let it **edit** destination and source through `PUT /v3/replenish/order/{id}`, which has no method annotation and so falls under the class gate `MOBILE_UI_VIEW_REPLENISHMENT`. This ticket closes only the six web routes. P1 (§11) closes the mobile ones using the same pattern.

---

## 2. Root Cause

- **How the six writes got their gate.** In the SBDEV-3017 tranche-1 census, rows 5.1–5.6 were given the screen's function because **no write function existed for this screen**. The same rule was later codified as §9.16 Option B, which was the putaway decision (2026-08-27): "the function that already gates the screen … no new constant".
- **What is and is not the defect.** Each annotation is correct under that rule. The defect is that the screen has no write function at all.
- **A misattribution to avoid (Critic H1).** The "38 vs 46 users / 403s 7 LIVE users" note in `FunctionGuardArchTest` belongs to `DashboardController#printToteLabels`, not to Replenishment. It is not a rationale for this screen, and this plan does not cite it as one.

---

## 3. Design Summary (RALPLAN-DR)

**Mode:** SHORT (T3, a single ralplan round).

**Principles**
1. **Nobody loses access on day one.** holders(new) == holders(VIEW) on every tenant, and the SQL guarantees it rather than a per-tenant list.
2. **The gate stays visible to the rails.** It is a method-level `@RequiresFunction`, with no class-level gate and no programmatic check.
3. **Grants are derived from existing grants.** They are never keyed by role name or id (`NameKeyedGrantSeedRailTest`).
4. **Reads are untouched.** The change only splits write authority out of VIEW on the six web routes.
5. **A deliberate break from a convention is written down** wherever a later agent would look.

**Decision drivers (top 3)**
1. Give the six **web** replenishment writes their own function, separate from view. The mobile create/edit routes stay under their VIEW functions until P1.
2. Zero day-one access loss across 5 PRD tenants, one of them unmeasured.
3. The rails must pin the new state, so that a silent revert goes red.

**Viable options**

| Option | Pros | Cons |
|---|---|---|
| **A (chosen). One `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER` on all 6 writes, granted by V2.2.35 as INSERT…SELECT from the VIEW grant.** | No access loss, even on unmeasured WineCo. No role names or ids. The same shape as V2.2.18 step 2. | Reverses Option B for this controller, so it needs back-references (§9). No behaviour changes until someone edits grants. Does not separate the mobile routes (F1). |
| **D. Same constant, granted by role name** (the V2.2.34 shape) | Explicit role list. | Reds `NameKeyedGrantSeedRailTest` unless the file is allow-listed. Misses any tenant whose VIEW holders differ, and WineCo is unmeasured. |
| **F. Six constants, one per handler** | The finest control. | The six are one capability behind six dialogs on one screen, so this is six times the seed, doc and pin churn. |

**Rejected options**
- **B. Keep VIEW.** That is the defect itself.
- **C. Reuse an existing action constant** (for example `WEB_UI_ACTION_PRINT_TOTE_LABELS`). Rejected on meaning alone: none of the existing actions describes replenishment maintenance.
- **E. Class-level gate.** Forbidden by `FunctionGuardArchTest#noSharedControllerCarriesRequiresFunction`, and it would re-gate the reads.

---

## 4. Architecture Overview

```
HTTP /v3/replenishOrder/<write>
  → FunctionGuardInterceptor.preHandle
      getMethodAnnotation(RequiresFunction)  ← method level wins; class level only if null
      none + class not in GUARDED → OPEN      (ReplenishOrderController is NOT in GUARDED)
      accessService.checkAnyAccess(user, value...)  ANY-of over UserRepository.getAllRoles
        (native group→role→function join on f.name, NO @Cacheable → a grant is live next request)
      deny → 403 {reason, requiredFunction} + header X-Authz-Denied: <requiredFunction>
  → handler → ReplenishorderService (@Transactional tenantTransactionManager)
```

**Callers of the six writes.** Found by `git grep` at each repo's `origin/develop`. Positive controls: web-ui has 47 `replenish` files and 127 `$axios` files.
- **wms2-web-ui:** the Replenishment screen popups call `/create`, `/cancelReplenishOrder`, `/updatePriority` and `/updateStockUnit`.
  - The one component that dispatches `/update` has its tag commented out.
  - `/changeSourceStockUnit` has no UI callers.
- **wms2-mobile-ui:** only the `/detailView` read, so the new gate needs **no MOBILE member**.
- **oms-laravel-api and Java:** none.

The Architect verified the neighbouring paths:
- SDR writes to `Replenishorder` are withdrawn (`RestConfiguration` unwritten list).
- There is no path-suffix aliasing (no `configurePathMatch`).
- CSRF is disabled, so the interceptor is today's only source of a 403 on these routes.

---

## 5. Fix Design

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Trigger |
|---|---|---|---|---|
| 1 | Database state | Tenant head ≥ 2.2.33. One image applies V2.2.34 and then V2.2.35. | implementer | — |
| 2 | Feature flags | N/A. The gate goes live with the annotation, and there is deliberately no toggle. | — | — |
| 3 | Config / env | N/A | — | — |
| 4 | Deploy order | Code and migration ship **in the same image**. No web-ui or mobile change is needed. | implementer | — |
| 5 | **Pre-PRD probe** (§5.1.1), per PRD tenant including WineCo | All checks pass | **Nam / devops** | **before the merge commit is promoted to `main`** |
| 6 | Post-deploy parity (§6.4) | dev: implementer, after the develop deploy, once `/api/public/version` shows the merge SHA. UAT/PRD: Nam / devops, once the version SHA contains the merge. Record results in §6.4. | as stated | as stated |
| 7 | Access / permissions | New `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`, granted to every VIEW-holding role. Keycloak is untouched. | implementer | — |
| 8 | Collision check | `src/main/resources/db/check-migration-version-collision.sh` | implementer | **immediately before merge** (blind spot: branches pushed after the 2026-09-30 sweep) |
| 9 | WineCo access | Retry the `wsl-wineco-prd` MCP and run the §1 count plus the §5.1.1 probe | implementer → Nam | before merge |

#### 5.1.1 Pre-PRD probe (read-only; run as the tenant's Flyway/app user)

**Why:** the PRDs are at 2.2.33, so V2.2.35 first lands behind V2.2.34's DDL. `StartupFlywayMigrator` keeps the app up when one tenant fails ("One tenant's failure never blocks the app or the other tenants"), and it counts two more non-apply paths as stale rather than failing:
- no `flyway_schema_history` (`baselineOnMigrate(false)`, then `skippedNoHistory++`);
- an active config with a blank `db_url` (`staleTenants++`).

Any of the three leaves that tenant's six writes 403 for **every** user.

**Landlord DB** (tenants that Flyway will never reach):
```sql
SELECT t.name, c.warehouse, c.db_url FROM tenant_db_configuration c JOIN tenant t ON t.id = c.tenant_id
WHERE c.active AND (c.db_url IS NULL OR btrim(c.db_url) = '');                    -- expect 0 rows
```

**Each tenant DB.** Run step 1 first. If it returns `f`, stop: the tenant has no history table and needs `db/backfill-flyway-history.sh` before it can ever receive V2.2.35.
```sql
SELECT to_regclass('public.flyway_schema_history') IS NOT NULL AS has_history;     -- 1: expect t
SELECT max(string_to_array(version,'.')::int[]) AS head                             -- 2: expect ≥ {2,2,33}
  FROM flyway_schema_history WHERE success AND version ~ '^[0-9.]+$';
SELECT count(*) FROM flyway_schema_history WHERE NOT success;                       -- 3: expect 0
SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tableowner <> current_user;  -- 4: expect 0
SELECT has_sequence_privilege('public.seqentities', 'USAGE');                       -- 4b: expect t (both INSERTs call nextval)
SELECT to_regclass('public.customerorder_cancellation_log') IS NOT NULL;            -- 5: expect t
SELECT count(*) FROM information_schema.columns                                     -- 6: V2.2.34 precondition
 WHERE table_name = 'customerorder_cancellation_log' AND column_name = 'reversal_waived';
--   if 6 returns 1 (column pre-exists), also expect 0 from:
--   SELECT count(*) FROM customerorder_cancellation_log WHERE reversal_waived AND (reversal_completed_at IS NULL
--     OR btrim(coalesce(reversal_waive_reason,'')) = '' OR reversal_waive_stock_returned IS NULL);
SELECT count(*) FROM mywms_function                                                 -- 7: F6 guard, expect 0
 WHERE (name = 'WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER' OR function = 'WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER')
   AND name IS DISTINCT FROM function;
```

- **Already measured (Architect, 2026-09-30).** Check 4 is `0` on all three reachable PRDs: every public table is owned by the `*_app` role. WineCo has not been measured.
- **Emergency remediation, pre-staged.** If a tenant fails to apply V2.2.35, run the two §5.4 INSERTs verbatim as that tenant's Flyway user.
  - They are idempotent, so the later Flyway apply is a no-op.
  - If V2.2.34 is what failed, fix its cause first (for example ownership, per memory *wms2-tenant-object-ownership-blocks-flyway*). The INSERTs restore writes in the meantime.
  - Reverting the six annotations is an equally valid rollback, because the grants are additive.
- **Image rollback (Critic L5, verified rather than assumed).** The tenant chain in `StartupFlywayMigrator` sets only `dataSource`, `locations`, `outOfOrder` and `baselineOnMigrate(false)`. It sets neither `ignoreMigrationPatterns` nor `validateOnMigrate`, so Flyway's defaults apply: `validateOnMigrate=true` and `ignoreMigrationPatterns=*:future`. The class javadoc and `db/migration/README.md` state the same.
  - So an older image booting against a tenant that has V2.2.35 applied sees it as a **future** migration, ignores it and validates cleanly.
  - That image's annotations re-gate on VIEW, so the extra function and grant rows are harmless.
  - AC-11 (§6.1) pins this by test.

### 5.2 Constant: `service/WmsConstants.java` (WEB_UI_ACTION block, after `WEB_UI_ACTION_PRINT_TOTE_LABELS`)

```java
/**
 * SBDEV-3606. Write authority on the web Replenishment screen: the six ReplenishOrderController writes
 * (create, cancel, priority, source edits). Deliberate exception to SBDEV-3017 §9.16 Option B.
 * Granted by V2.2.35 to every role that holds WEB_UI_VIEW_REPLENISHMENT_ORDER (derived, not listed),
 * and by initDB to receiving + super-admin. Does NOT govern the mobile /v3/replenish writes.
 */
public static final String WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER = "WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER";
```

- **Name.** `WEB_UI_ACTION_EDIT_REPLENISHMENT_ORDER` was the alternative. MANAGE is preferred because create and cancel are not edits.
- **Nothing depends on the `WEB_UI_ACTION` prefix (Critic L7).** Method: `git grep` at `origin/develop` of wms2-api, wms2-web-ui and wms2-mobile-ui for `startsWith('WEB_UI|MOBILE_UI`, `/^WEB_UI` and `LIKE 'WEB_UI`.
  - **Pattern control:** the same regexes do hit, but only as test assertions about audit-comment text: two `doesNotStartWith("WEB_UI_ACTION")` in wms2-api tests and one `/^WEB_UI_ACTION/` in a web-ui spec. There is also the comment-only V2.2.21 verification query.
  - **Corpus control:** `WEB_UI_ACTION_ADJUST_AMOUNT` appears in 14 api files and 5 web-ui files; `MOBILE_UI_VIEW_REPLENISHMENT` appears in 2 mobile files.
  - **Blind spot:** a prefix check spelled differently, such as `indexOf` or a substring. V2.2.21's comment "Expect 5 rows" becomes 7 (two new MANAGE grants) on a tenant with this grant. It is historical and left unedited.

### 5.3 Six annotations: `controller/ReplenishOrderController.java`

**Before (×6):**
```java
@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_REPLENISHMENT_ORDER)
```

**After (×6):** add one comment line above each existing `// SBDEV-3017 B2x…` block and keep that block unchanged, including the SDR caveat, "Mutating GET." and "Zero callers":
```java
// SBDEV-3606: a WRITE takes WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER, not the screen's VIEW function — Nam-decided exception to §9.16 Option B. Do NOT restore VIEW.
@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER)
```

- The five reads stay byte-identical.
- The gate has a single function: no ANY-of and no MOBILE member.

### 5.4 Migration: `V2.2.35__seed_replenishment_order_action_function.sql` (full text)

```sql
-- SBDEV-3606: split write authority out of WEB_UI_VIEW_REPLENISHMENT_ORDER for the six
-- ReplenishOrderController writes. The grant is DERIVED: every role holding the VIEW function gets
-- WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER, so holders(new) == holders(VIEW) on every tenant. No role
-- names, no role ids (they differ per tenant). V2.2.18 step-2 shape (NameKeyedGrantSeedRailTest-clean).
-- A PK / unique key on mywms_role_mywms_function is not guaranteed on every tenant (V2.2.00 declares
-- none), so: WHERE NOT EXISTS + SELECT DISTINCT, never ON CONFLICT (V2.2.18:45-49).
-- Statement 1 guards on name OR function because UNIQUE(function) is the table's only key; statement 2
-- keys on name because the gate (UserRepository.getAllRoles) compares f.name. They diverge only for a
-- pre-existing row whose name <> function (0 on every measured tenant); probe check 7 and AC-10 catch it.
-- Two statements, not a CTE, so statement 2 sees statement 1's row.

INSERT INTO mywms_function (id, version, client_id, name, number, function)
SELECT nextval('seqentities'), 0, 0, f.name, f.name, f.name
FROM (VALUES ('WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER')) AS f(name)
WHERE NOT EXISTS (SELECT 1 FROM mywms_function e WHERE e.function = f.name OR e.name = f.name);

INSERT INTO mywms_role_mywms_function (rolelist_id, functionlist_id)
SELECT DISTINCT rf.rolelist_id, act.id
FROM mywms_role_mywms_function rf
JOIN mywms_function vw ON vw.id = rf.functionlist_id AND vw.name = 'WEB_UI_VIEW_REPLENISHMENT_ORDER'
CROSS JOIN (SELECT id FROM mywms_function WHERE name = 'WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER') act
WHERE NOT EXISTS (SELECT 1 FROM mywms_role_mywms_function x
                  WHERE x.rolelist_id = rf.rolelist_id AND x.functionlist_id = act.id);
```

**F6: why the two statements are not keyed on one column.** Keying both on `name` would make statement 1 fail loudly with 23505 on `UNIQUE(function)` whenever a divergent row exists. That would freeze the tenant's whole migration chain. Keying both on `function` would grant to a row the gate never reads. The asymmetry is therefore deliberate. Probe check 7 catches a divergent row before PRD, and AC-10 catches it after.

**No change to `db/v1-to-v2-onboarding`**, following the V2.2.34 precedent.

### 5.5 initDB: `controller/rest/UtilRestController.java` (after the SBDEV-3381 block)

```java
// SBDEV-3606: web Replenishment write authority, same holders as WEB_UI_VIEW_REPLENISHMENT_ORDER
// (receiving + super-admin, granted above). Existing tenants get these rows from V2.2.35.
grantFunction(WmsConstants.FunctionEnum.WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER, role_receiving, role_super_admin);
```

`initDB` has zero callers (`UtilRestController` is a `@Service`). The line exists for convention and for AC-7.

### 5.6 Pin edits

**`FunctionGuardArchTest.REVIEWED_SHARED_GATE_FUNCTIONS`**
- Change the 6 `ReplenishOrderController#…/2` values to `Set.of(WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER)`.
- **Comment scope (Critic H1).** Only the two Replenishment lines, "All six ReplenishOrderController rows share one constant deliberately: they are one capability … six dialogs on one screen." (the two lines right after the `── SBDEV-3017 tranche 1 ·` header):
  - move them down so they sit directly above the six entries;
  - rewrite them as: "…one capability (supervisor replenishment maintenance) reached through six dialogs on one screen, so they share ONE action constant. SBDEV-3606 (Nam 2026-09-30) replaced the screen's VIEW function with WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER, granted by V2.2.35 to every VIEW holder: a deliberate exception to SBDEV-3017 §9.16 Option B. Do not revert to VIEW."
- **Leave these untouched:**
  - the "Screen constant, NOT WEB_UI_ACTION_PRINT_TOTE_LABELS … 7 LIVE users …" lines, which stay attached to `DashboardController#printToteLabels/2`;
  - `REVIEWED_SHARED_METHOD_GATES`.
- **Also changed in implementation (code-review L1, 2026-10-01):** the `.as()` label on `reviewedSharedGatesCarryTheirFullAnyOfSet` was rewritten to a generic drift label. It used to name `WEB_UI_VIEW_STOCK_UNIT` for every drift, which misdescribed M1–M6. Pre-existing, and fixed because this ticket relies on the message.

**`Sbdev3017TrancheGateContextTest`**
- Change the 6 write rows to the new name.
- `hasSize(227)` is unchanged, because the rows are edited in place.

**`audit-access-invariants.sql` SET 12 (added in implementation, security-review L-2):** a new operator query lists roles that hold MANAGE **without** VIEW, i.e. write authority on a screen the role cannot open. It is empty on day one by construction, and VIEW-without-MANAGE is intended and not reported. It uses `SELECT DISTINCT` and excludes connector roles, as SETs 2 and 3 do. No role list is involved, so it does not conflict with the SET 9 decision below. It was validated read-only on hydra nywh PRD, with a known-answer control query (MONITOR-without-ORDER → inventory-manager, outbound-manager).

**`audit-access-invariants.sql` SET 9:** no row is added. Its row shape takes an `ARRAY['role',…]` expectation, which would re-introduce the role list this migration avoids. Grant parity is checked by §6.4 instead (Critic L6).

### 5.7 Implementation steps

Work in the worktree `.claude/worktrees/wms2-api/SBDEV-3606`, branched off fresh `origin/develop`. Make each step an atomic commit.

1. **Write AC-6 first, then add the constant alone (§5.2).**
   - AC-6 looks the field up by reflection (`getDeclaredField("WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER")`, the same pattern as `declaresTheParcelPickingViewConstant`), so it compiles before the constant exists.
   - Run it and record the red: `NoSuchFieldException` naming the field.
   - Then add the constant. AC-6 goes green.
   - Adding the constant changes no behaviour: no annotation or seed references it yet, and `updateFunctionList` has no live caller.
   - Run the unit suite. Expect **green**. Only three tests reflect over `FunctionEnum`: `FunctionGuardArchTest` requires only that referenced values are declared, and the other two each target a single field.
2. **Edit the pins (§5.6) and write the remaining new tests (§6.1 AC-4, AC-5, AC-7..AC-11). Run them and record the reds in §6.3.** The expected reds, each naming its handler:
   - 6× `ReplenishOrderController#<m>/2 has [WEB_UI_VIEW_REPLENISHMENT_ORDER], expected [WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER]` from `reviewedSharedGatesCarryTheirFullAnyOfSet`;
   - 6× tranche rows reporting `expected WEB_UI_ACTION_MANAGE_… but was WEB_UI_VIEW_…`, one per path;
   - AC-4: 6 rows, each 200 instead of 403, one per path;
   - AC-5: 6 rows, each **403** with `X-Authz-Denied: WEB_UI_VIEW_REPLENISHMENT_ORDER`, because the handlers are still VIEW-gated. This red is correct and expected;
   - AC-7: the MANAGE role set is empty or null;
   - AC-8: 0 scripts found;
   - AC-9/AC-11: the "V2.2.35 exists" precondition fails.
   - A red for any other reason blocks step 3.
3. **Change the six annotations only (§5.3).** AC-1..AC-5 go green.
4. **Add V2.2.35 and the initDB line (§5.4, §5.5).** AC-7..AC-11 go green (AC-6 went green in step 1), and `NameKeyedGrantSeedRailTest` stays green.
5. **Back-references and docs (§9, §12).** Then run the full suite against the baseline, re-run the collision script, run the review lanes, and open the PR into `develop`.

---

## 6. Test Plan

### 6.1 Acceptance criteria

PIT cannot mutate annotations or SQL. Each mutation below is therefore a hand edit, which must produce a red whose message names the site. A red from an unrelated cause does not count.

| AC | Assertion | Test (class#method) | Mutation → attributable red |
|---|---|---|---|
| AC-1 | Each of the 6 writes resolves to exactly `{MANAGE}` | `FunctionGuardArchTest#reviewedSharedGatesCarryTheirFullAnyOfSet`; `Sbdev3017TrancheGateContextTest#everyTrancheRouteCarriesItsIntendedFunctions` | Revert `cancelReplenishOrder` to VIEW → `"…#cancelReplenishOrder/2 has [WEB_UI_VIEW_…], expected [WEB_UI_ACTION_MANAGE_…]"`. Widen to `{MANAGE, VIEW}` → same red (set equality). Delete the annotation → red on the empty set. |
| AC-2 | The 5 reads keep their sets | existing tranche read rows + the `getDetailView/9` entry | Move `/getPickableLocations` to MANAGE → its row reds, naming the path |
| AC-3 | No class-level gate | existing `FunctionGuardArchTest#noSharedControllerCarriesRequiresFunction` | Collapse to a class-level MANAGE → reds, naming the class |
| AC-4 | A VIEW-only principal gets **403** on each of the 6 writes, with body `reason=MISSING_FUNCTION`, `requiredFunction=WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`, and header `X-Authz-Denied: WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`. `verifyNoInteractions(replenishorderService)` applies to these six write rows only. The read control is a **separate** test, `…GateH2Test#viewOnly_isAllowedTheReadControl`: `/replenishorderDetailsById` returns no 403 and has no `X-Authz-Denied` header. It legitimately calls the service, so it makes no no-interaction assertion. | new `ReplenishOrderControllerGateH2Test#viewOnly_isDeniedWithManageNamed` (parameterised over the 6 writes; display name = path) | Revert one write to VIEW → its row gets no header and a non-403, and the display name names the path |
| AC-5 | A MANAGE-only principal gets **200** on each write, `X-Authz-Denied` is **absent**, and the handler's service method is invoked once (`verify(...)`). A 500 fails the row. | new `…GateH2Test#manageOnly_passesTheGate` | Change `/create` to `{VIEW}` → the `/create` row reds with a 403 and a header present |
| AC-6 | The constant exists and its value equals its field name | new `UtilRestControllerSeedUnitTest#declaresTheReplenishmentManageActionConstant` | A typo in the value → reds, showing both strings |
| AC-7 | initDB grants MANAGE to exactly the role set it grants VIEW to | new `…SeedUnitTest#initDB_grantsManageReplenishmentToTheSameRolesAsView` (`runInitDB()`, with its vacuity guard) | Drop `role_receiving` → reds, showing both sets |
| AC-8 | Exactly one comment-stripped `db/migration` script names `'WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER'`. It is `V2.2.35__…`, it sources `'WEB_UI_VIEW_REPLENISHMENT_ORDER'`, it contains `SELECT DISTINCT`, and it has no `mywms_role r` / `r.name IN` | new `…SeedUnitTest#manageReplenishmentMigration_derivesItsGrantFromTheViewFunction`; `NameKeyedGrantSeedRailTest` stays green | Rewrite the grant as `r.name IN (…)` → AC-8 reds **and** the rail reds |
| AC-9 | Migration derivation on Testcontainers (fixture below) | new `ReplenishmentOrderActionFunctionMigrationIT#grant_isDerivedFromView_perRole_andIdempotentOnAnUnkeyedTable` | Mutants: drop `DISTINCT` → receiving has 2 MANAGE rows. Grant to every role → `sbdev3606-no-view` gets 1. The natural form (`FROM mywms_role r CROSS JOIN (SELECT id FROM mywms_function WHERE name = '…')`) is **also** flagged by `NameKeyedGrantSeedRailTest`, through the `name = '…'` literal. Only a literal-free, id-keyed variant escapes the rail, and this IT's non-VIEW role is what kills that variant. Hardcode `rolelist_id IN (584,585)` → `sbdev3606-extra-view` gets 0. Drop `WHERE NOT EXISTS` → the count rises after the second apply. Targetless `ON CONFLICT DO NOTHING` → same, because the keys were dropped. |
| AC-10 | Post-deploy, per tenant: `2.2.35 success`; the VIEW and MANAGE role sets are equal both ways; users(MANAGE) = users(VIEW) | manual §6.4 SQL | — |
| AC-11 | **Image rollback.** After 2.2.35 is applied, the **real** `StartupFlywayMigrator` runs with 0 migrations applied and `Summary.failures() == 0`. It is built through its public constructor with a mocked `TenantDbConfigurationRepository` (`findByActiveTrue()` → one config pointing at the container) and an injected `FlywayExecutor`. The executor overrides **only** the locations: it no-ops the landlord leg, and otherwise runs `cfg.locations("filesystem:<tmp>").load().migrate()`, where `<tmp>` holds `db/migration` minus V2.2.35. Everything else in the chain is the production code. | same IT, `#olderImage_ignoresAnAppliedV2235AsFuture` | Control: the same run with an executor that also sets `.ignoreMigrationPatterns("*:missing")`, which drops the default `*:future`, must give `failures() == 1`. So a future `.ignoreMigrationPatterns(...)` or `.validateOnMigrate(...)` edit to the real chain reds this test. |

**AC-4/5 harness: new sibling `ReplenishOrderControllerGateH2Test extends BaseRepositoryIntegrationTest`**
- **Why a sibling class.** It uses a real context, with the real `FunctionGuardInterceptor`, plus `@MockitoBean AccessService` and `@MockitoBean ReplenishorderService`. With the service mocked, AC-5 writes nothing, and a handler that runs cannot be confused with a gate that passed. The existing `ReplenishOrderControllerH2Test` stays unchanged.
- **Access stub.** `checkAnyAccess(anyString(), any(String[].class))` uses `thenAnswer`. The answer walks **all** of `getArguments()[1..n]`, because Mockito expands varargs. It returns `allow()` if the principal's held set intersects those arguments, and otherwise `AccessDecision.deny(MISSING_FUNCTION, args[1])`, mirroring the real service.
- **Requests.** The body shapes come from the handlers' `reqMap` casts:

| Row | Request | AC-5 service verify |
|---|---|---|
| update | `POST /update` `{"id":1,"priority":1}` | `update(1L, null, 1)` |
| updateStockUnit | `POST /updateStockUnit` `{"id":1,"stockUnitId":2}` | `updateSourceStockUnit(1L, 2L)` |
| updatePriority | `POST /updatePriority` `{"id":1,"priority":1}` | `updatePriority(1L, 1)` |
| changeSourceStockUnit | `POST /changeSourceStockUnit` `{"id":1,"stockUnitId":2}` | `redirectSource(1L, 2L)` |
| cancelReplenishOrder | `GET /cancelReplenishOrder/{id}` against a seeded order. The handler reads the repository before calling the service. The seed pattern is the existing `cancelReplenishOrder` test. *(Corrected 2026-10-01: the base class now rolls tenant rows back (SBDEV-3242), so the earlier "this lane commits" note was stale; only the cancel rows seed an order.)* | `cancelReplenishmentOrder(argThat(o -> o.getId() == orderId))` |
| create | `POST /create` `{}` | `create(any())` |

**AC-9 fixture.** Keep the `migrateToUnderTest` precondition and the `dropUniquenessOnGrantTable` helper from `CancellationWaiveMigrationIT`.
1. Migrate to 2.2.34.
2. Call `dropUniquenessOnGrantTable` **before the first apply**.
3. Insert a **duplicate** (receiving, VIEW) row.
4. Create role `sbdev3606-extra-view` and grant it VIEW.
5. Create role `sbdev3606-no-view` with no VIEW.
6. Assert the positive controls: receiving has 2 VIEW rows, extra-view holds VIEW, and no-view does not.
7. Migrate to 2.2.35. Assert:
   - exactly 1 function row by name;
   - `SELECT rolelist_id, count(*) … WHERE functionlist_id = MANAGE GROUP BY 1` = exactly 1 row per VIEW role, with extra-view included;
   - no-view has 0 MANAGE rows;
   - the MANAGE role set equals the VIEW role set.
8. Apply the script a second time. The same counts must hold.

### 6.2 Suite gates

- Run `mvn test` and `mvn verify` in the worktree.
- Run the develop baseline close in time, with no concurrent Maven (memory *concurrent-maven-one-worktree-false-reds*).
- The only accepted diffs are the new tests. The two pin files are edited, not red.
- Rerun the known timing-flaky ITs before attributing a red.

### 6.3 Test execution (fill in during implementation)

| Command | Step | Result | Pass / Fail / Skipped |
|---|---|---|---|
| `mvn test` (unit suite) | 5.7-1 | 7538 run, 0 F, 0 E, 1 skip (after the constant, `96a0d930`→rebased `314fb1f8`) | Pass |
| `mvn test -Dtest=FunctionGuardArchTest,UtilRestControllerSeedUnitTest,Sbdev3017TrancheGateContextTest,ReplenishOrderControllerGateH2Test` (all surefire: pom excludes only `*IntegrationTest`/`*E2ETest`) | 5.7-2 / 3 / 4 | **Step 2:** 34 expected reds across 8 methods, each naming its handler/path/artefact (baseline in session scratchpad `SBDEV-3606-tdd-gate-baseline.md`). **Step 3:** only AC-7/AC-8 red. **Step 4 / tip `6a66c655`:** 68 run (6 classes incl. `ReplenishOrderControllerH2Test`, `NameKeyedGrantSeedRailTest`), 0 F/E | Pass |
| `mvn verify -Dit.test=ReplenishmentOrderActionFunctionMigrationIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` (failsafe `**/*IT.java`) | 5.7-2 / 4 | Step 2: both fail at the "V2.2.35 exists" precondition. Step 4 / tip: 2 run, 0 F/E | Pass |
| hand mutation per AC-1..AC-9, AC-11 | 5.7-4 | 13/13 required mutants killed, each with a message naming the site; follow-up assertions (AC-8 bare-table / hardcoded-id patterns, stub varargs self-test, read-control `verify(eq(VIEW))`, older-image V2.2.00 control) each mutation-checked red | Pass |
| `mvn verify` (full) vs develop baseline | 5.7-5 | Branch `1d07d690`: surefire 7589/0/0, failsafe 583 → 1 F + 2 E. Develop `652f37f7` same day: 7572/0/0, 581 → 5 F + 2 E. The branch's 3 reds (`CancellationReversalParcelSourceIntegrationTest` ×2, `SequenceTransactionServiceConcurrencyIT`) fail on develop too, with the same messages; they are order-dependent in a full local run and pass in isolation. The other 4 develop reds (`OrderReleaseSectionQueryIT`) were reused-container `seqentities` drift and passed after `docker rm -f`. Develop CI on `652f37f7`: green | Pass (no new reds) |

### 6.4 Manual test plan and AC-10

| Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| VIEW-only user is denied the writes | dev | Setup SQL below. Log in as the test user and open Replenishment. Try Create, then Cancel. | 403 with `requiredFunction=WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`, the standard 403 toast shows, and the list still loads. Then run teardown. | |
| super-admin happy path | dev | Create an order, change its priority, change its source SU, then cancel it | 200 each, and the state changes | |
| Grant parity (AC-10) | dev, UAT, 5 PRDs including WineCo | The parity SQL below | 0 / 0 EXCEPT rows; exactly 2 user-count rows with equal counts (a missing MANAGE row = FAIL); `success = t` | |

**Setup, dev only.** First create the user `sbdev3606.viewonly` via the Users screen (sb_admin); that creates both the Keycloak user and the `mywms_user` row. The user must be in no other group. Never modify the shared `receiving` or `super-admin` roles.
```sql
INSERT INTO mywms_role (id, version, name, number, description, connector)
  SELECT nextval('seqentities'), 0, 'sbdev3606-view-only', 'sbdev3606-view-only', 'SBDEV-3606 manual test', false;
INSERT INTO mywms_group (id, version, name, number, connector, client_id)
  SELECT nextval('seqentities'), 0, 'sbdev3606-view-only', 'sbdev3606-view-only', false, 0;
INSERT INTO mywms_role_mywms_function (rolelist_id, functionlist_id)
  SELECT r.id, f.id FROM mywms_role r, mywms_function f
  WHERE r.name = 'sbdev3606-view-only' AND f.name IN ('WEB_UI_VIEW_REPLENISHMENT_ORDER','WEB_UI_LOG_IN');
INSERT INTO mywms_group_mywms_role (grouplist_id, rolelist_id)
  SELECT g.id, r.id FROM mywms_group g, mywms_role r WHERE g.name = r.name AND r.name = 'sbdev3606-view-only';
INSERT INTO mywms_group_mywms_user (grouplist_id, userlist_id)
  SELECT g.id, u.id FROM mywms_group g, mywms_user u WHERE g.name = 'sbdev3606-view-only' AND u.name = 'sbdev3606.viewonly';
```

**Pre-login assertion.** The query must return exactly `WEB_UI_LOG_IN` and `WEB_UI_VIEW_REPLENISHMENT_ORDER`, and nothing else; otherwise stop. Without `WEB_UI_LOG_IN`, `pages/index.vue` bounces the user to `/not-authorized` before Replenishment is reachable.
```sql
SELECT DISTINCT f.name FROM mywms_user u
  JOIN mywms_group_mywms_user gu ON gu.userlist_id = u.id
  JOIN mywms_group_mywms_role gr ON gr.grouplist_id = gu.grouplist_id
  JOIN mywms_role_mywms_function rf ON rf.rolelist_id = gr.rolelist_id
  JOIN mywms_function f ON f.id = rf.functionlist_id
 WHERE u.name = 'sbdev3606.viewonly' ORDER BY 1;
```

**Teardown.** Afterwards, delete the user via the Users screen.
```sql
DELETE FROM mywms_group_mywms_user WHERE grouplist_id IN (SELECT id FROM mywms_group WHERE name = 'sbdev3606-view-only');
DELETE FROM mywms_group_mywms_role WHERE grouplist_id IN (SELECT id FROM mywms_group WHERE name = 'sbdev3606-view-only');
DELETE FROM mywms_role_mywms_function WHERE rolelist_id IN (SELECT id FROM mywms_role WHERE name = 'sbdev3606-view-only');
DELETE FROM mywms_group WHERE name = 'sbdev3606-view-only';
DELETE FROM mywms_role  WHERE name = 'sbdev3606-view-only';
```

**AC-10 parity, per tenant.** Paste as-is.
```sql
SELECT version, success FROM flyway_schema_history WHERE version = '2.2.35';                -- expect 1 row, t
WITH h AS (SELECT rf.rolelist_id, f.name FROM mywms_role_mywms_function rf JOIN mywms_function f ON f.id = rf.functionlist_id)
SELECT 'view_not_manage' AS side, rolelist_id FROM (
  SELECT rolelist_id FROM h WHERE name = 'WEB_UI_VIEW_REPLENISHMENT_ORDER'
  EXCEPT SELECT rolelist_id FROM h WHERE name = 'WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER') a
UNION ALL
SELECT 'manage_not_view', rolelist_id FROM (
  SELECT rolelist_id FROM h WHERE name = 'WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER'
  EXCEPT SELECT rolelist_id FROM h WHERE name = 'WEB_UI_VIEW_REPLENISHMENT_ORDER') b;   -- expect 0 rows
SELECT f.name, count(DISTINCT u.id) FROM mywms_user u
  JOIN mywms_group_mywms_user gu ON gu.userlist_id = u.id
  JOIN mywms_group_mywms_role gr ON gr.grouplist_id = gu.grouplist_id
  JOIN mywms_role_mywms_function rf ON rf.rolelist_id = gr.rolelist_id
  JOIN mywms_function f ON f.id = rf.functionlist_id
 WHERE f.name IN ('WEB_UI_VIEW_REPLENISHMENT_ORDER','WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER')
 GROUP BY f.name;   -- expect exactly 2 rows with equal counts; a missing MANAGE row = FAIL (no grant at all)
```

| Tenant | 2.2.35 success | EXCEPT rows | users VIEW / MANAGE | Checked by / date |
|---|---|---|---|---|
| dev / UAT ×n / hydra nywh / shipitez nywh / shipitez c1wh / WineCo | | | | |

**Deliberately skipped**
- `ReplenishOrderControllerUnitTest`: its `setupMockMvc` installs no interceptor.
- Web-UI Jest: there is no UI change on day one.

---

## 7. Horizontal Scalability and v2 Constraints

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | No | an annotation value and a constant only |
| 2 | Connection pool | No | the same single `getAllRoles` query per request |
| 3 | Scheduled jobs | No | `ReplenishOrderJobService` bypasses the gate and is unchanged |
| 4 | Long transactions | No | handler transactions unchanged; the migration is two small INSERTs per tenant |
| 5 | Request affinity | No | stateless gate |
| 6 | Retry / idempotency | Yes, handled | `WHERE NOT EXISTS` + `DISTINCT` (AC-9 on an unkeyed table) |
| 7 | Tenant context | No | request thread; Flyway runs per tenant datasource |
| 8 | Distributed lock | No | none added |
| 9 | Cache invalidation | No | `getAllRoles` has no `@Cacheable`; `CacheConfig` caches only sysprops, clients, locations and itemdata |
| 10 | External notification | No | no OMS or printer path |

| # | v2 constraint | Verdict |
|---|---|---|
| 1 | OSIV off | N/A. The gate runs before the handler. |
| 2 | Tenant tx manager | Unchanged |
| 3 | readOnly reads | Unchanged |
| 4 | Caffeine | N/A (row 9) |
| 5 | Micrometer | Nothing new. The deny path already logs `Denied {fn} on {Class}`, and the migrator publishes per-tenant stale gauges (unscraped: memory *wms2-metrics-exist-but-nothing-scrapes-them*). |
| 6 | Jakarta | N/A |
| 7 | H2-compatible SQL | The migration runs only in the Testcontainers IT, because the H2 lane has Flyway off |
| 8 | Controller test base | The real-context `BaseRepositoryIntegrationTest` sibling, because `setupMockMvc` installs no interceptor |

---

## 8. Risks & Mitigations

| # | Risk | Mitigation |
|---|---|---|
| R1 | **A tenant does not reach V2.2.35**, so every user there gets 403 on all 6 writes. This happens if V2.2.34 **or** V2.2.35 fails, there is no history table (`skippedNoHistory`), or the `db_url` is blank. Boot is never aborted, so the only sign is an ERROR or WARN line. | The §5.1.1 probe before promotion to `main` (Nam / devops). The pre-staged emergency INSERTs. An annotation revert as an alternative rollback. AC-10 parity after deploy. |
| R2 | **WineCo PRD is unmeasured.** | The derived grant covers it by construction. Probe, count and parity are owed there (§5.1 #9). |
| R3 | **The separation is incomplete.** `receiving` keeps mobile create and edit (§1), so revoking MANAGE does not make a role read-only. | Stated in the ADR, the constant's javadoc and the role-matrix row. P1 is ranked first. |
| R4 | **A future VIEW-only role** sees Create, Cancel, Priority and Source buttons that 403. | This is intended, and the standard 403 toast shows. P2 gates the buttons. |
| R5 | **Convention revert.** A later agent restores VIEW under §9.16 Option B. | The AC-1 pins, plus the §9 back-references. |
| R6 | **Migration version collision.** | Re-run the collision script immediately before merge. |
| R7 | **The grant is a snapshot.** A VIEW grant made later is not mirrored. | By design. Record it in the role matrix. |
| R8 | **Name/function divergence** (F6) leaves the grant silently empty. | Probe check 7 and AC-10. 0 divergent rows on every measured DB. |
| R9 | **GET `/cancelReplenishOrder/{id}` remains a mutating GET.** | Out of scope (SBDEV-3155). Exposure is unchanged, and the route now requires a stronger function. |

---

## 9. Acceptance & Implementation

**No verify script.** It is T3 opt-in only, and Nam declined it on 2026-09-30. All assertions are JUnit or IT (AC-1..AC-9, AC-11). AC-10 is manual SQL.

**Back-references**, written in the same PR and vault pass:
1. **`SBDEV-3017-B1-mvc-write-surface-gating.md` §9.16:** "Exception: ReplenishOrderController's 6 writes → `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER` (SBDEV-3606, Nam 2026-09-30)."
2. **Memory `~/.claude/projects/-Users-np1076-dev-spk-owl/memory/wms2-gate-a-route-on-its-screens-existing-function.md`:** add an exception note beside "Do not 'correct' this to an ACTION_ constant". Mirror it to `sbdocs/9-System/memory/` if a copy exists there.
3. **The six in-code comment lines** (§5.3).
4. **The rewritten Replenishment comment lines in `FunctionGuardArchTest`** (§5.6).

| Aspect | Value |
|---|---|
| Tier | T3 (authz + a PRD Flyway grant + a convention reversal) |
| Plan review | Architect → Critic, one ralplan round (done; see §13) |
| Implementation | `wms-tdd-gate`, then `ralph` via `wms-plan-executor`, following the §5.7 order |
| Verification | the floor: DB query done (§1); failing tests first, with reds recorded (§6.3); hand mutation per AC; independent review; full suite vs baseline. Plus the §5.1.1 probe and §6.4 parity. |
| Code review | 4 lanes, each of which writes a report file; never self-approve |
| Commit | git directly, in the §5.7 order |

---

## 10. Resolved Decisions and ADR

**Resolved (Nam, 2026-09-30); do not re-open.**
1. Scope: the 6 write handlers; the reads keep their gates.
2. One constant, `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`; EDIT was the noted alternative.
3. A derived grant: V2.2.18 step-2 INSERT…SELECT + `WHERE NOT EXISTS`, never `ON CONFLICT`, never joining `mywms_role` by name.
4. V2.2.35, with the collision script re-run before merge.
5. initDB: `grantFunction(NEW, role_receiving, role_super_admin)`.
6. No web-UI change on day one; button gating is a sub-T3 follow-up on this ticket.
7. An explicit exception to SBDEV-3017 §9.16 Option B, carrying the §9 back-references.
8. No verify script.

**ADR**

**Decision.** Gate the six `ReplenishOrderController` web writes with the new `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`.
- V2.2.35 seeds the function and grants it to every role that holds `WEB_UI_VIEW_REPLENISHMENT_ORDER`.
- initDB mirrors the grant.
- The reads do not change.

**Drivers.**
- A separate write function for the six web routes.
- Zero day-one access loss across 5 PRD tenants, one of them unmeasured.
- The rails pin the result.

**Alternatives considered.**
- D (grant by role name): trips the rail and is blind to tenant variance.
- F (six constants): too fine-grained for one capability.
- B (keep VIEW): is the defect.
- C (reuse an existing action): has the wrong meaning.
- E (class-level gate): is forbidden by the rail and would re-gate the reads.

**Why chosen.** A derived grant makes "nobody loses access" a property of the SQL rather than of a measurement that could not reach WineCo. A method-level annotation keeps every rail able to see the gate.

**Consequences.**
- Behaviour on day one is identical for every existing user.
- **MANAGE governs the six web Replenishment routes only.** Revoking it does **not** remove replenishment create (`POST /v3/replenish/requestAmount`, `MOBILE_UI_VIEW_REPLENISH_REQUEST`) or order edit (`PUT /v3/replenish/order/{id}`, `MOBILE_UI_VIEW_REPLENISHMENT`) from a role that holds those functions. On c1wh PRD that role is `receiving`.
- The separation is only as strong as the grant-administration path, and that path is closed:
  - `/v3/user/saveUserGroups` and `/v3/userRole/saveRoleFunctions` are GUARDED behind `WEB_UI_VIEW_USER_MANAGEMENT`. `UserController` and `UserRoleController` each carry a class-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` and are in `FunctionGuardInterceptor.GUARDED`.
  - The SDR access-chain hops 1, 2 and 4 are write-disabled.
- This controller now diverges from Option B, and the divergence is documented.
- A tenant that does not reach V2.2.35 gets 403 on all 6 writes until it is remediated.
- A VIEW-only grant made later produces visible buttons that 403 until P2 ships.

**Follow-ups.** P1 (mobile, ranked first), P2 (UI buttons, on this ticket), P3 and P4 (§11); the doc updates in §12.

---

## 11. Follow-ups / Proposals (not in scope)

P2 goes on this ticket, because it is sub-T3. P1, P3 and P4 are T3: they are **proposed, not filed**, and need Nam's confirmation.

| Rank | Item | Blast radius / cost |
|---|---|---|
| **P1 (first)** | **Mobile replenishment writes, using this ticket's pattern.** Add a `MOBILE_UI_ACTION_…` constant with a grant derived from `MOBILE_UI_VIEW_REPLENISH_REQUEST` / `MOBILE_UI_VIEW_REPLENISHMENT` (V2.2.18 step-2 shape), and method-level gates on `POST /requestAmount`, `PUT /order/{id}` and `POST /multi-unitloads`. | Closes the F1 gap: `receiving` holds both functions on c1wh PRD. Low risk and no new design. `PUT /order/{id}` overlaps SBDEV-3561 P9. |
| P2 (sub-T3, this ticket) | **Web-UI button gating.** A `canPerformAction`-style check in the replenishment `open/*` popups, mirroring `store/handlingUnits/stockUnits.js` (the `ACTION_FUNCTIONS` map, which fails closed while `!rootState.functionsLoaded`), plus MANAGE in `test/support/webFunctionConstants.js`. | One screen, about 5 components, with Jest tests. Closes R4. |
| P3 | **`CustomerOrderController /batchUpdatePriorityByOrderIds`** and the `CustomerorderBatchService` batch path write replenishorder priority under `WEB_UI_VIEW_ORDER`. | Crosses into the order screen's authz. |
| P4 | **A census of routes where a VIEW function gates a write.** About 60 POST/PUT/DELETE/PATCH handlers across 19 controllers (analysis §7); **not re-measured**. | A T3 programme. |

**P4 census method.** Enumerate `@RequiresFunction` handlers by reflection or ArchUnit, not by grep, and filter to non-GET verbs plus known mutating GETs.

**P4 blind spots.**
- Inherited `AdminController` mappings (it is the base class of 43 controllers).
- Mutating GETs.
- Service-level side-effect writes such as P3.
- `@Service` "controllers" that do not route.

---

## 12. Docs to update after the fix

| Doc | Change |
|---|---|
| `3-Resources/architecture/wms2-keycloak-role-matrix.md` | §3.7 row for MANAGE, worded: "governs the 6 web `/v3/replenishOrder` writes only; the mobile `/v3/replenish` create/edit routes stay under MOBILE_UI_VIEW_REPLENISH_REQUEST / MOBILE_UI_VIEW_REPLENISHMENT; revoking MANAGE does not make a role read-only (c1wh: receiving)". Also add MANAGE to the §4 `receiving` persona and check the §3.9.3 / §5 orphan lists. |
| `3-Resources/design/wms2-replenishment-design.md` §2 | Gate notes on the endpoint table; update the controller line count from 298 to 347. |
| `3-Resources/architecture/wms2-function-to-docs-map.md` §9 | A pointer from the Replenishment row to this plan. |
| `1-Projects/wms2/plan/SBDEV-3017-B1-mvc-write-surface-gating.md` §9.16 | The exception back-reference (§9 item 1). |
| `4-Archieves/wms2/plan/SBDEV-3561-change-source-stock-unit-state-guard.md` §10 P1 | "6 of the 11 uses were writes; they are re-gated by SBDEV-3606." |
| memory `wms2-gate-a-route-on-its-screens-existing-function.md` | The exception note (§9 item 2). |
| memory `wms2-access-chain-hops-1-2-writable-over-sdr.md` | Flag it as stale: hops 1, 2 and 4 are write-disabled (`RestConfiguration` `configureAccessChainMembershipWriteExposure`). |
| memory `wms2-function-gates-are-self-grantable-via-ungated-usercontroller.md` | Flag it as stale: `UserController` and `UserRoleController` are class-gated by `WEB_UI_VIEW_USER_MANAGEMENT` and are in `GUARDED` (`/saveUserGroups` also calls `denyUnlessUserManagementAllowed()`). |

---

## 13. Review round 1 disposition

| Finding | Change made | § |
|---|---|---|
| Architect F1 (High): mobile routes keep create/edit for `receiving` | Driver 1 and the ADR consequence are corrected, with the same wording in the §1 note, the javadoc and the role-matrix row; the mobile sibling is ranked P1 with the same pattern | §1, §3, §5.2, §10, §11, §12 |
| Critic H1 (High): the 7 users belong to Dashboard, and Option B was the putaway decision | Root cause rewritten; C rejected on meaning alone; §5.6 rewrites only the two Replenishment lines and leaves the Dashboard text untouched | §2, §3, §5.6 |
| Critic H2 / Architect F4: pins never seen red | Steps reordered to constant → pins + tests (reds recorded) → annotations → migration; the string-literal stub dropped | §5.7, §6.3 |
| Architect F2 / Critic M1 / L5: PRD trigger, owner, the .34 coupling, rollback | §5.1.1 probe SQL, owned by Nam/devops and run before promotion to main; landlord no-`db_url` query; no-history stop; pre-staged INSERTs; image rollback verified from the `StartupFlywayMigrator` chain and pinned by AC-11; R1 widened | §5.1, §5.1.1, §6.1, §8 |
| Architect F3 / Critic L2: DISTINCT and all-roles mutants survive | AC-9 fixture drops the keys before the first apply, seeds a duplicate VIEW row, an extra-view role and a no-view role; per-role counts asserted; mutants named | §6.1 |
| Architect F5 / Critic L1: false PK claim | Header now states the general rule ("not guaranteed on every tenant; V2.2.00 declares none") | §5.4 |
| Architect F6: name vs function lookup | Asymmetry kept deliberately, with the reason (the preferred same-column form would either freeze the chain on UNIQUE(function) or grant an unread row); caught by probe check 7 and AC-10 | §5.4, §5.1.1, §8 R8 |
| Architect F7 / Critic M2: AC-4/5 attribution and bodies | AC-4 asserts 403 + reason + requiredFunction + header + no service interaction; AC-5 asserts 200 + header absent + service verify; sibling class with a mocked service; per-handler bodies | §6.1 |
| Critic M3: manual revoke would break dev | Dedicated `sbdev3606-view-only` role, group and user, with setup and teardown SQL; Pass/Fail column added | §6.4 |
| Critic L3: AC-10 not pasteable | Literal EXCEPT-both-ways query + user count + history row, and a results table | §6.4 |
| Critic L4: template gaps | Test-execution table, V1/V2 line, priority "normal" | header, §6.3 |
| Critic L6: SET 9 row would re-list roles | Dropped, with a one-line reason | §5.6 |
| Critic L7: prefix claim covered one repo, no control | Scoped to three repos, with pattern and corpus positive controls and the blind spot stated | §5.2 |
| Critic open questions (self-grant; WineCo UAT) | One ADR sentence; WineCo retry added to prerequisites | §10, §5.1 #9 |
| Architect note: access-chain memory stale | Added to the docs list | §12 |

---

## 14. Review round 2 disposition

Critic: APPROVE. Architect: SOUND-WITH-CHANGES. F6 deviation accepted. Every one-edit fix is applied below; there is no redesign.

| # | Finding | Change made | § |
|---|---|---|---|
| 1 | Arch N1 / Critic M2: the manual-test user cannot log in | The setup grants `WEB_UI_VIEW_REPLENISHMENT_ORDER` and `WEB_UI_LOG_IN`; a pre-login assertion requires the held set to be exactly those two | §6.4 |
| 2 | Arch N2 / Critic M1: AC-5 missing from the step-2 reds | Added: 6 rows, 403 with `X-Authz-Denied: WEB_UI_VIEW_REPLENISHMENT_ORDER` | §5.7 step 2 |
| 3 | Arch N2 / Critic L4: AC-6 green by construction | AC-6 is written first as a reflection lookup, is seen red (`NoSuchFieldException`), and only then is the constant added | §5.7 step 1 |
| 4 | Arch N3: rail claim in AC-9 | Corrected: the rail does flag the natural `name =` all-roles mutant; only an id-keyed variant escapes, and the IT's non-VIEW role kills it | §6.1 AC-9 |
| 5 | Arch N4: check 7 over-match | `WHERE (name = X OR function = X) AND name IS DISTINCT FROM function` | §5.1.1 |
| 6 | Arch N5 / Critic L3: AC-11 mirrored the chain | Drives the real `StartupFlywayMigrator` via its `FlywayExecutor` seam, overriding locations only; blind spot removed; control asserts `failures() == 1` | §6.1 AC-11 |
| 7 | Arch N6: ADR self-grant sentence | Settled: grant administration is GUARDED behind `WEB_UI_VIEW_USER_MANAGEMENT`, and the SDR hops are write-disabled; the self-grant memory is added to the stale list | §10, §12 |
| 8 | Arch optional: `seqentities` USAGE | Probe check 4b, `has_sequence_privilege('public.seqentities','USAGE')` | §5.1.1 |
| 9 | Critic L1: AC-10 hides a missing MANAGE row | Annotated "exactly 2 rows with equal counts; a missing MANAGE row = FAIL" (in the SQL and the scenario row) | §6.4 |
| 10 | Critic L2: `verifyNoInteractions` vs the read control | The read control is its own test; the no-interaction assertion covers the six write rows only | §6.1 AC-4 |
| 11 | Critic L5: the single-IT command runs surefire | Added `-Dtest=ZzzNone` | §6.3 |

---

## 15. Implementation Status (2026-10-01)

**PR:** https://github.com/SiteBossInc/wms2-api/pull/438 (into `develop`, not merged) · branch `feature/SBDEV-3606-replenishment-write-function` · worktree `.claude/worktrees/wms2-api/SBDEV-3606` · base `origin/develop` `652f37f7`.

| Commit | Content |
|---|---|
| `314fb1f8` | Step 1: the constant, plus AC-6 (seen red with `NoSuchFieldException` first) |
| `c9012cab` | Step 3: six annotations, pin edits, `ReplenishOrderControllerGateH2Test` |
| `52329413` | Step 4: V2.2.35, the initDB line, AC-7/AC-8, `ReplenishmentOrderActionFunctionMigrationIT` |
| `7e91acf9` | Mutation-report F1–F4: AC-8 bare-table/hardcoded-id patterns, IT assertion order and hint, stub self-test, generic arch-test label |
| `1d07d690` | Code-review L2–L6 and security L-2: audit SET 12, cancel-row `argThat`, cancel-only seeding, read-control `verify(eq(VIEW))`, `@TempDir`, version-based control |
| `6a66c655` | Scoped-review Lows: SET 12 DISTINCT and connector filter, V2.2.00 lower-bound control, style |
| `c62d0916` | Whitespace only |

**Tests.** Test classes: `ReplenishOrderControllerGateH2Test` (new, 14), `ReplenishmentOrderActionFunctionMigrationIT` (new, 2), `UtilRestControllerSeedUnitTest` (+3), `FunctionGuardArchTest` and `Sbdev3017TrancheGateContextTest` (edited in place). The §6.3 table records the reds, the mutation results and the full-suite comparison.

**Review.**
- Conformance verifier: PASS, 17/17 VERIFIED.
- Code review: 0 High, 0 Medium; 13 Lows fixed across 3 passes.
- Security review: PASS. L-2 fixed. L-1 (RAISE on name/function divergence) was declined because it is strictly worse: the gate ships in the image, so an aborted tenant still 403s *and* freezes its migration chain. See the PR inline comment.

**Landmines found in implementation.**
- `check-migration-version-collision.sh` needs bash ≥ 4 (`declare -A`). On macOS's bash 3.2 it exits `FATAL: found ZERO migration versions`. It fails closed, as designed, but cannot be used on this laptop. The version was swept by hand across 357 refs.
- A reused Testcontainers container had `seqentities` in the reserved fixture band, so `OrderReleaseSectionQueryIT` went red locally. `docker rm -f` fixed it.
- `CancellationReversalParcelSourceIntegrationTest` and `SequenceTransactionServiceConcurrencyIT` are red on a full local `verify` on develop too. They are order-dependent and pass in isolation.

**Still owed:** the pre-PRD probe (§5.1.1), including WineCo PRD and landlord PRD (never measured); a collision re-run before merge; AC-10 per tenant after deploy; the sub-T3 web-UI button-gating follow-up and proposal P1 (mobile) on the ticket.

**Merged and on dev (2026-10-01).** PR #438 was merged into `develop` as `51849f1a` at 00:13 UTC. Develop CI passed both test and build. Dev reports `/api/public/version` = `develop-51849f1a…`. AC-10 holds on `dev_wh01_om1`, the only active dev tenant: 2.2.35 succeeded, the role sets are equal in both directions, and users(MANAGE) = users(VIEW) = 41. ClickUp is at `on dev`. Still owed at promotion: the §5.1.1 probe on UAT and PRD (WineCo PRD and landlord PRD have never been measured), AC-10 per UAT and PRD tenant, and the §6.4 manual click-path on dev.

## 16. Findings disposition at archival (2026-10-01)

| # | Open item | Disposition |
|---|---|---|
| 1 | Pre-PRD per-tenant probe (§5.1.1). WineCo PRD and landlord PRD were never measured | **Owner: Nam / devops**, at PRD promotion. Not machine-knowable from here |
| 2 | AC-10 parity per UAT and PRD tenant after deploy | **Owner: Nam / devops** |
| 3 | Live 403 for a user holding VIEW without MANAGE (§6.4) | **Dropped (dev).** No such user exists, because V2.2.35 grants MANAGE to every VIEW holder. Covered by `ReplenishOrderControllerGateH2Test`. Live allow (panderson) and live deny (sbtest, which holds neither function) were tested 2026-10-01 |
| 4 | P1: mobile `/v3/replenish` writes split (T3) | **Owner: Nam (decision)**. Proposed on SBDEV-3606; T3 items are never filed without Nam |
| 5 | Web-UI button gating (sub-T3) | **On a ticket: SBDEV-3620** |
| 6 | The wider ~60 VIEW-gated write handlers across 19 controllers (T3) | **Owner: Nam (decision)**. Proposed, not filed |
| 7 | `POST /create` with an unknown client returns 500 (pre-existing) | **On a ticket: SBDEV-3619** |
| 8 | Security L-1: RAISE on name/function divergence | **Dropped.** It freezes the tenant's migration chain *and* still 403s. Recorded in the PR #438 inline comment |
| 9 | `check-migration-version-collision.sh` needs bash ≥ 4 | **Dropped.** It fails closed (`FATAL: found ZERO migration versions`), and only the message misleads. Use a bash-4 shell, or sweep by hand as done here |
| 10 | Local-only order-dependent IT reds (`CancellationReversalParcelSourceIntegrationTest`, `SequenceTransactionServiceConcurrencyIT`) | **Dropped.** Pre-existing, identical on develop, and develop CI is green |

> Archived 2026-10-01: PR #438 merged into develop (`51849f1a`), verified on dev, ClickUp `on dev`. No verify script (declined at T3).
> Implementation worktree(s) removed 2026-10-01: wms2-api/SBDEV-3606
