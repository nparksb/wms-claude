---
title: SBDEV-3183 review — SdrMustStayOpenRailUnitTest (b12ff678)
type: review
ticket: SBDEV-3183
date: 2026-10-18
reviewer: code-reviewer lane (independent, read-only)
verdict: APPROVE with changes recommended (COMMENT)
---

# Review: `SdrMustStayOpenRailUnitTest` @ `b12ff678`

Scope: one test-only commit in wms2-api,
`src/test/java/net/aim_ai/wms/unit/security/SdrMustStayOpenRailUnitTest.java` (+123). The worktree is
detached at `b12ff678`, whose parent is `origin/develop` `944cc789`. No build was run, as the brief asked.

## Verdict: **COMMENT (approve-able). No HIGH or CRITICAL findings.**

The rail is correct for what it enforces. None of the 8 types is ruled on `origin/develop`, and PR #529 does not conflict with it. The OMS caller list is complete and correctly classified. The DB facts in the javadoc reproduce today.

There is one real completeness miss: the **mobile UI also reads `Client` over SDR** (`components/picking/pick.vue:252-254`). The type list is still right, because Client is already pinned through OMS. But the rail's caller string, the javadoc and the "6 OMS / 2 mobile" count all say otherwise. If the OMS identity is resolved later, the javadoc's own re-opening procedure would lead someone to delete Client and break mobile picking. Fix that before merge. Everything else is LOW.

## Findings

| ID | Sev | Conf | File | Evidence | Fix |
|---|---|---|---|---|---|
| F1 | MEDIUM | HIGH | `SdrMustStayOpenRailUnitTest.java:70-73, :101-102, :149` | wms2-mobile-ui `origin/develop` `f51dc6c` `components/picking/pick.vue:252-254`: `await this.$axios.$get(\n '/client/search/findByClNr?clNr=System')` in `created()` of the pick screen. `ClientRepository` exports `findByClNr` (`ClientRepository.java:25`), and `ClientController` (`/v3/client`) has no `/search/**` mapping, so this is an SDR read. The javadoc says the mobile UI reads only Section and Stockunit. Client's caller string names only OMS, and the guard message says "6 OMS readers, 2 mobile readers". The sweep missed this read because the literal is on the line after `$get(`. The javadoc's "Re-opening this decision" step tells the reader to delete an entry once its caller is resolved. Resolving OMS's identity would then remove Client and 403 every mobile picker's pick screen under ENFORCE_RULED. | Add `mobile components/picking/pick.vue: GET /client/search/findByClNr?clNr=System` to Client's caller string, add the read to the mobile bullet in the javadoc, and reword the count message (for example "8 types: 6 read by OMS, 3 read by mobile, Client by both"). Also record that the original sweep missed multi-line literal calls. |
| F2 | LOW | HIGH | `SdrMustStayOpenRailUnitTest.java:68-69` | The javadoc says `db/audit-access-invariants.sql` "forbids granting it any". The file forbids it only in a **comment** (`:521`). The G-3 query that enforces the rule filters on `u.name IN ('anonymous','anonymousUser')` (`:536`, `:546`), so a grant to `oms_integration` would **not** show up in the audit. Separately, the same comment calls `oms_integration` "unused", which contradicts V2.2.09, which seeds it as the return auto-receive operator (`V2.2.09__…sql:62-77`). | Reword to "a comment in `audit-access-invariants.sql` (SBDEV-3062) says not to grant it; G-3 does not check it". Optionally propose adding `'oms_integration'` to G-3's `IN` list on this ticket. That is a separate, small change, and it is in the main resources, not this test. |
| F3 | LOW | MEDIUM | `SdrMustStayOpenRailUnitTest.java:61-63` | The javadoc lists three OMS auth shapes: service account, passed-through user JWT, and none. `WmsApiService::applyAuthentication` (oms-laravel-api `59039e8c`, about `:3596-3700`) also has `basic` and `token` modes, plus a per-facility S2S service account (SBDEV-2765). The conclusion still holds, because every bearer identity resolves to some `preferred_username` with no `mywms_user` row. The list is just not exhaustive. | Say "for example" or list all five. Optional. |
| F4 | LOW | HIGH | `SdrMustStayOpenRailUnitTest.java:76-84` (blind spots) | OMS `config/wms.php` `printer_search_by_type` defaults to `rest/printer/findByType` (MVC/rest), but the comment beside it documents an env override to `v3/printer/search/findByType`, which is **SDR on Printer**. `PrinterRepository.java:24` exports `findByType`. Printer is not on the list. No tenant is known to use the override. | Add one sentence to the "What this cannot see" paragraph: a facility setting `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT` to the v3 form makes OMS an SDR reader of Printer. Printer should not get a rule without checking that env on every OMS deploy. Alternatively, propose removing the override from OMS. |
| F5 | LOW | HIGH | rail scope (whole class) | The rail pins the rule table only. Under `SdrGuardMode.FAIL_CLOSED` (`SdrGuardMode.java:76-77`), unruled types are denied too, so all 8 callers break whatever this rail says. The javadoc's "a rule would deny it … once the tenant enforces" is true for ENFORCE_RULED. It does not say that FAIL_CLOSED is equally fatal to these callers. | Add one line: "FAIL_CLOSED denies these regardless; this decision also means no tenant can reach FAIL_CLOSED until the callers are resolved." |
| F6 | LOW | HIGH | `SdrMustStayOpenRailUnitTest.java:142-151` | The vacuity guard catches an entry dropped **without** editing the count. Dropping an entry and changing `8` to `7` in the same edit passes. The comment says this is intended, and it is the normal limit of a frozen-count ratchet. `distinct()` makes the duplicate check meaningful. | No change needed. If you want it stronger, assert the exact set of 8 class names, so the reviewer sees the removed name in the diff and not only a number. |

