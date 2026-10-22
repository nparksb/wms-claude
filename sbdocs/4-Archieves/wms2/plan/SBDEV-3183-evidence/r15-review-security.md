---
ticket: SBDEV-3183
lane: security
round: r15
reviewed: git diff a49e6ebd..HEAD (38a1c1ac) in .claude/worktrees/wms2-api/SBDEV-3183-r15
date: 2026-10-21
verdict: APPROVE (no Critical/High/Medium; 6 Low)
---

# Security Review Report — SBDEV-3183 r15 (15 more SDR read rules + 2 search overrides)

**Scope:** `SdrFunctionRules.java` (15 type rules, Printer/findByType and ReceivingDtoView/findByKeyword
overrides), `SdrFunctionGuard.java` (comments only), `CustomerorderForceCancelOutboxIntegrationTest`
(@MockitoBean → @MockitoSpyBean), three unit tests. Cross-checked against wms2-web-ui `origin/develop`
(add0628, 2026-10-16), wms2-mobile-ui `origin/develop` (f51dc6c), oms-laravel-api `origin/develop` (26a301ac),
siteboss-frontend, SDR 4.5.7 sources (`Path.matches`, `SearchResourceMappings`).
Read-only: no mvn, no file in the worktree touched. (Note: one `git fetch` was run in v2/wms2-mobile-ui to read
its origin/develop; that updates remote refs only.)

**Risk Level:** LOW

## Summary
- Critical: 0 · High: 0 · Medium: 0 · Low: 6
- The change is additive and only narrows: every new rule turns a previously-unruled (allowed below
  FAIL_CLOSED) type into a ruled one. No path was found by which a ruled type's rows are served by an unruled
  SDR path. Both overrides are keyed on exactly the string SDR dispatches on, and a key mismatch falls back to
  the type rule, never to "open".
- Dependency audit / secrets scan: not re-run — the diff adds no dependency and no literal credential
  (grepped the diff: no key/password/token literals). Out of scope for this delta.

## Answers to the five questions

### Q1. Override widening

**Printer/findByType → {PRINTER, INBOUND_BOL, CLIENT, PARCEL_PICKING}: ACCEPTABLE (Low, L1).**
`net/aim_ai/wms/model/Printer.java` carries only `number, name, address, clientId (client_id), type,
processdefault` (+ AbstractBaseEntity id/version/timestamps). No credential, token or secret field. `address`
is a printer host/IP/queue — network-topology information, low sensitivity. `findByType` is a derived
equality query (no LIKE), so enumerating requires the type values; there are five
(`WmsConstants.PrinterType`: INBOUND, RETURN, OUTBOUND_TOTE, OUTBOUND_PALLET, LOCATION) plus `?type=` which a
derived finder turns into `type IS NULL`. So yes: a holder of any of the four can read every printer row in
≤6 requests. That is not a new class of exposure:
- `PrinterController#outboundTotePrinters` already serves OUTBOUND_TOTE rows to `{PRINTER, ORDER_MONITOR}`,
  `#inboundPrinters` serves INBOUND rows to `{PRINTER, CONTAINER, CLUB_LINE, TRANSFER_ORDER}`.
- `PrinterRestController` `GET /rest/printer/findByType` serves any type with no token (internal surface,
  JWT deferred by decision — see L2).
No need to move to an MVC endpoint. If it is ever wanted, the narrow shape is a type-allow-listed MVC endpoint
per screen (`/v3/printer/inboundPrinters` already exists and is exactly what the three INBOUND callers need).

**ReceivingDtoView/findByKeyword → {RECEIVED_STOCK_OVERVIEW}: ACCEPTABLE.**
Confirmed in `ReceivingDtoViewRepository.java`:
```java
" WHERE (... LIKE LOWER(concat('%', COALESCE(:keyword, ''),'%')) or :keyword IS NULL or :keyword = '')" +
" AND (p.clientid = :clientNumber OR :clientNumber IS NULL OR :clientNumber = '') "
```
Empty/absent `keyword` and `clientNumber` ⇒ all rows (paged). That is exactly the Receiving Report's dataset,
which the RECEIVED_STOCK_OVERVIEW holder is entitled to see. The query is JPQL over `ReceivingDtoView` only and
returns `Page<ReceivingDtoView>`, so nothing beyond the receiving view is reachable. The override is
search-scoped: the same holder still needs INBOUND_BOL for the collection (`GET /receivingDtoView`), item and the
other two searches (`requiredFunctions` falls through to `rules.get(domainType)`). The two withdrawn methods
(`findByClientOffsetAndLimit`, `getQtyByAdvicenumber`) are `exported = false` and unaffected.

