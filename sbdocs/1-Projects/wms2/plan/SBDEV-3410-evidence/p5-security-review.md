# SBDEV-3410 P5 — Security review (independent lane)

**Scope:** `ClientController.allClients` `@RequiresFunction` ANY-of set, eleven → fourteen, plus the
paired exact-set-equality row in `Sbdev3017TrancheGateContextTest`.
**Source of truth:** worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p5`
@ `1aa726d5`, branch `feature/SBDEV-3410-p5-allclients-stock-unit-record-function`, 1 ahead of
`origin/develop`. Diff: 2 files, 110 lines (`/tmp/p5.diff`).
**Date:** 2026-09-22. **No maven was run** (per lane constraint); no working-tree mutation of any kind.

**Verdict: the widening is safe to ship.** Blast radius is zero on every database I could reach, the
three functions added are exactly the ones that gate the three screens, the payload carries no PII or
secrets, and the tenant boundary holds. Four findings below, none blocking — one Medium that is
**pre-existing and not introduced by P5** but that materially changes how much this gate is worth,
and three Low.

---

## Instrument validation (do this before believing any number below)

Every holder count comes from a SQL traversal that reproduces `UserRepository.getAllRoles`
**join for join** — same four tables, same columns
(`src/main/java/net/aim_ai/wms/repo/jpa/UserRepository.java:77-84`):

```sql
mywms_user u
  JOIN mywms_group_mywms_user  gu ON u.id = gu.userlist_id
  JOIN mywms_group_mywms_role  gr ON gr.grouplist_id = gu.grouplist_id
  JOIN mywms_role_mywms_function rf ON rf.rolelist_id = gr.rolelist_id
  JOIN mywms_function           f  ON rf.functionlist_id = f.id