## Evidence by brief question

### 1. Is the caller list complete and correct? Is anything ruled? Does it conflict with #529?

**OMS** (`oms-laravel-api` `origin/develop` = `59039e8c`, freshly fetched). I enumerated every `getWmsEndpoint('…')`, `getFromWms`, `readWithServiceIdentity` and `getWmsBaseUrl` call site in `app/`, plus `config/wms.php` (`:97-225`). The `v3/` paths classify as follows:

- **SDR (exported repository):**
  - `v3/client` (paged list), `v3/client/search/findByClNr`, PATCH `v3/client/{id}`: Client
  - `v3/itemdata`, `v3/itemdata/search/findByClientId`: Itemdata
  - `v3/shipperid`: Shipperid
  - `v3/boxtype`: Boxtype
  - `v3/customerorder/search/findByOrderbatchId` and `findByExternalIdList`: Customerorder
  - `v3/customerorderBatch/search/findByBatchid`: CustomerorderBatch

  All six types are on the list. The search paths exist as `@RestResource` on the matching repositories (`ClientRepository:25`, `ItemdataRepository:21`, `CustomerorderRepository:43,:57`, `CustomerorderBatchRepository:54`).
- **MVC (not SDR):**
  - `v3/client/create`: `ClientController` `/v3/client` + `@PostMapping("/create")`
  - `v3/shipperId/create`: `ShipperIdController` `/v3/shipperId`
  - `v3/boxType/create`: `BoxTypeController` `/v3/boxType`

  None of these controllers, and not `AdminController` (`/v3` + `/user/*`, `/admin/*`, `/groups/*`), shadows a listed SDR read. `ClientController` has no PATCH `/{id}` and no `/search/**`, so PATCH `v3/client/{id}` really is SDR.
- **Neither:** `rest/*` is the internal surface. The unprefixed `/transfer/complete`, `/inventory/update` and `/inventory/count` match no exported path. The exported paths are 69 repositories, and their `path=` values include no `transfer` or `inventory`. `inventoryRecord` is a different path.
- **Conditional SDR:** Printer, through the env override only (F4).
- **Verdict:** no OMS SDR path on a type outside the 8, and no listed path is actually MVC.

**Mobile** (`wms2-mobile-ui` `origin/develop` = `f51dc6c5`, freshly fetched). I grepped every string literal of the form `/<exported path>` or `/v3/<exported path>` across all 69 `path=` values, every `search/` and `_embedded` occurrence, and every `$axios.$get(<variable>)` or multi-line `$get(`. I excluded tests. Results:

- **SDR:**
  - `/section` and `/section/search/findByName` (`store/picking.js:239, :441`)
  - `/stockunit/search/getAmountAvailable` (`OrderHeaderBlock.vue:74`)
  - **`/client/search/findByClNr` (`pick.vue:252-254`), which the rail does not mention (F1)**
- **MVC look-alikes:**
  - `/unitLoad/search/findByItemForReplenish` (`UnitLoadController` `/v3/unitLoad` `:297`; the SDR path is lowercase `unitload`)
  - `/lookup/search/…` (`LookupController`)
  - `/user/getAllRoles`, `/user/isWmsUser`
  - `/replenishOrder/detailView` (the `url` variable in `pages/replenish.vue`)
