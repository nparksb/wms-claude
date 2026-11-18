---
title: "SBDEV-3668 — scope /v3/replenish/** (and the two shared lists the handheld reads) to the caller's client"
ticket: "SBDEV-3668"
ticket_url: "https://app.clickup.com/t/868me6983"
type: "bug"
priority: ""
status: "archived"
project: ["wms2-api"]
version: "v2"
requester: "Nam Park"
created: "2026-10-29"
updated: "2026-10-30"
revision: "r2 — ralplan round 1 folded in (Critic APPROVE 4M/7L, Architect SOUND-WITH-CHANGES 4M/6L); Nam: ArchUnit rail now"
tier: T3
db_verified: true
branch: "bugfix/SBDEV-3668-replenish-client-scoping"
related:
  - "[[wms2-replenish-workflow]]"
  - "[[wms2-multi-unitload-replenish]]"
  - "[[wms2-keycloak-role-matrix]]"
  - "[[proposals-register]]"
tags:
  - plan
---

# SBDEV-3668 — client scoping on the mobile replenishment surface

**Ticket:** [SBDEV-3668](https://app.clickup.com/t/868me6983) · **Tier:** T3 (authorization) · **Base:** `origin/develop` 219ad551 · **Branch:** `bugfix/SBDEV-3668-replenish-client-scoping`
**Inputs:** analysis `.omc/research/SBDEV-3668-analysis.md` ("AB §n"); RALPLAN-DR `.omc/research/SBDEV-3668-planner-r1.md`; reviews `SBDEV-3668-critic-r1.md`, `SBDEV-3668-architect-r1.md`.
Citations quote code on 219ad551; line numbers are hints. `MRS` = `service/mobile/MobileReplenishService.java`, `RC` = `controller/mobile/ReplenishController.java`, `CS` = `service/ClientService.java`, `VDS` = `service/ViewDtoService.java`.

---

## §0 Affected sites

**Method:** every `@*Mapping` in `RC` (12) and `DashboardController` read; `grep -rn "isSystemClient(\|getUserClient()\|getCallersClient()" src/main` (positive control: the known `getReservedOrder` site, `MRS` ~L484); handheld calls via `git grep '$get\|$post\|$put'` over wms2-mobile-ui `origin/develop` `store/replenish.js`, `pages/replenish*.vue`, `components/replenish/` (widened from AB §0 (d) after Arch L1). **Blind spots:** reflection/SpEL; body-carried ids in other mobile controllers.

| # | Site (quoted) | Construct | Scope |
|---|---|---|---|
| A1 | `MRS.loadOrderById` — `replenishorderRepository.findById(id)` | GET by id | **in** |
| A2 | `MRS.update` — `findByIdForUpdate(id).orElseThrow(() -> new FacadeException("MsgCannotReadOrder"))` | PUT `/order/{id}` | **in** |
| A3/A4 | `MRS.lockOrder` (only callers: `startOrder`, `heartbeatOrder`, `resetOrder`) — `return replenishorderRepository.findByIdForUpdate(id).orElseThrow(...)` | claim / heartbeat / release | **in** |
| A5 | `MRS.fulfillMultipleUnitLoadsTx` — `Replenishorder template = replenishorderRepository.findByIdForUpdate(request.getOrderId())` | finish; moves stock, creates children | **in** (template check only, §2) |
| A6 | `RC.orderList` — `clientRepository.findByClNr(clientNumber)` then `getCalculatedOrders(null, client.getId())` | caller-chosen client | **in** |
| A7 | `MRS.getCalculatedOrders` — `else if (clientService.isSystemClient(client)) res = ...WithClient(..., client.getId(), ...); else res = ...getCalculatedOrder(...)` | inverted branch | **in** |
| A8 | `MRS.getClientList` — `clientRepository.getClientList(WmsConstants.State.PROCESSABLE)` | every client with a 300 order | **in** |
| A9 | `MRS.loadOrderByDestination` — `getActiveByStateAndItemDataAndLocation(...)` then `setOrderToReplenishMobileOrder(orderDto, o)` | by location; mobile `/requestLocation` + web B3 | **in** |
| A10 | `MRS.requestReplenish` — `Client client = clientService.getByNumber(mOrder.getClientNumber());` | **creates** an order for a named client | **in** |
| B1 | `ReplenishOrderController.getDetailView` → `VDS.getReplenishOrderViewByKeyword` — query `(c.id = :clientId or :clientId = -1)` | handheld main list; web supervisor list | **in** (force own) |
| B2 | `DashboardController.replenishMonitorViewSummary` → `VDS.getReplenishMonitorViewSummary` — `dto.put("clientId", result.getClient_id());` | handheld Critical list; web monitor | **in** (post-filter) |
| B3 | `ReplenishOrderController.loadOrderByDestination` → `mobileReplenishService.loadOrderByDestination` | web | **in** (via A9) |
| A11 | `MRS.getReservedOrder` — `if (!clientService.isSystemClient(client)) { res = ...getReservedOrderWithClient(...)` | already scoped (operator + client) | no change |
| A12 | `RC.fixedLocationUpperBound/{locationId}` | location config scalar; ~~out — no order data~~ the 200-with-value vs 200-empty answer revealed another client's fixed assignment (security r1 L2) | **in** (Nam 2026-10-29): via `MRS.getFixedLocationUpperBound`; foreign == unassigned (`null`) |
| A13 | handheld `components/replenish/shared/OrderHeaderBlock.vue:74` → SDR `/stockunit/search/getAmountAvailable?locationId=&itemdataId=` | SDR search, caller-chosen item | **out → P31** (SDR) |
| A14 | handheld `store/replenish.js:283` → `/lookup/locationByLocationName/…` | location lookup | **out → P32** |
| B4/B5 | web `ReplenishOrderController` by-id reads/writes; SDR `/v3/replenishorder` item + collection reads | supervisor + SDR | **out → P31**. ⚠ B5 **bypasses the in-scope reads** (R6) |
| C1 | other mobile workflows (picking, cycle count, move stock, palletizing) | no client scoping anywhere | **out → P32**; cancellation is P11 |

`ReplenishmentMonitorViewRepository` is `@RepositoryRestResource(..., exported = false)` → no SDR bypass for B2. `Replenishorder` is in `RestConfiguration.SDR_WRITE_WITHDRAWN` (array from ~L452, entry ~L539) → no SDR **write** route; SDR **reads** stay open (R6).

---

## §1 Problem statement

A handheld user whose WMS user belongs to a non-System client can read, claim, release, re-source and finish **any** client's replenishment order by id, create orders for any client, and list every client's orders. The only existing scoping is `getReservedOrder` (A11). Origin: SBDEV-3626 security review L1.

**DB (DEV `dev_wh01_om1`, wms2-wineco-dev MCP, 2026-10-29):**
```sql
SELECT (SELECT count(*) FROM mywms_user) users,
       (SELECT count(*) FROM mywms_user u JOIN client c ON c.id=u.client_id WHERE c.cl_nr<>'System') nonsys_users,
       (SELECT count(*) FROM replenishorder WHERE state=300) open300,
       (SELECT count(DISTINCT client_id) FROM replenishorder WHERE state=300) open300_clients;
-- users=100, nonsys_users=0, open300=566, open300_clients=58
```
Plus: System client id 0; `replenishorder` spans 106 distinct `client_id`; `client_id` NOT NULL on both tables; `los_sysprop WMS2_SDR_READ_GUARD_MODE = 'SHADOW'` (allows; records would-denies). **Zero live exposure on DEV**; fix is pre-emptive (§10 D1). UAT/PRD unmeasured (MCPs down) → P-1.

---

## §2 Root cause

- **A1–A5:** every order-id handler loads the row and goes straight to state checks; nothing compares `order.getClientId()` with the caller's client. The gap is original (AB §10).
- **A5 batch:** one `orderId` per request; every unit load is bound to the template's item — `validateUnitLoadEntry`: `!Objects.equals(matching.getItemdataId(), template.getItemdataId())` → `MsgSourceStockNotFound`. Order client = item client at creation (`ReplenishGeneratorService` ~L286 `replenishOrder.setClientId(itemData.getClientId())`; children ~L337 `order.setClientId(template.getClientId())`). Two instruments for "`client_id` never changes after creation": (1) `grep "\.setClientId("` on `Replenishorder` in `src/main` → those two create sites only; (2) the SDR write surface is withdrawn (`SDR_WRITE_WITHDRAWN` includes `Replenishorder.class`), so no Jackson/SDR binding can rewrite it. Native SQL: `grep -rniE "update replenishorder " src/main/java` → 2 statements, neither sets `client_id` (same grep filtered on `client_id` → 0). Blind spot: SQL outside `src/main/java` (Flyway data fixes). So the template check covers the batch.
- **A7:** inverted branch (System → only System's; non-System → all). Dead in production (one caller, always non-null id), but A6 then trusts the caller-supplied id.
- **A6/A8:** caller-chosen `clientNumber`; `/clientList` offers every client.
- **A9/A10:** keyed by location / client number, no caller check.
- **B1/B2:** shared lists take `clientId` as an optional filter, never the caller's identity.

---

## §3 Principles, drivers, options (full RALPLAN-DR in `.omc/research/SBDEV-3668-planner-r1.md`)

**Principles:** (1) a refusal is byte-identical to not-found on the same endpoint — no existence or state oracle **through these MVC endpoints** (SDR reads excepted until P31, R6); (2) gate → scope → state; (3) the order's row lock stays its first touch (SBDEV-3244); (4) one predicate, one home, for by-id **and** list sites; (5) System callers unchanged.
**Drivers:** no handheld change; no new lock/stale-entity hazard; reusable by P31/P32.
**Chosen:** `ClientService.callerScopeClient()` + `isVisibleToCaller(Long)` (Architect synthesis, adapted), checked **after** the existing lock, pinned by an ArchUnit rail. Rejected: controller/aspect guard; check-before-lock via plain `findById` (lock-upgrade `StaleObjectStateException`, `ReplenishorderRepository` SBDEV-3244 comment); check-before-lock via scalar `findClientIdById` (see ADR); B1/B2 refuse-foreign (Nam chose force-own).

---

## §4 Architecture

```
handheld / web ──► FunctionGuard (@RequiresFunction, unchanged) ──► controller ──► service
   RC: loadOrderById, PUT /order/{id}, /order/{id}/start|reset, /multi-unitloads,
       /requestLocation, /requestAmount, /clientList, /clientOrderList/{clNr}  ──► MobileReplenishService
   ReplenishOrderController: /detailView, /loadOrderByDestination              ──► ViewDtoService / MRS
   DashboardController: /replenishMonitorViewSummary                           ──► ViewDtoService
                                                                                     │
   by-id sites: lock/read row ──► ClientService.isVisibleToCaller(owner) ── false → endpoint's own not-found
   list sites:  ClientService.callerScopeClient() ── empty = System (all) / present = narrow to own
   ReplenishClientScopeArchTest: every MRS/VDS method that reads a replenish source calls one of the two
```

| File | Role |
|---|---|
| `service/ClientService.java` (120 lines) | `callerScopeClient()`, `isVisibleToCaller(Long)` beside `getUserClient` / `isSystemClient` |
| `service/mobile/MobileReplenishService.java` (1275) | A1–A10 call sites |
| `controller/mobile/ReplenishController.java` (288) | A6 delegates the cl_nr lookup to the service |
| `service/ViewDtoService.java` (1580) | B1, B2 |
| `test/.../unit/config/ReplenishClientScopeArchTest.java` (new) | the rail |

---

## §5 Fix design

### Predicate (one home, two entry points)
```java
// ClientService — SBDEV-3668
/** The client a caller is confined to; EMPTY means a System-client caller, who sees every client.
 *  Fails closed (EntityNotFoundException) for the anonymous sentinel, a login with no WMS user, and a user
 *  whose client row is missing — never reads any of those as System. */
public Optional<Client> callerScopeClient() {
    if (SecurityContextUtils.ANONYMOUS.equals(SecurityContextUtils.getUserName())) {
        throw new EntityNotFoundException("No authenticated WMS user");
    }
    Client caller = getUserClient().orElseThrow(() -> new EntityNotFoundException("Client not found for current user"));
    return isSystemClient(caller) ? Optional.empty() : Optional.of(caller);
}

/** True when the caller may see an object owned by {@code ownerClientId}. Same fail-closed rules. */
public boolean isVisibleToCaller(Long ownerClientId) {
    return callerScopeClient().map(own -> own.getId().equals(ownerClientId)).orElse(true);
}
```
- Returns `Optional<Client>`, not the Architect's `Optional<Long>`: B2 compares **cl_nr** (§5 Fix D), so the list sites need the whole row.
- **Anonymous fails closed (decided, §10 D5).** `getUserName()` returns `"anonymous"` when there is no recognised principal, and `V2.2.00` seeds `mywms_user 'anonymous'` on client 0 in every tenant DB, so without this guard an unauthenticated call would resolve to System. This mirrors `MRS.currentUser()` (`if (name == null || SecurityContextUtils.ANONYMOUS.equals(name)) throw ...`). **Production paths that run as anonymous: none.** Method: (1) every caller of the touched methods is `RC` (`/v3/replenish`), `ReplenishOrderController` (`/v3/replenishOrder`) or `DashboardController` (`/v3/dashboard`) (grep of `mobileReplenishService\.` and the two VDS method names across `src/main`); (2) `SecurityConfiguration` `permitAll` covers `/`, `/v3`, `/v3/token`, `/error`, `/rest/**`, `/api/**`, `/api-docs/**`, `/swagger-ui/**`, `/api/public/**`, actuator health/info, none of which maps to those three controllers; everything else is `.anyRequest().authenticated()`; (3) no `@Scheduled` or job class calls them. Blind spot: reflection. **Test paths that run as anonymous: 6 classes** (§8 churn list).
- `.equals` on boxed `Long`; System by `cl_nr` (`isSystemClient`), never `id == 0`; `orElseThrow`, never `get()` (OptionalSafetyArchTest). No new dependency: `ClientService` already holds `userRepository`, `clientRepository`. Not `@Transactional`; joins the caller's tenant tx.
- **Identity axis (pre-existing, R9):** the predicate keys on `getUserName()` (JWT `preferred_username`, else `sub`); the gate keys on `getAuthorizedName()`. Same as `currentUser()` today.

### Fix A — by-id paths (A1–A5): right after the load/lock, before any state check
| Site | After |
|---|---|
| A1 `loadOrderById` | after `if (!orderOpt.isPresent()) return null;` → `if (!clientService.isVisibleToCaller(orderOpt.get().getClientId())) return null;` → 200 empty body |
| A3/A4 `lockOrder` | `Replenishorder order = ...findByIdForUpdate(id).orElseThrow(...); if (!clientService.isVisibleToCaller(order.getClientId())) throw new FacadeException("MsgCannotReadOrder"); return order;` → `claimRefusal` → 404 `properties.code=MsgCannotReadOrder`, same as a missing id, for start, heartbeat and reset |
| A2 `update` | same two lines right after the lock, before `Integer state = order.getState();` → 200 `{errors:[{message:"Order not found"}]}` |
| A5 `fulfillMultipleUnitLoadsTx` | same, right after the template lock, before `REPLENISH_ALREADY_FINISHED` / `REPLENISH_RESERVED` → envelope as for a missing id; post-commit recalc never runs (Tx throws first) |

Never `EntityNotFoundException` from the object check on A3/A4 (maps to `code:"ENTITY_NOT_FOUND"`, distinguishable). A **caller**-level failure (no user, anonymous) does throw ENFE from the predicate; that is not an object oracle (R4).

### Fix B — A6/A7/A8 lists
- **A7** `getCalculatedOrders(code, clientId)`: replace the `getUserClient()` line and the 3-way branch with `Optional<Client> scope = clientService.callerScopeClient();` then: scope empty → `clientId != null ? WithClient(clientId) : getCalculatedOrder(all)`; scope present → `Long own = scope.map(Client::getId).orElseThrow(); if (clientId != null && !clientId.equals(own)) throw new EntityNotFoundException("Client", clientId); res = WithClient(own);`. System + null now means **all** clients (was System-only); no production caller passes null.
- **A6** new `MRS.getCalculatedOrdersByClientNumber(String clientNumber)`: `Client client = clientRepository.findByClNr(clientNumber).filter(c -> clientService.isVisibleToCaller(c.getId())).orElseThrow(() -> new EntityNotFoundException("Client not found by clNr: " + clientNumber)); return getCalculatedOrders(null, client.getId());` — one `orElseThrow` for unknown and foreign. `RC.orderList` calls it; `clientRepository` (only use `RC` ~L175) leaves `RC`'s constructor.
- **A8** `getClientList`: `return clientService.callerScopeClient().map(own -> resultList.stream().filter(c -> own.getId().equals(c.getId())).toList()).orElse(resultList);`

### Fix C — A9/A10 (REQUEST gate)
- **A9** `loadOrderByDestination`: **directly after `fix` resolves** (before the active-order query), `Itemdata item = itemdataService.getById(fix.getItemdataId()); if (!clientService.isVisibleToCaller(item.getClientId())) throw new FacadeException("NOT_A_FIXED_ASSIGNED_LOCATION", new Object[]{});` — same ctor as the no-FLA throw; reuse `item` in the later `setItemToReplenishMobileOrder`. A foreign request never reads the order. Side effect: a dangling FLA item now answers `EntityNotFoundException("ItemData", id)` (404 global) instead of the order-state message; DEV has FK `fkdafqhoda5j7d33nk970ra1y16 FOREIGN KEY (itemdata_id) REFERENCES itemdata(id)`, so unreachable there (R10). Covers B3.
- **A10** `requestReplenish`: after `if (client == null) throw new EntityNotFoundException("Client", mOrder.getClientNumber());` add `if (!clientService.isVisibleToCaller(client.getId()))` throwing the same exception → identical envelope "Client not found: X"; `calculateOrder` never called.

### Fix D — B1/B2 (Nam: force own client; web non-System users included)
`ViewDtoService` gains a `ClientService` constructor parameter.
- **B1** after `cId` is computed: `cId = clientService.callerScopeClient().map(Client::getId).orElse(cId);`
- **B2** resolve `Optional<Client> scope = clientService.callerScopeClient();` once before the stream, then keep rows where `scope.map(own -> own.getClNr().equals(r.getClient_id())).orElse(true)`. ⚠ The projection's `client_id` is the **cl_nr** (`ReplenishmentMonitorViewRepository` ~L57 `c.cl_nr AS client_id`; the handheld uses it as `clientNumber: item.clientId`).

Mobile UI: no change.

### Fix E — ArchUnit rail (Nam, 2026-10-29: add now)
New `unit/config/ReplenishClientScopeArchTest`, modelled on `ReplenHoldPolicyCallerArchTest` (imported production classes + fixture-based positive control).
- **Scanned classes:** `MobileReplenishService`, `ViewDtoService`.
- **Sources:** `ReplenishorderRepository.{findById, findByIdForUpdate, getActiveByStateAndItemDataAndLocation, getCalculatedOrder, getCalculatedOrderWithClient, getOpenViewByKeyword, getClosedViewByKeyword}`, `ClientRepository.getClientList`, `ReplenishmentMonitorViewRepository.getReplenishViewSummary`, `ClientService.getByNumber`. **As built (`b9eaa219`): 12 methods over 5 types** — review added `ClientRepository.findByClNr` (A6, CR r1 L9) and `FixLocationAssignmentRepository.findByAssignedlocationId` (A12).
- **Rule:** every scanned method that calls a source also calls `ClientService.isVisibleToCaller` or `ClientService.callerScopeClient` directly. **Allowlist (1):** `MRS.readReplenishOrder` — private, reached only from `finishReplenishmentOrderWithoutRefill` inside `fulfillMultipleUnitLoadsTx`, with an id the service built from the already-checked, locked template or its child. **As built: 5 entries**, each private with its reason in the test javadoc — `readReplenishOrder`, `finishReplenishmentOrderWithoutRefill`, `assignDestinationForMultiUnitLoads` (reads a caller-chosen location's FLA; its "different fixed assignment" refusal is the P32 residue), `calculatedOrders` (A6/A7 helper, scope passed in), `readAddOn` (scope passed in; hides a foreign FLA bound, CR r2 M1).
- **Non-vacuity on the SCANNED set:** the set of scanned methods that call a source must contain all of `EXPECTED_READERS` — planned as 11 (`loadOrderById, lockOrder, update, fulfillMultipleUnitLoadsTx, getCalculatedOrders, getClientList, loadOrderByDestination, requestReplenish, readReplenishOrder, getReplenishOrderViewByKeyword, getReplenishMonitorViewSummary`); **as built 14**: `update` and `fulfillMultipleUnitLoadsTx` left (they lock through `lockOrder`, CR r1 L4), `getCalculatedOrders` became `calculatedOrders` + `getCalculatedOrdersByClientNumber`, and `getFixedLocationUpperBound`, `finishReplenishmentOrderWithoutRefill`, `assignDestinationForMultiUnitLoads`, `readAddOn` joined. A renamed source or a moved call empties nothing silently.
- **Positive control:** a nested fixture (`class Leaky { ReplenishorderRepository r; Object m(Long id) { return r.findById(id); } }` and a compliant twin calling `isVisibleToCaller`) imported with `ClassFileImporter`; the rule must report `Leaky.m` and not the twin.
- P31/P32 widen the scanned classes and sources later.

---

## §6 File change summary

| File | Change | ~Lines |
|---|---|---|
| `service/ClientService.java` | `callerScopeClient`, `isVisibleToCaller` | +14 |
| `service/mobile/MobileReplenishService.java` | A1, lockOrder, A2, A5, A7 rewrite, A6 new method, A8, A9, A10 | +35 / −8 |
| `controller/mobile/ReplenishController.java` | `orderList` delegates; drop `clientRepository` field + ctor param | +2 / −6 |
| `service/ViewDtoService.java` | ctor param; B1; B2 | +10 |
| tests | §8, incl. ctor sites `ReplenishControllerUnitTest` L68 + L515; `FunctionGuardMockMvcUnitTest` uses reflective `instantiate` (unaffected) | — |
| docs | `wms2-replenish-workflow.md` "Client scoping" note that **separates** scoped writes (A2–A5, A10: closed — SDR writes withdrawn) from scoped MVC reads (A1, A6–A9, B1–B3: closed on MVC only; SDR `/v3/replenishorder` reads open until P31); `wms2-keycloak-role-matrix.md` (functions are coarse; object scoping exists only on these replenish routes); `wms2-function-to-docs-map.md` §9 Replenishment row | — |

---

## §7 Implementation steps

### §5.1 Prerequisites
| # | Prerequisite | Blocking? | Owner |
|---|---|---|---|
| P-1 | Re-measure on UAT/PRD: the §1 `nonsys_users` query **and** `SELECT sysvalue FROM los_sysprop WHERE syskey='WMS2_SDR_READ_GUARD_MODE'` (DEV: SHADOW). Record on the ticket | **No** for this deploy (pre-emptive) | executor / Nam |
| P-2 | `ticket-lease.sh claim SBDEV-3668`; worktree `.claude/worktrees/wms2-api/SBDEV-3668` off fresh `origin/develop` | yes | tdd-gate |
| P-3 | Full-suite baseline on the fresh base, recorded | yes | tdd-gate |
| P-4 | The 6 anonymous-path test classes (§8 churn) seeded with a **named System user** and wrapped in `runAs` | yes (they go red otherwise) | tdd-gate |
| P-5 | **P31 lands before any non-System user is onboarded on any tenant** — SDR `/v3/replenishorder` reads bypass A1/A6–A8/B1/B2 until then (R6). Not a blocker for deploying this ticket | onboarding gate | Nam |

### Steps
1. **Tests first** (tdd-gate): §8 unit + controller + IT + rail, red for the right reason; the churn fixes land in the same commit, each noted; the 3 inverted `GetCalculatedOrders` tests flipped deliberately with a commit note.
2. **Predicate + by-id sites** (Fix A) → AC-1..5, AC-14, AC-17.
3. **Lists** (Fix B) → AC-6..8.
4. **REQUEST paths** (Fix C) → AC-9, AC-10.
5. **Shared lists** (Fix D) → AC-11, AC-12.
6. **Rail** green (AC-16); AC-13 pins; full suite vs baseline; PIT + manual mutation (§8); docs; 4 review lanes.

**Rollback:** single revert; no schema, no data.

---

## §8 Testing plan

### Churn — existing tests this change turns red (fix them in step 1, before judging any red)
Method: `grep -rlE "mobileReplenishService\.(loadOrderById|update|startOrder|heartbeatOrder|resetOrder|fulfillMultipleUnitLoads(Tx)?|getClientList|getCalculatedOrders|loadOrderByDestination|requestReplenish)\(|(viewDtoService|dtoViewService)\.(getReplenishOrderViewByKeyword|getReplenishMonitorViewSummary)\(" src/test` → 13 classes, then each class's base, Flyway status and security setup. Blind spot: callers through other beans; the tdd-gate's first full run is the second instrument.

| # | Test | Why red | Fix |
|---|---|---|---|
| C1 | `MobileReplenishServiceUnitTest` (all by-id tests) | mocked `boolean isVisibleToCaller` defaults to **false** → every by-id call refuses | outer `@BeforeEach` (~L136): `lenient().when(clientService.isVisibleToCaller(any())).thenReturn(true);` and, explicitly, `lenient().when(clientService.callerScopeClient()).thenReturn(Optional.empty());` (an unstubbed `Optional` already defaults to empty = System; stub it anyway so the intent is visible) |
| C2 | `MobileReplenishServiceUnitTest.GetClientList` (2 tests, ~L612-650) | A8 now calls `callerScopeClient()` | covered by C1's System default; no per-test stub needed |
| C3 | `MobileReplenishServiceUnitTest#throwsWhenOrderAlreadyStartedForLoadByDestination` (~L812) | A9 moves `itemdataService.getById(10L)` up; unstubbed → `null` → NPE | stub `getById(10L)` with an item; tighten `.isInstanceOf(FacadeException.class)` to key `MsgReplenishAlreadyStarted`; AC-9 reuses the fixture |
| C4 | `MobileReplenishServiceUnitTest.GetCalculatedOrders` — `shouldReturnOrdersForSystemClient`, `shouldReturnOrdersWithSearchKeyword`, `shouldReturnEmptyListWhenNoOrdersFound` | they assert the inverted branch | **flip, not delete** (AC-6); `shouldReturnOrdersForSpecificClient` passes by the coincidence `client.setId(2L)` — stub scope explicitly |
| C5 | `ViewDtoServiceUnitTest` (`@InjectMocks` ~L127) | new ctor param → `null` → NPE | `@Mock ClientService` + lenient `callerScopeClient()` → empty |
| C6 | `ReplenishControllerUnitTest` ctor sites L68 and L515, `clientOrderList` stub ~L230 | `clientRepository` leaves `RC`'s ctor | drop the arg; re-stub `getCalculatedOrdersByClientNumber` |
| C7 | `MobileReplenishServiceH2Test#loadOrderById` | H2 profile: `ddl-auto=create-drop`, `spring.flyway.enabled=false` (`application-integration.properties` L38/L51) → no `anonymous`, no `System` client; and anonymous now fails closed anyway | seed a `client` with `cl_nr='System'` + a named user on it; `runAs` that user. **Not** `@MockitoBean ClientService` (it would stub the predicate under test) |
| C8 | `MobileReplenishServiceIntegrationTest#fulfillMultipleUnitLoads_success` (H2, `extends BaseIntegrationTest`) | same as C7 | same as C7 |
| C9–C12 | Postgres ITs calling as anonymous: `TransferStockReplenHoldGuardIT`, `MobileReplenishMultiUnitLoadIT`, `MobileReplenishSourceScanIT`, `ReplenishorderRedirectSourceIT` | anonymous now fails closed | seed `mywms_user ('sbdev3668-sys', client_id 0) ON CONFLICT DO NOTHING` (System client 0 exists from `V2.2.00`), wrap calls in `runAs`. `ReplenishClaimIT` and `ReplenishOrderJobClaimIT` already run named users on client 0 — unaffected |

### Unit — `MobileReplenishServiceUnitTest`, new `@Nested ClientScoping`
Stub `isVisibleToCaller(<orderClientId>)` → false per test. **Every write path pins "scope before state"** by building the foreign order in a state whose own refusal would differ, and asserting the key `MsgCannotReadOrder`:
- `loadOrderById_returnsNull_whenForeign` / `_returnsOrder_whenOwn` (AC-1)
- `update_refusesMsgCannotReadOrder_whenForeign_{finished700, startedByOther}` — not the BusinessException naming the number (AC-2)
- `startOrder_refusesMsgCannotReadOrder_whenForeign_{finished700 (not REPLENISH_ALREADY_FINISHED), startedByOther (not REPLENISH_RESERVED)}`; `heartbeatOrder_..._whenForeign_startedByOther` (not `REPLENISH_CLAIM_LOST`); `resetOrder_..._whenForeign_{finished700, startedByOther}`; each `verify(replenishorderRepository, never()).save(any(Replenishorder.class))` — typed `any(Class)` (Mockito `never()` + bare `any()` trap) (AC-3)
- `fulfillMultipleUnitLoadsTx_refusesMsgCannotReadOrder_whenTemplateForeign_{finished700, startedByOther}` + `verify(stockunitRepository, never()).findByIdForUpdate(anyLong())`, `verify(replenishGeneratorService, never()).createOrderFromTemplate(any(), any())` (AC-4)
- `loadOrderByDestination_refusesNotFixedAssigned_whenItemForeign_evenWhenOrderStarted` + `verify(replenishorderRepository, never()).getActiveByStateAndItemDataAndLocation(anyInt(), anyLong(), anyLong())` (AC-9); `requestReplenish_throwsClientNotFound_whenForeign_andNeverCalculates` (AC-10)
- `GetCalculatedOrders` (AC-6): System+null→`getCalculatedOrder`, System+id→`WithClient(id)`, nonSystem+null→`WithClient(own)`, nonSystem+own→own, nonSystem+foreign→`EntityNotFoundException`
- `getCalculatedOrdersByClientNumber_unknownAndForeign_throwIdenticalMessage` (AC-7); `GetClientList#nonSystem_returnsOnlyOwn` (AC-8)

### Unit — others
- **`ClientServiceUnitTest`** `CallerScope` (AC-14): System → empty and `isVisibleToCaller(foreign)` true; own → true; foreign → false; **`anonymous` → `EntityNotFoundException` even though a seeded `anonymous` user on System exists in the mock**; no client row → ENFE; a System client whose id is **not** 0 → still empty.
- **`ViewDtoServiceUnitTest`** (AC-11, AC-12): `detailView_nonSystem_forcesOwnClientId_ignoringParam` (capture `cId` to `getOpenViewByKeyword`); `monitorSummary_nonSystem_keepsOnlyOwnClNr` with rows whose `client_id` is a cl_nr and an id-valued decoy.

### Controller — `ReplenishControllerUnitTest` (service mocked; pins exception → wire mapping; resolved text, SBDEV-3641 precedent)
`/start`, `?heartbeat=true`, `/reset` with `FacadeException("MsgCannotReadOrder")` → 404 + `$.properties.code` (already covered by the SBDEV-3626 AC-16 nest: **regression pins**, green on base); PUT and multi → 200 `$.errors[0].message == "Order not found"`; `loadOrderById` null → 200 empty; `clientOrderList` with the service throwing `EntityNotFoundException("Client not found by clNr: X")` → 404 `detail`. Together with the IT's pairwise check (next), this gives foreign == missing over HTTP: the IT proves the service raises the **same** exception, the controller rows prove that exception's wire shape.

### IT — new `integration/service/mobile/ReplenishClientScopeIT`
Copy (do not extract) `ReplenishClaimIT`'s private seed helpers and `runAs`; parameterise `user(id, name, clientId)` only. Own container, id band `3668xxxx`, assert BY ID only. Seed C1 (item + order) and C2, users `u_c1` (C1), `u_c2` (C2), `u_sys` (client 0).
- `runAs(u_c2)` on C1's order: `startOrder`, `heartbeatOrder`, `resetOrder`, `update`, `fulfillMultipleUnitLoads` each throw key **`MsgCannotReadOrder`**, with the order in a FINISHED and a STARTED-by-`u_c1` variant; the order row's `state`, `operator_id`, `modified`, `version` and the source stock unit's `amount`/`reservedamount` unchanged; no child order rows. (AC-15)
- **Pairwise, foreign == missing** (AC-17): same caller `u_c2`, id `36689999` (absent) vs C1's order, for start / heartbeat / reset / update / multi (equal class, `getKey()`, `getLocalizedMessage()`), `loadOrderById` (both `null`), `getCalculatedOrdersByClientNumber` (unknown cl_nr vs C1's cl_nr: equal message), `requestReplenish` (same), `loadOrderByDestination` (a location without FLA vs C1's FLA location: equal key).
- `runAs(u_c1)` and `runAs(u_sys)`: `startOrder` succeeds (AC-5).

### Gate rail — `FunctionGuardMockMvcUnitTest` (AC-13, **regression pin**, green on base)
A principal without `MOBILE_UI_VIEW_REPLENISHMENT` gets 403 on `/loadOrderById/1`, PUT `/order/1`, `/multi-unitloads`, `/clientOrderList/X`. Mutation-check by removing the class `@RequiresFunction`, not a scope call. `FunctionGuardArchTest` golden map unchanged.

### ArchUnit — `ReplenishClientScopeArchTest` (AC-16; red on base: no scanned method calls the predicate yet)
Per §5 Fix E: rule, allowlist (planned 1, as built 5), non-vacuity over `EXPECTED_READERS` (planned 11, as built 14), fixture positive control.

### AC-5 instrument note
The lenient C1 default makes the predicate return true in every existing unit test, so **green existing unit suites are not evidence for AC-5**. The System leg rests on `ClientServiceUnitTest` (AC-14) and the IT's `u_sys` run.

### Mutation check
PIT `targetClasses` = `MobileReplenishService`, `ClientService`, `ViewDtoService`; `targetTests` = the classes above; every new-code mutant killed or listed with a reason. Manual, one at a time:
- delete each predicate call — 11 sites: A1, `lockOrder` (reddens start, heartbeat **and** reset — expected, one helper), A2, A5, A6 filter, A7 scope, A8, A9, A10, B1, B2;
- move the check **below the state guard** in A2, A5 and `lockOrder` → the `finished700`/`startedByOther` cases red;
- B2 `getClNr()` → `getId()` → AC-12 red;
- delete the anonymous guard → AC-14 anonymous case red;
- delete a rail source entry → the non-vacuity check red.

**Verify script: NONE.** Every assertion is JUnit/IT/ArchUnit; the one cross-file invariant ("a future handler skips the predicate") is now the rail.

### Manual test plan (DEV `dev_wh01_om1`, via `wms-dev-probe`)
DEV has no non-System user, so one is made temporarily. **`WMS_DEV_USER=sbtest`** in `~/.config/wms-dev-probe/credentials` (Nam supplies the password). `sbtest` (id 19800000) holds 84 functions incl. `MOBILE_UI_VIEW_REPLENISHMENT` and `MOBILE_UI_VIEW_REPLENISH_REQUEST` (role ∪ group-role query, run 2026-10-29). ⚠ `wmstest` was the r1 choice and holds **0** functions — it would 403 everywhere. `sbtest` is a shared DEV login and is re-parented to ACB for the run; announce it.

| # | Precondition / step | Count (run 2026-10-29) | Expect |
|---|---|---|---|
| M0 | `snapshot.sh save u3668 "select id,client_id from mywms_user where id=19800000"`; `snapshot.sh save ro3668 "select id,state,operator_id,version,modified from replenishorder where id in (20295307,20295309)"`; then `UPDATE mywms_user SET client_id=700112951 WHERE id=19800000` (ACB) | sbtest client 0; CRIST order 20295307 (state 300), ACB order 20295309 (300, no operator) | 1 row |
| M1 | as sbtest: `GET loadOrderById/20295307`; `POST /order/20295307/start` | — | 200 empty; 404 `properties.code=MsgCannotReadOrder`; `ro3668` row 20295307 unchanged |
| M2 | as sbtest: `POST /order/20295309/start`, then `/reset` | — | 200 claim; 204. **Side effects not undone:** row 20295309 `version` +2 and `modified` advance (state/operator return to 300/NULL); list them in the run report |
| M2a | **on abort between M2 start and reset:** `/reset` as sbtest; if the token is gone, `UPDATE replenishorder SET state=300, operator_id=NULL WHERE id=20295309 AND operator_id=19800000` | — | order not left claimed |
| M3 | `SELECT count(*) FROM replenishorder WHERE client_id=700112951 AND state<670` (OPEN = `state < PALLETIZED(670)`) | 52 | `detailView?state=OPEN&size=500`: exactly 52 rows, every `clientNumber='ACB'` |
| M4 | `SELECT count(*) FROM fix_location_assignment f JOIN itemdata i ON i.id=f.itemdata_id WHERE i.client_id NOT IN (0,700112951)` | 1298 | `requestLocation/<one of them>` → "Not a fixed assigned storage location"; `/clientList` → `[ACB]` |
| M4b | (A12, added 2026-10-29) pick one `f.assignedlocation_id` from the M4 query, and one ACB-owned FLA location (`… WHERE i.client_id=700112951`) | — | as sbtest: `GET fixedLocationUpperBound/<foreign>` → 200 **empty body**, same as an unassigned location; `GET fixedLocationUpperBound/<ACB>` → its `upperbound` |
| M5 | `UPDATE mywms_user SET client_id=0 WHERE id=19800000`; `snapshot.sh diff u3668`; `snapshot.sh diff ro3668` | — | `u3668` **restored**; `ro3668` differs only in 20295309 `version`/`modified` (declared in M2) |

---

## §9 Risks & mitigations

| # | Risk | Mitigation |
|---|---|---|
| R1 | Unit-test wall of reds from the mocked predicate and the anonymous guard | §8 churn table C1–C12, fixed before judging reds |
| R2 | B1/B2 change non-System **web** users' lists; and B1 force-own vs A6 refuse-foreign answer the same question differently — a non-System web user who picks shipper X (`wms2-web-ui store/internalOps/replenishments.js:165` `'&clientId=' + data.clientId`) sees their own rows under X's chip | accepted (Nam D2); the web shipper dropdown is P31's to scope; safe to resolve the caller on web because the gate already requires a provisioned WMS user (`AccessService` `USER_NOT_PROVISIONED`) |
| R3 | Check after `FOR UPDATE`: a foreign caller briefly locks, or waits on, a foreign row; a held row can answer the lock-timeout 409 (`retryable:true`) instead of 404 — a narrow "exists and is busy" oracle, and a foreign caller spamming `/start` contends with the owner | accepted at zero exposure; scalar pre-check is the ADR follow-up |
| R4 | A caller with no resolvable WMS user (or anonymous) now gets ENFE from the predicate on multi, loadOrderById and the lists → `RestExceptionHandler` (`@Order(0)`, unscoped) **404 ProblemDetail** (no code); on start/reset the local catch → 404 `ENTITY_NOT_FOUND`. Caller-level, not object-level: no oracle | accepted; unreachable for a real handheld user |
| R5 | B2 compares the wrong key (id vs cl_nr) and empties the Critical list | AC-12 decoy row; manual mutation |
| R6 | **SDR `/v3/replenishorder` item + collection reads bypass A1/A6–A8/B1/B2** on any tenant whose `WMS2_SDR_READ_GUARD_MODE` is OFF (the default for absent/unknown) or SHADOW (DEV) — and even ENFORCE_RULED checks a function, not a client. Only the writes (A2–A5, A10) are closed, because SDR writes on `Replenishorder` are withdrawn. Also open: P31 web by-id, P32 other mobile, P11 cancellation | P-5: P31 before onboarding any non-System user; docs note splits writes from reads; P-1 measures the guard mode |
| R7 | A future `/order/{id}/x` handler forgets the check | ArchUnit rail (AC-16) |
| R8 | P30 (detailView 500-row cap) interacts with B1 | B1 only narrows the set |
| R9 | Identity axis: predicate uses `getUserName()`, gate uses `getAuthorizedName()`; they differ for a JWT without `preferred_username` | pre-existing (same as `currentUser()`); carried to P31/P32 |
| R10 | A9 reorder: dangling FLA item → 404 instead of the order-state message | FK-backed on DEV; accepted |

---

## Horizontal Scalability Validation

| Concern | Affected? | Evidence |
|---|---|---|
| In-JVM state | No | predicate stateless; `getUserClient` uncached |
| Pool math | No | no new tx |
| Scheduled jobs | No | touched methods have controller callers only (grep, §5); blind spot reflection |
| Long tx | No | added reads per request (all indexed: `mywms_user.name` unique, `client` PK): claim paths 3 (`currentUser` + predicate's 2), PUT/multi/loadOrderById 2 (+2 more in `readAddOn` on loadOrderById), A6 1+2+2 |
| Request affinity | No | stateless |
| Retry / idempotency | No | refusals terminal and repeatable |
| Tenant context | No | tenant datasource via `TenantFilter` |
| Distributed locks | Unchanged | same `findByIdForUpdate`, same order; check after it (R3) |
| Cache invalidation | No | no cache added |
| External notifications | No | none |

## v2 constraint checklist

| Constraint | Status |
|---|---|
| OSIV | off; no lazy access added |
| `tenantTransactionManager` | no new `@Transactional`; existing ones unchanged |
| readOnly / propagation | unchanged |
| Constructor injection | `ViewDtoService` +1 param; `ReplenishController` −1; `MRS` unchanged |
| Optional safety | `orElseThrow` / `map` / `orElse` only (OptionalSafetyArchTest) |
| H2 SQL | no SQL change; H2 fixtures seed System client + named user (C7/C8) |
| BaseControllerUnitTest | `ReplenishControllerUnitTest` extends it |
| Micrometer | no new metric |

## Completeness checklist

| # | Item | Status |
|---|---|---|
| 0 | Affected sites by grep (§0) | done; method + blind spots; A13/A14 added |
| 1 | DB query confirming the symptom | §1 (0/100 non-System users; 566 open over 58 clients; guard mode SHADOW) |
| 2 | Root cause to file + quote | §2 |
| 3 | Sibling sweep | §0 A13/A14/B4/B5/C1 → P31/P32; A11/A12 no change |
| 4 | Invariant over instance | one predicate pair at every site + ArchUnit rail with non-vacuity and positive control |
| 5 | Failing test first, per AC | §8; AC-13 and the controller claim rows are regression pins (stated) |
| 6 | Mutation-check plan | §8 (PIT + 11 deletions + 3 move-below-state + key flip + anonymous + rail source) |
| 7 | Flyway version swept | n/a — no migration |
| 8 | Cross-repo deploy order | API only; handheld unchanged |
| 9 | Docs | §6 docs row (3 docs; writes vs reads split) |
| 10 | Independent review | 4 lanes (T3), reports to `SBDEV-3668-evidence/` |
| 11 | Verify script | NONE (§8) |

---

## §10 Resolved decisions

**Nam, 2026-10-29 — not reopened:**
- **D1** Proceed despite zero DEV exposure; UAT/PRD re-measure is non-blocking (P-1). Consequence (r2): because SDR reads bypass the in-scope reads (R6), **P31 must land before any non-System user is onboarded** (P-5).
- **D2** In scope: A1, A2, A3/A4, A5 (template check suffices — verified §2), A6, A7 (3 bug-pinning tests flipped), A8, A9 (+B3), A10, B1 and B2 forced to own client for non-System callers, web included.
- **D3** Out: P31 (web by-id + SDR `/replenishorder`, now also A13), P32 (other mobile workflows + A14; cancellation is P11) — proposed in `sbdocs/2-Areas/proposals-register.md`, never filed.
- **D4** Refusal contract: identical to not-found per endpoint; check before any state check.
- **D6** (was Q1) **Add the ArchUnit rail now**, scoped to `MobileReplenishService` + the `ViewDtoService` list sites, non-vacuity on the scanned set, fixture positive control, own AC (AC-16). P31/P32 widen it.

**Planner decision, r2 (for review):**
- **D5** `callerScopeClient()` / `isVisibleToCaller` **fail closed on the `anonymous` sentinel**. No production path runs as anonymous (§5 method); 6 test classes do and are converted (C7–C12).

## ADR

- **Decision:** `ClientService.callerScopeClient()` (list sites) + `isVisibleToCaller(Long)` (by-id sites), checked in the service immediately after each existing load/lock, mapped to each endpoint's existing not-found; fail closed on anonymous; pinned by `ReplenishClientScopeArchTest`.
- **Drivers:** no handheld change; no new lock/stale-entity hazard; one reusable home for P31/P32.
- **Alternatives:** controller advice/aspect (cannot produce 4 refusal shapes; misses B3 and service callers); plain-read check before lock (SBDEV-3244 lock-upgrade `StaleObjectStateException`); **scalar `findClientIdById` before lock** — the Architect's steelman: closes R3 and the contention lever, one indexed read; it loses because the after-lock check reads the **locked, committed** `client_id` and is TOCTOU-free whatever `client_id`'s mutability, while the pre-lock scalar is safe only while `client_id` stays immutable (true today: two Java create sites + SDR writes withdrawn); private helper in MRS (second copy in VDS); inline `getUserClient + isSystemClient` at list sites (four copies of the rule — Architect synthesis adopted instead); B1/B2 refuse foreign (Nam chose force-own).
- **Why chosen:** smallest diff that keeps the lock first, keeps every refusal byte-identical to not-found, puts the rule where every caller (mobile, web B3) passes, and makes the rule enforceable by a rail.
- **Consequences:** 2–5 indexed reads per scoped request; non-System web users see only their client in B1/B2; System + null in `getCalculatedOrders` means all clients; anonymous now refused on these paths (6 test classes converted); R3/R4/R9/R10 accepted; SDR reads remain the open read route (R6, P-5).
- **Follow-ups:** P31 (SDR reads, web by-id, A13, web shipper dropdown — before any non-System onboarding), P32 (+A14), P11; widen the rail with each; scalar pre-check if a non-System tenant reports lock contention or if `client_id` ever becomes writable; P-1 counts on the ticket.

## Acceptance criteria → tests

| AC | Criterion | Test |
|---|---|---|
| AC-1 | non-System `loadOrderById` on a foreign order → `null` (200 empty); own → returned | `ClientScoping#loadOrderById_*`; controller empty-body row |
| AC-2 | PUT on a foreign order → `MsgCannotReadOrder` in FINISHED and STARTED-by-other; 200 `errors[0].message="Order not found"` | `ClientScoping#update_refusesMsgCannotReadOrder_whenForeign_*`; controller row |
| AC-3 | start / heartbeat / reset foreign → `MsgCannotReadOrder` (not the state keys), no save; wire 404 `properties.code` | `ClientScoping#startOrder_/heartbeatOrder_/resetOrder_*`; controller pins |
| AC-4 | multi foreign (FINISHED, STARTED-by-other) → `MsgCannotReadOrder` before any SU lock, no child order | `ClientScoping#fulfillMultipleUnitLoadsTx_refuses*` |
| AC-5 | System caller unchanged on AC-1..4 | `ClientServiceUnitTest.CallerScope` System rows + `ReplenishClientScopeIT` `u_sys` run (not the existing unit suites — §8 note) |
| AC-6 | `getCalculatedOrders` 5-row matrix | `GetCalculatedOrders` (rewritten) |
| AC-7 | `clientOrderList` foreign → 404 identical to unknown | `#getCalculatedOrdersByClientNumber_unknownAndForeign_throwIdenticalMessage`; controller row; AC-17 |
| AC-8 | `/clientList` non-System → own only | `GetClientList#nonSystem_returnsOnlyOwn` |
| AC-9 | `requestLocation` / web B3 on a foreign FLA item → "Not a fixed assigned storage location", before reading the order | `ClientScoping#loadOrderByDestination_*` |
| AC-10 | `requestAmount` naming a foreign client → "Client not found: X", no `calculateOrder` | `ClientScoping#requestReplenish_*` |
| AC-11 | `detailView` non-System → own client whatever `clientId` | `ViewDtoServiceUnitTest#detailView_nonSystem_forcesOwnClientId_ignoringParam` |
| AC-12 | monitor summary non-System → rows with own **cl_nr** only | `ViewDtoServiceUnitTest#monitorSummary_nonSystem_keepsOnlyOwnClNr` |
| AC-13 | **regression pin:** no function → 403 on order-id paths (gate precedes scope) | `FunctionGuardMockMvcUnitTest` new rows |
| AC-14 | predicate truth table; fails closed on anonymous, no user, no client; System by cl_nr | `ClientServiceUnitTest.CallerScope` |
| AC-15 | real DB: foreign user refused with `MsgCannotReadOrder`, rows unchanged; own succeeds | `ReplenishClientScopeIT` |
| AC-16 | every scanned MRS/VDS method reading a replenish source calls the predicate; non-vacuous over `EXPECTED_READERS` (14 as built); positive control reports the leaky fixture | `ReplenishClientScopeArchTest` |
| AC-17 | foreign refusal == missing-id refusal on the same endpoint (class, key, message / null) | `ReplenishClientScopeIT#foreignRefusal_equalsMissing_*` |

---

## Review round 1 — disposition

| Finding | Disposition |
|---|---|
| Critic M1 (A8/A9 churn) | **Changed:** §8 C2 (covered by the System default for `callerScopeClient`), C3 (stub `getById(10L)`, assert key); A9 placement fixed to "directly after `fix`" and the dangling-item side effect stated (R10) |
| Critic M2 (state-before-scope unpinned on writes) | **Changed:** every write path has FINISHED and STARTED-by-other foreign cases asserting `MsgCannotReadOrder` (unit + IT); "move below state" added to manual mutation for A2/A5/lockOrder |
| Critic M3 (manual restore) | **Changed:** `ro3668` snapshot of both orders, declared `version`/`modified` side effects, abort step M2a; user switched to **sbtest** — the requested `wmstest` holds 0 functions (DB query), so it cannot exercise the plan |
| Critic M4 (SDR reads bypass) | **Changed:** R6 rewritten, P-5 added, D1 consequence, docs row splits writes vs reads, P-1 measures the guard mode (DEV measured: SHADOW) |
| Critic L1 (R4 is 404 not 500) | **Changed:** R4 corrected (verified `RestExceptionHandler` `@Order(0)` unscoped `@ExceptionHandler(EntityNotFoundException.class)`) |
| Critic L2 / Arch M3 (anonymous fail-open) | **Changed:** fail closed (D5); production anonymous paths: none (method in §5); test paths: 6 classes (C7–C12); AC-14 pins it |
| Critic L3 / Arch L5 (ctor sites) | **Changed:** §6 + C6 name L68 and L515 |
| Critic L4 (AC-5 instrument) | **Changed:** §8 note; AC-5 row names its real instruments |
| Critic L5 (immutability second instrument) | **Changed:** §2 cites `SDR_WRITE_WITHDRAWN` as instrument 2, native-SQL blind spot |
| Critic L6 / Arch L2 (AC-13 green on base) | **Changed:** AC-13 and the controller claim rows labelled regression pins; AC-13 mutation is removing the class gate |
| Critic L7 (counts, wording, PK) | **Changed:** 11 deletion sites; lockOrder reddens 3 tests by design; lookup counts measured per path; `findByName` called unique-index, not PK |
| Critic "missing": IT copy vs extract; IT asserts key; A6 unknown vs foreign body; web caller resolution | **Changed:** copy + parameterise `user`; keys asserted; AC-17 pairwise + controller mapping row; R2 cites `USER_NOT_PROVISIONED` |
| Arch M1 (two H2 classes) | **Changed:** C7/C8 — seed System client + named user, `runAs`; no `@MockitoBean ClientService` |
| Arch M2 (A9 unit test) | **Changed:** C3 |
| Arch M4 (pairwise foreign == missing) | **Changed:** AC-17 in `ReplenishClientScopeIT` over 9 entry points; HTTP equality by composition with the controller mapping rows. Full MockMvc-over-real-service **not adopted**: it needs a web context over the Postgres container for one more layer the controller rows already pin |
| Arch synthesis `callerScopeClientId()` | **Adopted with one change:** returns `Optional<Client>` (B2 needs the cl_nr) |
| Arch synthesis: rail now | **Adopted** (Nam D6) |
| Arch steelman / ADR rationale | **Changed:** ADR states "TOCTOU-free whatever mutability"; the SDR-PATCH question is answered (writes withdrawn, verified) rather than handed to P31 |
| Arch T2 (force-own vs refuse-foreign UX) | **Changed:** R2 states it; P31 inherits it on purpose |
| Arch L1 (A13/A14) | **Changed:** §0 rows + widened method |
| Arch L3 (OPEN count) | **Changed:** M3 uses `state<670` → 52 (measured) |
| Arch L4 (redundant resolution) | **Partly:** counts stated per path; the `isVisibleToCaller(User, Long)` overload is **rejected** — a second signature weakens the rail's single predicate set for ≤2 indexed reads on a low-rate path |
| Arch L6 (identity axis) | **Changed:** R9 |

---

## Implementation review — round 1 (code `7e19f0e0`) → fixes `f2889c44`, `69646c4e` (rebased onto origin/develop `4883cf57`)

Reports: `.omc/research/SBDEV-3668-{conformance,codereview,security}-r1.md`; fixes `.omc/research/SBDEV-3668-fixes-r1.md`.

| Finding | Disposition |
|---|---|
| Conformance: AC-13 PARTIAL / CR M1 (killed only via `UnnecessaryStubbingException`) | **Fixed:** only `MOBILE_UI_VIEW_REPLENISHMENT` denied; asserts 403 + `X-Authz-Denied`; class-gate mutant now red on AC-13's own assertion |
| CR M2 (seed before tenant context) | **Fixed:** `seedSystemUser()` is the last line of `setTenantContext()` |
| CR L1–L11 | **Fixed** (table in the fixes report): Optional idioms, A6 resolves once, `update` + multi via `lockOrder`, B1/B2 scope first, single principal read with null arm, foreign-300 variants for the `never()` checks, reflective scaffolding removed, rail source `findByClNr`, B1 CLOSED + System pins |
| CR L12 / Sec L1 (timing / query-count oracle) | **Fixed for query count:** every in-scope path resolves `callerScopeClient()` before its lookup and compares in memory (`ClientService.isVisibleIn`); the order row's first touch stays `findByIdForUpdate`. Lock-wait timing on a held foreign row stays accepted (R3) |
| Sec L2 (A12 leak) | **Fixed** (Nam: scope here) — §0 A12 row; unit own/foreign==unassigned/System, controller wire row, IT pairwise; mutant: filter deleted → `expected: null but was: 36` |
| Sec I1 (rail checks the call, not its use) | **Covered by tests:** an "ignore the result" mutant per touched site, each killed by that site's unit test |
| Sec I2 / I3 / I4 | I2 → P32; I3 no change (sort not injectable); I4 residuals stand |

Full suite after the fixes (pre-rebase, `53126b85`): surefire 9251 / 0 F / 0 E, failsafe 1109 / 0 / 0. Round 2 (code review + security/conformance) runs on `69646c4e`.

### Round 2 (`69646c4e`) → fix `b9eaa219`
Reports: `.omc/research/SBDEV-3668-{codereview,security}-r2.md`; fixes `.omc/research/SBDEV-3668-fixes-r2.md`. Code review COMMENT (0 H, 1 M, 5 L); security PASS (1 L).

| Finding | Disposition |
|---|---|
| CR M1: `readAddOn` copied a caller-chosen destination's FLA bound into `amountDestinationMax`, so `/requestAmount` leaked the A12 bit | **Fixed:** `readAddOn` takes the scope and keeps the bound only when the FLA's item is visible (shared helper with A12); System unchanged. Allowlist reasons rewritten. Lanes disagreed (security: "all allowlist entries post-scope") — the disagreement was the finding: the scope check covers the client, not the caller-chosen destination |
| CR L1 = Sec L1: scope-before-lookup unpinned (moving `callerScopeClient()` below `findByIdForUpdate` survived 155/155) | **Fixed:** `InOrder` pins at lockOrder, A1, A6, A9, A10, A12, B1, B2; each move-below mutant reds its own pin |
| CR L2 dead stub / stale javadoc · L3 `isVisibleToCaller` unused in production · L5 A12 item read for System | **Fixed** · **kept with a warning javadoc** (deleting narrows the rail predicate pair and the gate contract test) · **fixed** (System short-circuit, pinned) |
| CR L4 stale rail counts in this plan | **Fixed:** Fix E / §8 / AC-16 carry planned vs as-built numbers |
| Open, for Nam | `/requestAmount` may create an own-client order whose destination is another client's FLA bin (pre-existing; a behaviour change to refuse) |

Full suite `b9eaa219` (Testcontainers reuse OFF): surefire 9273 / 0 / 0, failsafe 1123 / 0 / 0. An earlier run at `69646c4e` with reuse ON gave 15 failsafe reds in 4 non-replenish classes — the known reused-container fill.

### Round 3 (`b9eaa219`) → fix `3cb2db59`
Report: `.omc/research/SBDEV-3668-review-r3.md`; fixes `.omc/research/SBDEV-3668-fixes-r3.md`. COMMENT (0 H, 1 M, 3 L).

| Finding | Disposition |
|---|---|
| M1 (test gap): the scope passed to `readAddOn` by loadOrderById / startOrder / update / getReservedOrder unpinned | **Fixed:** parameterised test over the 4 routes + own-bin control; one `Optional.empty()` mutant per route reds only that row |
| L1 caller resolved twice | **Fixed:** `lockOrder` returns order + admitting scope (private record); `getReservedOrder` derives scope from the client it holds |
| L2 allowlist reason overclaimed | **Fixed:** names only "has different fixed assignment" |
| L3 A9 double visibility check | **Not changed:** removing it needs a trust flag or `Optional.empty()` at A9, which reads like the M1 bug; one cached read |

### Round 4 (`3cb2db59`) → fix `bffd9721`
Report: `.omc/research/SBDEV-3668-review-r4.md` — **APPROVE**, 2 Low + Info. L1 rail javadoc for `readAddOn` (scope source of `getReservedOrder`) **fixed**; L2 System branch of `getReservedOrder` unpinned (fail-safe mutant survived) **fixed** with `getReservedOrder_reportsForeignBinBound_whenCallerIsSystem`; Info (anonymous refused only because `currentUser()` runs first) **comment added**. 
### Round 5 (`bffd9721`) → fix `d4cef01b` · Round 6 (`d4cef01b`) → APPROVE
Round 5 (`.omc/research/SBDEV-3668-review-r5.md`): **APPROVE**, 1 Low — anonymous refusal in `getReservedOrder` rests on `currentUser()` running first, unpinned → **fixed** with `getReservedOrder_shouldRefuse_whenCallerIsAnonymous` (System-client trap stubbed; reorder mutant → `NeverWantedButInvoked … getUserClient()`). Round 6 (`.omc/research/SBDEV-3668-review-r6.md`): **APPROVE**, 0 H/M/L.

Branch rebased onto origin/develop `c9d1d77b` (SBDEV-3951, no file overlap, rail source names unchanged): tip **`619a46b9`**, same patch-id as the reviewed `d4cef01b`.

---

## Implementation status (2026-10-30)

- **PR:** https://github.com/SiteBossInc/wms2-api/pull/586 → `develop` (7 inline reviewer notes). Not merged.
- **Branch** `bugfix/SBDEV-3668-replenish-client-scoping` @ **`619a46b9`**, base origin/develop `c9d1d77b`. Commits: `936adbf5` TDD gate · `9d66b036` predicate · `ec3eb31c` Fixes A–D · `58ecbf9f` PIT pins · `21b66815` rails · `f2889c44` review r1 · `69646c4e` A12 · `b9eaa219` review r2 · `3cb2db59` review r3 · `bffd9721` review r4 · `619a46b9` review r5.
- **Full suite at `619a46b9`** (`mvn -B -ntp clean verify -Pci`, JDK 21, Testcontainers reuse off): surefire 9338 / 0 F / 0 E (1 skipped); failsafe 1138 / 0 / 0 (23 skipped). Baseline on `219ad551`: 0 failures.
- **Reviews:** 6 rounds; the last (r6) APPROVE with 0 H/M/L; reviewed patch-id = tip.
- **Open:** P-1 (UAT/PRD exposure + `WMS2_SDR_READ_GUARD_MODE`, MCPs down), **P-5** (P31 before onboarding any non-System user), the manual DEV test (post-merge; Nam supplies the `sbtest` password). `/requestAmount` into a foreign FLA bin: Nam 2026-10-30 — leave, noted in the PR.
- Not done by the executor: merge, `on dev`, archive, worktree removal.

### Merged — on dev (2026-10-30)
- **PR #586 merged into develop as `dde23325`** (merge-one.sh, pinned to graded head `74e1c41f`).
- Develop had moved by 2 commits (`711399b3` / `aa84699c`, request-header limit 64 KB; no overlapping files), so develop was merged into the branch as `74e1c41f`, with no conflicts. PR check run 41047649024: `test` passed on `74e1c41f` (full `mvn clean verify -Pci`).
- Post-merge (`post-merge-verify.sh --wait-deploy`: ALL PROVEN): develop CI run 41050575837 passed test and build; DEV serves `develop-dde233259f2a5106c30f32f68b9425129d16eca6`.
- ClickUp → `on dev`, with each fix-direction item settled (UAT/PRD exposure still open, P-1). Doc markers flipped (4 standard + 2 by hand).
- **Next:** the manual DEV test (M0–M5 incl. M4b, `wms-dev-probe`, `sbtest` → ACB; Nam supplies the password), then `archive-plan`. P-1 and P-5 remain open.


### Manual DEV test — 2026-10-30 (develop-dde23325, sbtest → ACB → System)
All of M1–M5 and M4b ✅, with System-caller controls and missing-id controls. Detail is in the ClickUp comment.
- On the wire, `code` is a **top-level** ProblemDetail field (`"code":"MsgCannotReadOrder"`), not `properties.code` as §8 and the PR body say. The refusal is identical to a missing id either way.
- Restore proof: `u3668` restored. `ro3668` differs only in order 20295309's `version` (4454 → 4456) and `modified`, as declared in M2. No orders were created.
- Not run: the PUT and multi-unitloads foreign refusals (covered by unit tests and the IT), and `/requestAmount` (it would create an order).
- **Next:** `archive-plan`. P-1 (UAT/PRD exposure) and P-5 (P31 before onboarding) remain open.

---

## Archive note (2026-10-30)
Archived after merge (#586 `dde23325`, on dev) and a passing manual DEV test. No verify script existed (T3 opt-out).
> Implementation worktree(s) removed 2026-10-30: wms2-api/SBDEV-3668 and analysis/wms2-api-SBDEV-3668 (local branch deleted; remote branch left to GitHub).

| Finding | Disposition |
|---|---|
| P-5 / R6 — SDR `/v3/replenishorder` reads + web by-id routes unscoped | **Proposed P31** — must land before any non-System user is onboarded |
| Other mobile workflows unscoped; `/multi-unitloads` existence hint (sec I2); A14 | **Proposed P32** |
| Pending Reversals not client-filtered | **Proposed P11** |
| R9 identity axis (`getUserName` vs `getAuthorizedName`) | **Proposed** — carried in P31/P32 |
| P-1 UAT/PRD exposure + `WMS2_SDR_READ_GUARD_MODE` | **Done 2026-10-30:** all 8 v2 UAT/PRD tenant DBs (WineCo, Hydra, ShipItEZ LA+NY; each schema-checked) have **0 non-System users** (control: System = all users, 0 orphans); multi-client warehouses exist (up to 124 clients); guard mode **OFF everywhere** (DEV: SHADOW). Table on the ticket. |
| `/requestAmount` can create an own-client order into another client's FLA bin | **Dropped** — pre-existing; Nam 2026-10-30: leave, noted in PR #586 |
| R3 lock-timeout 409 on a busy foreign row; scalar pre-check follow-up | **Dropped (accepted risk)** — revisit on lock-contention reports from a non-System tenant or if `client_id` becomes writable |
| R10 dangling FLA item → 404; sec I3 sort not injectable | **Dropped (accepted)** |