```

`AccessService.checkAnyAccess` (`service/AccessService.java:134-160`) calls exactly that query and
ORs the held list against the annotation values. There is **no super-admin bypass inside
`checkAnyAccess`** — it is a pure list membership test — so the SQL is the whole decision.
`mywms_user_mywms_role` is not traversed, correctly: it is unused in v2.

Two controls, both run, both on `dev_wh01_om1`:

| Control | Purpose | Result |
|---|---|---|
| probe a bogus function `ZZZ_BOGUS_CONTROL` | a broken join would still return a count | **0 holders** — instrument discriminates |
| ask which functions ARE held by users outside the eleven | proves the "newly gains" column is not vacuously 0 | **`MOBILE_UI_VIEW_PICKING` et al → 5 users.** So a 5 *was* reachable; the 0s below are true zeros |

That second control is the one that matters. Without it, `gaining = 0` is indistinguishable from
"nobody is outside the eleven, so the column can only ever print 0" — which, as it happens, is the
situation on all three non-dev databases (see S4).

---

## Q1 — Is the widening safe? Who newly gains `allClients`?

**VERIFIED. Nobody, on any database reachable from this session. Four databases, including one
production tenant.**

`holders` = users who hold that function via the group path. `gaining` = holders who hold **none** of
the previous eleven, i.e. the population the change actually unblocks.

| Database | Env | STOCK_UNIT_RECORD | STOCK_UNIT | CONTAINER | **gaining (each)** | users in graph / already admitted by the eleven |
|---|---|---|---|---|---|---|
| `dev_wh01_om1` (wineco) | dev | 45 | 44 | 45 | **0 / 0 / 0** | 54 / 49 |
| `wh01_hydra_v2` (hydra/nywh) | **PRD** | 7 | 7 | 7 | **0 / 0 / 0** | 7 / 7 |
| `wh01_shipitez_v2` (c1wh) | uat | 26 | 26 | 26 | **0 / 0 / 0** | 34 / 34 |
| `wh02_shipitez_v2` (nywh) | uat | 9 | 9 | 9 | **0 / 0 / 0** | 9 / 9 |

The dev row **independently reproduces the lead's 45 / 44 / 45 and 0 / 0 / 0**, from a query written
without sight of theirs.

The five dev users outside the eleven hold only `MOBILE_UI_*` functions and hold none of the three
new ones — so they gain nothing either. On prd hydra, all 7 provisioned users already hold all
fourteen; the 2 remaining `mywms_user` rows (9 total) are not in the authorization graph at all.

**Strictly widening, and latent.** No user anywhere I can measure moves from denied to allowed.

⚠ **Coverage limit, and it is bigger than the task framing assumed.** `landlord-prd` lists **three
active tenant databases**, not one:

```
hydra    / nywh → wh01_hydra_v2     (measured, read-only MCP)
shipitez / c1wh → wh01_shipitez_v2  (NOT measured — no prd MCP in this session)
shipitez / nywh → wh02_shipitez_v2  (NOT measured — no prd MCP in this session)
```
`SELECT t.name, c.warehouse, c.active, split_part(c.db_url,'/',4) FROM tenant t JOIN tenant_db_configuration c ON c.tenant_id=t.id` — all three `active = true`.
The two shipitez rows I measured are the **UAT** databases, which happen to carry the same database
names on a different host. They are a proxy, not the production tenants. **2 of 3 production tenant
databases are unmeasured.** Given 4/4 measured databases return 0 and the UAT shipitez copies are
the closest available analogue of the prd ones, I judge the residual risk low — but the claim
"blast radius is zero on production" is supported for **hydra only**.

---

## Q2 — Is the client list tenant-scoped?

**VERIFIED PASS. `allClients` cannot leak clients across tenants.**

- `ClientRepository` lives in `net.aim_ai.wms.repo.jpa`, which `TenantDatabaseConfig:22-24` binds to
  `tenantEntityManagerFactory` — the routing datasource — not to the landlord EMF.
- `TenantDynamicRoutingDataSource.determineCurrentLookupKey()` returns `TenantContext.getCurrentTenant()`
  (`landlord/config/TenantDynamicRoutingDataSource.java:120-122`); the key is
  `first4(tenant) + "-" + facilityCode`. One tenant+facility → one physical database, and `client`
  is a per-database table (147 rows in `wh01_hydra_v2`).
- **The null-context failure mode is safe.** `determineTargetDataSource()` (`:126-130`) falls back to
  `getResolvedDefaultDataSource()`, which is the **landlord** datasource (`:114`). The landlord schema
  has no `client` table, so a missing/misspelled `X-Tenant-ID` produces a SQL error, never another
  tenant's rows. In practice the request never gets that far: a null tenant context makes
  `MultiTenantJwtDecoder` fall back to the default issuer and the request 401s first.

There is no *intra*-tenant scoping — a caller sees all 147 merchants in their warehouse, not only the
ones tied to their `mywms_user.client_id`. That is the endpoint's whole purpose (it populates a
shipper filter dropdown) and is unchanged by P5, so it is not a finding here; noted only so the next
reader does not mistake it for an oversight.

---

## Q3 — Does `allClients` return sensitive fields?

**VERIFIED PASS. It is a thin roster, not a fat entity.**

`Client extends AbstractBaseEntity` and declares **eight** fields; the base adds four. Confirmed
against the live prd schema — the table has exactly these twelve columns, so there is no unmapped
column that could later be picked up:

`id · created · modified · version · additionalcontent · entity_lock · name · cl_nr · section_id ·
enablereceiving · printerreceiving_id · defaultputawaylocation_id`

No addresses, no contacts, no credentials, no API keys, no email or phone. `additionalcontent` is the
only free-text field and is the one that could in principle hold anything — measured on prd:
`SELECT count(*), count(additionalcontent) FROM client` → **147 rows, 0 non-null**. Nothing is hiding
in it today.

What *does* go out is the tenant's complete merchant roster — 147 names and merchant numbers on
hydra prd. That is commercially confidential but not personal data, and every one of the fourteen
screens in the ANY-of set already renders it in a dropdown. Widening a gate on this payload is not
equivalent to widening one on an entity carrying secrets.

---

## Q4 — Is `@RequiresFunction` genuinely enforced on this route?

**VERIFIED PASS for the MVC route. But there is an ungated sibling route to the same data — see S1.**

The MVC path is enforced, and each of the repo's documented "looks enforced but isn't" traps is
cleared explicitly:

1. **`ClientController` is NOT in `FunctionGuardInterceptor.GUARDED`** (`:124-171` — sixteen classes,
   this is not one). That does **not** matter here: `preHandle` reads
   `handlerMethod.getMethodAnnotation(RequiresFunction.class)` **before** the GUARDED check
   (`:236` vs `:271`), and GUARDED membership only decides what happens when *no* annotation
   resolves. A method-level annotation on a non-GUARDED controller is fully honoured. Precedent in
   this same repo: `StockUnitController:84` relies on exactly this.
2. **The interceptor reaches the route.** It is registered as a `MappedInterceptor` **bean** with
   pattern `/**` (`WebConfig.java:85-88`), picked up by every `AbstractHandlerMapping` via
   `detectMappedInterceptors`. Declared return type is `MappedInterceptor` — the order-dependence trap
   documented at `WebConfig:58` is not tripped.
3. **No kill switch.** `FunctionGuardInterceptor` is a bare `@Component` (`:105`) with no
   `@Conditional*`; the bean method has none either. It cannot be disabled by a property.
4. **No `@PublicHandler` on the method**, so the marker cannot shadow the requirement.
5. **Transport auth holds:** `SecurityConfiguration:178` gates `/v3/**` on authority
   `wms_user`, so the route is not anonymous.
6. `AccessService.checkAnyAccess` fails closed on empty varargs and on an unprovisioned user
   (`:134-160`) — the annotation here carries fourteen values, so that path is unreachable.

**Bypass check — and this is the one real hit.** See S1.

---

## Q5 — Is the resulting fourteen-member ANY-of set self-consistent?

**VERIFIED. No member is an outlier, and no member is materially wider than the others — but the OR
was already close to universal before P5.**

Holder counts, all fourteen, `dev_wh01_om1` (54 users in the authorization graph):

| holders | functions |
|---|---|
| 47 | FLOWBIN_MONITOR, PARCEL_MONITOR, PARCEL_PICKING |
| 46 | LOCATION_OVERVIEW |
| 45 | CONTAINER *(new)*, CYCLECOUNT, STOCK_UNIT_LOCK_OVERVIEW, STOCK_UNIT_RECORD *(new)* |
| 44 | INVENTORY_RECORD, STOCK_UNIT *(new)* |
| 42 | INBOUND_BOL, RECEIVED_STOCK_OVERVIEW |
| 41 | REPLENISHMENT_ORDER |
| 37 | CLIENT |

The three new members sit at 45 / 44 / 45 — **narrower than the three widest existing members**. P5
introduces no new widest member and no "effectively any user" member that was not already there.

On prd hydra all fourteen sit at 7 holders, out of 7 graph users — the eleven already admitted 100%
of the provisioned population, and so does the fourteen. Same on both UAT shipitez databases
(34/34 and 9/9). See S4: this is a pre-existing property of the design, not something P5 causes.

**The three functions added are the correct ones** (verified in `wms2-web-ui` @ `origin/develop`
`9254bf5`, not assumed):
- `util/appMenuList.js:78` — `/handlingUnits/handling-units` is ANY-of
  `['WEB_UI_VIEW_STOCK_UNIT','WEB_UI_VIEW_CONTAINER']`. Both grids (`components/handlingUnits/containerTable.vue`,
  `stockUnitsTable.vue`) dispatch `admin/client/getClients` today.
- `util/appMenuList.js:120` — Stock Unit Record is gated on `WEB_UI_VIEW_STOCK_UNIT_RECORD`.
- `store/admin/client.js:24` — `getClients` hits `'/allClients'`, i.e. the **MVC** route under review,
  not SDR. So the gate does govern the UI's real path.

The comment's own derivation also checks out exactly:
`git grep -l "admin/client/getClients" origin/develop -- '*.vue' '*.js'` → **15 files, 26 sites** at
`9254bf5`, across seven reports plus the two Handling Units grids. The retracted "13 / six reports"
was indeed wrong, and in exactly the way the comment says.

---

# Findings

## S1 — MEDIUM — The same client roster is reachable **ungated** over Spring Data REST
**VERIFIED. Pre-existing on `origin/develop`; NOT introduced by P5. Do not block P5 on it.**

`ClientRepository` carries a class-level `@RepositoryRestResource(collectionResourceRel = "client",
path = "client")` (`repo/jpa/ClientRepository.java:19`), the detection strategy is `ANNOTATED`
(`RestConfiguration.java:902`) and the SDR base path is `/v3`
(`RestConfiguration.java:25` → `:884`). `ClientController` declares no handler for the bare
`/v3/client` path (its mappings are `/create`, `/setSection`, `/setPrinter`, `/toggleReceiving`,
`/detailView`, `/detailViewById/{id}`, `/allClients`, `/receivingPrintIdByNumber/{number}`,
`/{id}/effectivePutawayDestination`), so nothing shadows SDR there. Two routes return the same data
as `allClients`:

- `GET /v3/client` — the SDR collection, `Page<Client>`, same entity, same fields.
- `GET /v3/client/search/findAllByOrderByName` — `@RestResource(path="findAllByOrderByName")`,
  exported, `SELECT c FROM Client c ORDER BY c.name`. That is `allClients` **byte for byte in intent**,
  including the sort.

Neither is gated:

1. `FunctionGuardInterceptor.preHandle:211-219` routes SDR handlers to `SdrFunctionGuard`, which is a
   **rule-source** gate. `SdrFunctionRules` rules exactly eight domain types — `User`, `UserFunction`,
   `UserGroup`, `UserGroupUser`, `UserRole` (`:214-240`), `Sysprop` (`:302`), `Message` (`:309`),
   `StockrecordView` (`:314`). **`Client` is not among them.**
2. An unruled type is not denied at the rollout's target mode: `SdrGuardMode.deniesUnruled()` is
   `this == FAIL_CLOSED`, so unruled is **allowed at SHADOW and at ENFORCE_RULED** — the exact
   argument `SdrFunctionRules:161-166` already makes for why P2 added its `StockrecordView` rule
   rather than deferring it.
3. And today it is moot anyway: `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey ILIKE '%SDR%'`
   returns `WMS2_SDR_READ_GUARD_MODE = OFF` on **both** `dev_wh01_om1` and prd `wh01_hydra_v2`.
4. Transport auth is the only thing left, and it is `hasAnyAuthority(wms_user)`
   (`SecurityConfiguration:178`) — which, per the 2026-08-26 authz-axis decision, everyone has.

**Consequence for this review:** the "who newly gains the shipper list" question in Q1 has a
zero answer for a second, stronger reason — every authenticated `wms_user` can already `GET /v3/client`
and read all 147 merchants without holding any of the fourteen functions. The gate P5 widens is real
for the UI's path and worth keeping correct, but it is not today a confidentiality boundary for this
data.

**Why Medium and not High:** the exposed data is a merchant roster with no PII or secrets (Q3), the
surface requires an authenticated `wms_user`, and this is the known, tracked state of the SDR
programme rather than a regression. It is Medium rather than Low because the P5 annotation comment
reads as if this gate controls access to the client list, and the next reader will believe it.

**Recommended fix (follow-up, not P5):** add `rules.put(net.aim_ai.wms.model.Client.class, …)` to
`SdrFunctionRules`, mirroring the P2 `STOCK_UNIT_RECORD_VIEW` precedent that Nam approved on
2026-09-21 for precisely this "a richer ungated path to the same data" shape. ⚠ It is **not** a
copy-paste: the rule set must be the same fourteen-member any-of as the MVC gate, or narrower rules
will 403 a live caller once a tenant reaches `ENFORCE_RULED` — `getClientList` is also exported and is
read by the replenishment screens. Sizing that set is design work, which is why it does not belong in
P5. Per the ticket policy this is a sub-T3 finding on an existing ticket → **put it on SBDEV-3410**,
unless SBDEV-3410 is already `on dev` or later, in which case it belongs on the SBDEV-3222/3183 SDR
programme.

## S2 — LOW — The stated derivation rule does not produce one of the three functions it justifies
**VERIFIED.**

The annotation comment states the rule as *"Derive the set from the dispatchers; do not maintain a
count"* and gives the command:

```
git grep -l "admin/client/getClients" origin/develop -- '*.vue' '*.js'   (in wms2-web-ui)
```

I ran it at `9254bf5`. It returns 15 files: the two Handling Units grids, three Cycle Count screens,
two Replenishment screens, `createPurchaseOrder.vue`, and seven reports. **`WEB_UI_VIEW_STOCK_UNIT_RECORD`
is not derivable from that output** — the Stock Unit Record screen does not dispatch `getClients` on
`origin/develop`; its dropdown is what this ticket's UI phase adds.

So a reader who does what the comment tells them to do, before the UI phase lands, derives an
**eleven-plus-two** set and concludes `STOCK_UNIT_RECORD` is extraneous. Removing it re-breaks the
screen SBDEV-3410 exists to fix — silently, as an empty dropdown, which is the exact failure mode the
comment is written to prevent. The comment turns its own rule against itself.

**Fix:** one sentence on the annotation, e.g. *"`WEB_UI_VIEW_STOCK_UNIT_RECORD` is added ahead of its
dispatcher: the Stock Unit Record shipper dropdown ships in this ticket's `wms2-web-ui` phase, so the
grep above will not list it until that lands."* Cheap, and it is the difference between a rule that
survives the next reader and one that misfires on them.

## S3 — LOW — The rule has no mechanical enforcement anywhere
**VERIFIED.**

The comment correctly identifies that the failure is invisible — an un-added function yields an empty
dropdown, not a 403, so neither a test nor the `METRIC_DENIED` counter can see it. Nothing then
enforces the rule. There is no arch rail, no cross-repo check, and no test in either repo that
compares the `getClients` dispatcher set against the `@RequiresFunction` set. The gate test
(`Sbdev3017TrancheGateContextTest`) pins the annotation against a hand-copied literal list, so it
catches *drift between the annotation and the test* and nothing else — both sides can be wrong
together, which is precisely how the Handling Units gap survived.

This is the same defect class as the memory note *"Prose enumerations rot — state the rule"*: the rule
is now stated, which is a genuine improvement, but stating it does not enforce it.

**Suggested rail (cheap, wms2-web-ui side):** a Jest spec that greps the dispatcher file set and
asserts it maps onto a checked-in `{file → menu function}` table, failing when a new file appears.
`test/util/reprentLabelHostSet.spec.js` already does exactly this shape for a different host set and
is a ready template. Out of scope for P5 — offered as a proposal, not a request.

## S4 — LOW / INFORMATIONAL — The ANY-of was already close to "any provisioned WMS user"
**VERIFIED. Pre-existing; P5 does not move it.**

On three of the four databases measured, the **eleven** already admit **100%** of the users in the
authorization graph — prd hydra 7/7, uat `wh01_shipitez_v2` 34/34, uat `wh02_shipitez_v2` 9/9. Only
dev has any user the eleven exclude (49 of 54; the other 5 are mobile-only). Going to fourteen changes
none of those.

So, as an access control, this gate today distinguishes essentially nobody on production. It has value
as a *contract* — it documents which screens legitimately read the roster, and it fails closed for a
future tenant provisioned with narrower roles — but it should not be relied on as a live
confidentiality control, and combined with S1 it is not one.

Worth recording on the ticket so nobody later cites "gated on fourteen functions" as evidence that the
client roster is access-controlled.

## S5 — LOW / INFORMATIONAL — `allClients` builds an unbounded page and throws on an empty tenant
**VERIFIED. Pre-existing; unchanged by P5; noted only because P5 touches this method.**

```java
Long count = clientRepository.count();
Page<Client> clients = clientRepository.findAll(PageRequest.of(0, count.intValue(), Sort.by("name")));
```

Two nits, neither security-critical: the page size is the full row count, bypassing the
`api.paging.max-size` cap the controller's own constructor takes; and on a tenant with zero clients
`PageRequest.of(0, 0)` throws `IllegalArgumentException` ("Page size must not be less than one") → 500.
Unreachable on any populated tenant (hydra prd has 147), so this is a robustness note for a
freshly-cut-over tenant, not a finding against P5. No change requested.

---

## Cleared, explicitly

| Check | Result |
|---|---|
| New users gain `allClients` (dev) | **0 / 0 / 0** — with a proven-non-vacuous instrument |
| New users gain `allClients` (prd hydra) | **0 / 0 / 0** |
| Cross-tenant leak via `findAll()` | **No** — tenant EMF, routing key per tenant+facility, null context → landlord (no `client` table) |
| PII / credentials / API keys in payload | **None** — 12 columns, `additionalcontent` NULL on all 147 prd rows |
| MVC gate genuinely enforced | **Yes** — method-level annotation read before the GUARDED check; `MappedInterceptor` at `/**`; no `@Conditional`; no `@PublicHandler`; `/v3/**` needs `wms_user` |
| Wrong/over-broad function added | **No** — all three verified against `appMenuList.js:78` and `:120` |
| A new widest member introduced | **No** — 45/44/45 vs an existing max of 47 |
| Comment's "15 files / 26 sites @ 9254bf5" | **Reproduced exactly** |
| `super_admin` / `sb_admin` bypass inside the decision | **None** — `checkAnyAccess` is pure list membership |
| SDR sibling route to the same data | **Present and ungated — S1** |

## What I did not do

- **No maven, no tests run** (lane constraint). I have not observed
  `Sbdev3017TrancheGateContextTest` go red or green on this branch; the claim that it pins the set
  by exact equality in both directions is read off the source (`row()` / `resolve()` both normalise
  via `String.join("+", new TreeSet<>(…))`), not measured. The verifier lane owns that.
- **No live HTTP probe of `GET /v3/client`.** S1 is derived from source and from the sysprop values,
  both cited. Per the memory rule *"advertised capability ≠ exploitable capability"*, treat S1 as
  VERIFIED-BY-CONSTRUCTION, not VERIFIED-BY-EXPLOIT. One `curl` with a dev `wms_user` token would
  settle it in seconds and is the single highest-value follow-up measurement in this report.
- **No measurement of the two shipitez PRODUCTION tenant databases** — no MCP for them in this
  session. Their UAT namesakes were measured as a proxy.