- **Verdict:** no mobile SDR read on a type outside the 8. Client is a second, undocumented reason it stays on the list.

**Currently ruled on `origin/develop`?** `SdrFunctionRules.productionRules()` rules User, UserFunction, UserGroup, UserGroupUser, UserRole, Sysprop, Message and StockrecordView. `productionOverrides()` is `Map.of()`. **None of the 8 is ruled**, so the rail is green on develop.

**PR #529** (`origin/feature/SBDEV-3183-ac2-advice-cyclecount-location-rules` = `fd43e407`) adds rules on Advice, Cyclecount and Location. It adds overrides on `Location/findByGateTrue` and `Location/getAllCrossDockingLanes`. None of those types is in the 8. Neither OMS nor mobile reads `advice`, `cyclecount` or `location` over SDR (the grep above came back empty). The rail is a new file, so there is no textual conflict. **No conflict.**

### 2. Javadoc factual claims

- **V2.2.09 seeds `oms_integration`:** TRUE. `V2.2.09__seed_return_advice_auto_receive_sysprop.sql:62-77` inserts it into `mywms_user` with `WHERE NOT EXISTS`.
- **`audit-access-invariants.sql` forbids granting it:** PARTLY. A comment forbids it, but nothing enforces it (F2).
- **`AccessService` returns `USER_NOT_PROVISIONED` when there is no `mywms_user` row:** TRUE. `AccessService.checkAnyAccess:152-153` does this after the held-function check fails.
- **`JwtAccessTokenCustomizer` fallback:** the javadoc does not cite it. The underlying fact holds: the principal is `preferred_username`, falling back to `"service-account"` (`JwtAccessTokenCustomizer.java:35-36, :53`). So a `service-account%` pattern covers both the Keycloak `service-account-<client>` name and the fallback.
- **No `service-account-*` row and `oms_integration` holds 0 functions:** reproduced 2026-10-18 by this lane. The query covered `mywms_user` names `LIKE 'service-account%'` and `IN ('oms_integration','anonymous','anonymousUser')`, with function grants counted through group→role→function (the only path `getAllRoles` reads). Result: **0 service-account rows on all five** DBs (`dev_wh01_om1`, `wh01_hydra_v2`, `wh01_om1_v2`, `wh01_shipitez_v2`, `wh02_shipitez_v2`). `oms_integration` and `anonymous` exist on each with **0 grants**. The dev MCP dropped its first query (the known idle trap), and the retry succeeded.
- **Completeness claim:** the "What this cannot see" paragraph says the sweep's blind spot is variable-built URLs. The measured miss (F1) was a *literal* split across lines, so the stated blind spot is incomplete. F1's fix covers this.

### 3. Test quality

- `carriesNoTypeRule` reads `requiredFunctions(type)`. With a null `searchPath` that returns exactly `rules.get(type)` (`SdrFunctionRules:338-349`), so it cannot pass vacuously through the override branch.
- `carriesNoSearchOverride` filters `overrideKeys()` by class equality and asserts the result is empty. That is meaningful, because an override would gate a search even with no type rule. It is green today only because `productionOverrides()` is empty, and that is the right reason.
- Both tests build the production instance with `new SdrFunctionRules()`, the same no-argument constructor `@Component` uses. They do not use `forTesting`, so they test the shipped table.
- The domain classes are compile-time `Class` literals, so renaming an entity breaks compilation and the rail cannot silently go stale.
- The vacuity guard is meaningful against a silent drop and is guarded against duplicates. It has the normal frozen-count limit (F6).
- I could not find an assertion that passes for the wrong reason. The commit message reports three mutation kills (rule on Client, override on Customerorder/findByOrderbatchId, Shipperid dropped). This lane did not re-run them, because no build was allowed.

### 4. `MockitoTestConventionArchTest`

**Compliant.**
- Convention 1: the class has no `@MockitoSettings`, and `BaseUnitTest` carries only `@ExtendWith(MockitoExtension.class)`. No mocks are used.
- Convention 2: the name is `<Subject>UnitTest`, with no `SdrMustStayOpenRailTest` twin. Its subject also differs from `SdrFunctionRulesUnitTest`'s, because it uses the descriptive `MustStayOpenRail` lens that the convention allows.

## Positive observations

- The rail is keyed on `Class` literals, matching `SdrFunctionRules`' own reasoning, so a rename is a compile error and not a silent un-pin.
- It checks overrides as well as type rules. That is easy to miss, because overrides gate searches even on an unruled type.
- The assertion messages name the caller and the remedy, so a red test explains itself.
- The javadoc is honest about its own blind spots and pins both caller lists to commits.