### Q2. Can a ruled type's data be reached via an unruled path? — No (verified)
- **Association links:** only `User`, `UserRole`, `UserGroup` carry `@ManyToMany`; the `@EmbeddedId` types
  are join rows. None of the 15 is an association target or owner
  (`grep -rnE "@(ManyToOne|OneToMany|OneToOne|ManyToMany|ElementCollection|Embedded|EmbeddedId)" model/`).
  The guard comment's claim holds.
- **Projections / excerpts:** the only `@Projection`/`excerptProjection` is in `UserRepository`. None
  references the 15.
- **Other repositories embedding/returning these entities:** grep across `repo/` for any
  `List|Optional|Page|Set|Iterable|Collection<T>` or bare `T method(` return of the 15 types in a repository other
  than `TRepository`: zero hits. No unruled repository's search serves their rows.
- **Second repository exporting the same domain type:** each of the 15 has exactly one repository
  (`Repository<T,` count = 1 for all 15).
- **/profile and /search listing:** `/profile/{repository}` and `/{repository}/search` carry `{repository}`
  but no `{search}`, so they resolve to the type rule (metadata only, no rows anyway). The `/v3` root index is
  row 3 (deny when enforcing).
- **Override path matching:** `SearchOverrideKey` is matched with `Map.get` on the `{search}` URI template
  variable, case-sensitive. SDR resolves the search with `Path.matches` = regex `"/?" + Pattern.quote(ref)`
  (SDR 4.5.7 `Path.java:32,62`) — also exact and case-sensitive. Both read the SAME value from
  `HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE` (the guard via `uriVariable`, SDR via `@PathVariable`), so
  percent-encoding, matrix-parameter stripping and trailing-slash handling are applied identically before
  either sees it. A case variant (`findbytype`) is not dispatched by SDR at all. Any divergence would land on
  the type rule (PRINTER_VIEW / INBOUND_BOL_VIEW), never on "no rule". No prefix match exists anywhere in the
  lookup.

### Q3. Non-overridden searches fall back to the type rule — Yes
`SdrFunctionRules.requiredFunctions(Class, String)`:
```java
if (searchPath != null) {
    Set<String> override = searchOverrides.get(new SearchOverrideKey(domainType, searchPath));
    if (override != null) { return Optional.of(override); }
}
return Optional.ofNullable(rules.get(domainType));
```
`/printer/search/findByTypeAndProcessdefaultTrue` and `findAllTypeAndProcessdefaultTrue` → PRINTER_VIEW;
`/receivingDtoView/search/findByAdvicenumber` and `findByAdvicepositionid` → INBOUND_BOL_VIEW. Not open.

### Q4. Rule breadth vs wms2-web-ui callers (origin/develop add0628)
Every live SDR read of the 15 maps to a screen whose `util/appMenuList.js` gate is in the rule's set:

| Resource | Live caller → route gate | Rule | OK |
|---|---|---|---|
| /goodsreceiptposition | inboundNotices.js:349 → INBOUND_BOL | INBOUND_BOL | yes |
| /itemunit | skuUnit.js:51 → ITEM_UNIT; packaging.js:78 → CASE_TYPE | ITEM_UNIT, CASE_TYPE | yes |
| /locationArea | functionalArea.js:51 → AREA; createCc.js:55 → CYCLECOUNT | AREA, CYCLECOUNT | yes |
| /locationRack | storageLocation.js:106 (not dispatched) | STORAGE_LOCATION | yes |
| /locationType | locationType.js:51 → STORAGE_LOCATION_TYPE | same | yes |
| /lockOverview(All)DtoView | lock.js:56 → STOCK_UNIT_LOCK_OVERVIEW | same, both | yes |
| /printer | printerSetup.vue:217 → PRINTER; editUser.vue:121 → USER_MANAGEMENT | PRINTER, USER_MANAGEMENT | yes |
| /printer/search/findByType | openNoticeTable.vue:273 (INBOUND_BOL), add/editShipper.vue (CLIENT), parcelPicking.js:116 (PARCEL_PICKING) | override, 4 | yes |
| /receivingDtoView search ×2 | inboundNotices.js:318, receivingForm.vue:615 → INBOUND_BOL | INBOUND_BOL | yes |
| /receivingDtoView/search/findByKeyword | receiving.js:61 → RECEIVED_STOCK_OVERVIEW (data.js:26 not dispatched) | override | yes |
| /replenishorder/{id} | replenishments.js:192 → REPLENISHMENT_ORDER | same | yes |
| /stockView | inventory.js:69 → INVENTORY_RECORD | same | yes |
| /unitload | container.js:142 (commented-out dispatch) | STOCK_UNIT, CONTAINER | yes |
| /unitloadRecord | container.js(reports):49 → UNIT_LOAD_RECORD | same | yes |
| /unitloadType | unitLoadType.js:51 → UNIT_LOAD_TYPE; **createPo.js:82 (not dispatched — see L4)** | UNIT_LOAD_TYPE | yes |
| /viewWarehouseLocationReport | skuLocation.js:69 → LOCATION_OVERVIEW | same | yes |

wms2-mobile-ui origin/develop: zero SDR reads of the 15. oms-laravel-api origin/develop: zero v3 SDR reads of
the 15 (Printer default is `/rest/printer/findByType`; see L3). siteboss-frontend: zero.
No rule is too broad relative to its callers beyond L1/L5; no entitled UI user is locked out.

### Q5. @MockitoBean → @MockitoSpyBean: any production fail-open? — No
Mechanism: `@MockitoBean` replaces the repository's bean DEFINITION (the `JpaRepositoryFactoryBean`) with a
bare mock. Spring Data's `Repositories` discovers repositories through `RepositoryFactoryInformation` beans, so
with the factory bean gone, `Unitload` is known only as a persistent entity and SDR maps it via entity metadata
with `isExported() == false`. In production nothing replaces repository bean definitions: no `@Bean` method
returns a `*Repository`, and there is no custom `BeanPostProcessor`/`BeanDefinitionRegistryPostProcessor` in
`src/main` (grepped). AOP proxies (`@Transactional`, method security, metrics) wrap the factory's PRODUCT, not
the `RepositoryFactoryInformation` bean, so they cannot un-export a repository.
And it fails closed if it ever did happen: (a) an un-exported type has no SDR surface at all —
`RepositoryRestHandlerMapping` will not dispatch it, so no rows are served; (b) `SdrRuleStartupCheck` throws
`IllegalStateException` for a ruled-but-unexported type, refusing boot. The one tolerated case is a context with
NO `ResourceMappings` bean (warn + return), which is pre-existing and also has no SDR surface.
No other test `@MockitoBean`/`@MockBean`s any of the 18 ruled-by-3183 repositories (grepped `src/test`), so no
second IT will hit the same boot refusal.

## Findings (all Low)

### L1. findByType override lets any of four functions read every printer row
**Severity:** LOW · **Category:** A01 Broken Access Control (horizontal widening, accepted)
**Location:** `src/main/java/net/aim_ai/wms/security/SdrFunctionRules.java` (`PRINTER_BY_TYPE_VIEW`,
`productionOverrides()` Printer/findByType)
**Exploitability:** remote, authenticated `wms_user` holding INBOUND_BOL, CLIENT or PARCEL_PICKING, tenant at
SHADOW-or-higher (at OFF nothing is gated anyway).
**Blast radius:** printer `number/name/address/client_id/type/processdefault` for the warehouse. No secrets.
**Issue:**
```java
// type is a filter, not a scope: a holder can read every printer row by iterating types
overrides.put(new SearchOverrideKey(net.aim_ai.wms.model.Printer.class, "findByType"), PRINTER_BY_TYPE_VIEW);
```
**Remediation (optional, not required for merge):** point the three INBOUND callers at the existing
`/v3/printer/inboundPrinters` and Parcel Picking at `/v3/printer/outboundTotePrinters` (add PARCEL_PICKING to
its any-of), then drop the override so `findByType` falls back to PRINTER_VIEW:
```java
// BAD (any type, four functions)
overrides.put(new SearchOverrideKey(Printer.class, "findByType"), PRINTER_BY_TYPE_VIEW);
// GOOD — type fixed server-side, per caller
@RequiresFunction({WEB_UI_VIEW_PRINTER, WEB_UI_VIEW_ORDER_MONITOR, WEB_UI_VIEW_PARCEL_PICKING})
@GetMapping("/outboundTotePrinters")
public List<Printer> outboundTotePrinters() { return printerRepository.findByType(PrinterType.OUTBOUND_TOTE); }
```

### L2. Printer gate is defence-in-depth only: an unauthenticated /rest twin serves the same rows
**Severity:** LOW (pre-existing, decided deferral — record, do not fix here) · **Category:** A01
**Location:** `src/main/java/net/aim_ai/wms/controller/rest/PrinterRestController.java:41`
```java
@GetMapping(value = "/findByType", produces = "application/json")
public ResponseEntity<List<Printer>> findByType(@RequestParam("type") String type) {
```
**Issue:** `/rest/**` is internal-only and its JWT gating is deferred by Nam pending the OMS-team plan
(2026-08-27, reaffirmed 2026-09-02). Do not claim the Printer read capability is "closed" by this change; it is
closed for the `/v3` SDR copy only. **Remediation:** none in this ticket; covered by the deferred `/rest` JWT work.

### L3. OMS printer read is one env var away from being denied once a PRD tenant enforces
**Severity:** LOW (availability, fail-closed) · **Category:** A05 Security Misconfiguration
**Location:** `SdrFunctionRules.java` "OMS CAVEAT" comment; oms-laravel-api `config/wms.php:226`,
`app/Services/WmsApiService.php:3018` ("stays env-overridable to v3/printer/search/findByType").
**Issue:** if any untracked PRD OMS env sets `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT=v3/printer/search/findByType`,
the OMS identity (no WEB_UI functions) is denied at ENFORCE. Direction is safe (deny), but the OMS QA return flow
breaks. **Remediation:** make it a checklist item of the per-tenant SHADOW→ENFORCE flip (read the deployed OMS
env, or check SHADOW would-deny logs for the OMS user on `SDR[Printer]` before flipping). Optionally remove the
env override from OMS so the SDR path cannot be reselected.

### L4. Dead UI action would be denied for Receiving users if revived (/unitloadType)
**Severity:** LOW (latent lockout, no live impact) · **Category:** A04 Insecure Design (rule-to-caller drift)
**Location:** wms2-web-ui `store/receiving/createPo.js:80-82` (origin/develop)
```js
async getUnitLoadTypes(context) {
  const results = await this.$axios.$get('/unitloadType')
```
**Issue:** not in the implementation report's caller list for UnitloadType. `receiving/createPo/getUnitLoadTypes`
is dispatched nowhere today (only `masterData/unitLoadType/getUnitLoadTypes` is), so no current lockout. If
Create PO ever dispatches it, an INBOUND_BOL-only user gets 403 at ENFORCE. **Remediation:** record it in the
sweep evidence as a known dead caller (or delete the action in web-ui) so a revival is a conscious rule change.

### L5. Override parameter pin does not pin the return type / query shape
**Severity:** LOW · **Category:** A04 Insecure Design (regression guard gap)
**Location:** `src/test/java/net/aim_ai/wms/unit/security/SdrFunctionRulesUnitTest.java:352`
(`REVIEWED_OVERRIDE_PARAMETERS`)
**Issue:** the guard goes red if a parameter is added, but not if `findByKeyword` is changed to return an
interface projection over a native query joining other tables (e.g. the `ReceivingQtyView` pattern already in
the same repository). The override's holders would then read joined data that was never reviewed, while the
boot check and this test stay green. Same for Printer/findByType.
**Remediation:**
```java
// GOOD — pin the generic return type too
assertThat(matches.get(0).getGenericReturnType().getTypeName())
        .isEqualTo(REVIEWED_OVERRIDE_RETURN_TYPES.get(key)); // e.g. "java.util.List<net.aim_ai.wms.model.Printer>",
                                                            // "org.springframework.data.domain.Page<net.aim_ai.wms.model.ReceivingDtoView>"
```
Optionally also assert `nativeQuery == false` on the `@Query` for overridden methods.

### L6. PRINTER_VIEW grants USER_MANAGEMENT holders the full printer collection
**Severity:** LOW (justified by a live caller) · **Category:** A01
**Location:** `SdrFunctionRules.java` `PRINTER_VIEW = ordered(WEB_UI_VIEW_PRINTER, WEB_UI_VIEW_USER_MANAGEMENT)`
**Issue:** needed because `components/admin/userManagement/users/editUser.vue:121` dispatches
`admin/printer/getPrinters` (`GET /printer`) to populate a user's default printer. Consequence: user
administrators also read printer item/collection and the two un-called searches. Low-value data; acceptable.
**Remediation (optional):** if narrowing is ever wanted, give editUser a projection endpoint returning
`{id, name}` only and drop USER_MANAGEMENT from the type rule.

## Notes (not findings)
- The Cypress caveat in the rule comment is correct: once a Cypress tenant enforces, its test user must hold
  STOCK_UNIT|CONTAINER (Unitload), AREA|CYCLECOUNT (LocationArea) and the report functions.
- `Goodsreceiptposition` malformed caller path (`.../search/findByAdvicepositionId/…`): with no `{search}`
  variable it is either a 404 or dispatched to the property-reference controller with `{repository}` set; either
  way the type rule applies. No bypass.
- Not swept: MVC `/v3` siblings of all 15 types for ungated reads (outside this diff). Spot-checked
  `UnitLoadController` detail reads and `PrinterController`/`LabelPrintingController`: all gated.

## Security Checklist
- [x] No hardcoded secrets in the diff
- [x] Inputs: override keys exact-matched; same `{search}` value used by guard and SDR
- [x] Injection: findByKeyword is parameterised JPQL; no change to queries
- [x] Authorization: 15 rules fail toward deny; overrides fall back to type rule; no association/projection/
      foreign-repository path to the 15 types
- [x] Startup integrity: ruled-but-unexported refuses boot; no production path un-exports a repository
- [ ] Dependencies audited — not applicable to this delta (no dependency change); not re-run
