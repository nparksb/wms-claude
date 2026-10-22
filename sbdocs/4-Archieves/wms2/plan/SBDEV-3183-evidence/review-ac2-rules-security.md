---
title: SBDEV-3183 AC-2 — security review of e0bb9412 (Advice / Cyclecount / Location SDR rules)
type: review
ticket: SBDEV-3183
commit: e0bb9412
base: origin/develop 5016bb19
reviewer: security-reviewer lane (independent, read-only, no build run)
date: 2026-10-18
verdict: APPROVE — safe to ship inert at OFF; no blocking findings
---

# SBDEV-3183 AC-2 rules: security review

**Scope:** `git show e0bb9412`: `SdrFunctionRules.java` (3 type rules, 2 Location search overrides), the
`SdrFunctionGuard.java` comment arithmetic, and two unit tests. To trace the paths I also read
`SdrFunctionGuard.evaluate/buildIndex`, `SdrRuleStartupAssertion`, `SdrRuleStartupCheck`,
`LocationRepository`, `AdviceRepository`, `CyclecountRepository`, `RestConfiguration` (Advice exposure),
`AdviceController`, `LocationController`, `CycleCountController`, `AdminController`, the `Location`, `Advice`
and `Cyclecount` models, the full set of exported repositories, spring-data-rest-core 4.5.7 `Path.matches`
and `SearchResourceMappings.getExportedMethodMappingForPath`, and the callers on origin/develop of wms2-web-ui,
wms2-mobile-ui and oms-laravel-api.
**Risk level:** LOW. The commit only narrows access and does nothing until a tenant leaves OFF.

## Verdict

**APPROVE.** I found no path that reaches Advice, Cyclecount or Location through Spring Data REST and skips
the rule once a tenant enforces. Neither override widens anything. No gated search takes a lock. The boot
check refuses to start on a stale override key. At OFF the rules are never read at request time, and the
boot-time checks pass with this source. Every finding below is either pre-existing residual exposure that
this commit narrows, or a hardening or accuracy note. None of them blocks this commit.

## Findings

| ID | Severity | Evidence | Fix |
|---|---|---|---|
| S1 | MEDIUM (pre-existing; this commit narrows it) | The Advice item PATCH is still live: `RestConfiguration.configureAdviceItemVerbWriteExposure` → `httpMethods.disable(HttpMethod.PUT, HttpMethod.DELETE)`. The only field that blocks PATCH binding is `Advice.java:31 @ReadOnlyProperty private String state`. Every other field binds: `clientId`, `type`, `allowoverdelivery`, `allowshortdelivery`, `externalid`, `transferId`, `number`, `purchaseordernumber`. Cyclecount is the same (`Cyclecount.java:31` covers only `state`, while `clientId`, `type`, `subtype`, `number` stay writable). The UI caller sends only `comment` (`closedNoticeDescription.vue` saveComment). Today any wms_user can move an advice to another client or turn on over-delivery. After an enforcing flip, 43 of 100 INBOUND_BOL holders on dev still can. The new rule is now the only fence, and it is a *view* function. | Do it in a follow-up, not here. Move saveComment to a field-scoped MVC endpoint (for example `POST /v3/advice/{id}/comment` with `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL)`) and withdraw the SDR item PATCH. Alternatively add a `@HandleBeforeSave` that refuses changes to anything but `comment`/`note`. Do the same for Cyclecount. |
| S2 | LOW (pre-existing, outside the commit's scope) | The same data is exported through unruled view types. `ReceivingDtoViewRepository` (`@RepositoryRestResource(path = "receivingDtoView")`, searches `findByAdvicenumber`, `findByKeyword`) serves `adviceid`, `advicenumber`, `advicecomment`, `advicesupplier`, `advicedeliverynotenumber` and position quantities. `ViewWarehouseLocationReportRepository` (`path = "viewWarehouseLocationReport"`, `findByKeyword`, `findByLocation`) serves `locationName` with client, SKU and stock quantities. Both appear in the boot log's unruled list, so any wms_user reads them at every mode except FAIL_CLOSED. This is business data, not credentials. | Treat "Advice reads are closed" as true only of the `/advice` entity endpoint, not of the data. Sweep callers for these two view types and rule them in a later slice: ReceivingDtoView most likely on WEB_UI_VIEW_INBOUND_BOL, ViewWarehouseLocationReport on its report screen's function. |
| S3 | LOW (hardening) | An override is checked against its search **path** only: `searches.getExportedMethodMappingForPath(key.searchPath()) == null` (`SdrRuleStartupAssertion.java:90`). Today both overridden methods take no parameters: `LocationRepository.java:99 List<Location> findByGateTrue();` and `:178 List<Location> getAllCrossDockingLanes();`. That is why the overrides cannot be widened by a caller-supplied argument (Q2). If someone later adds an `@Param` to `getAllCrossDockingLanes` (a JPQL `@Query`, so the path stays the same), the override would grant INBOUND_BOL holders a parameterised query, and nothing would flag it. | Add a unit test that uses reflection to assert both overridden repository methods have `getParameterCount() == 0`, with a message pointing at the "SDR cannot bind a parameter to the principal" block in `SdrFunctionRules`. |
| S4 | INFO (accuracy) | The commit body and the rule comment say Advice's "Only SDR caller found: PATCH /advice/{id}". wms2-web-ui `store/receiving/inboundNotices.js:197` also issues `this.$axios.$delete(\`/advice/${...id}\`)`. That call is already a 405, because Advice item DELETE is withdrawn and `AdviceController` has no `@DeleteMapping`. So it does not change the rule's correctness, but the caller sweep missed it. | Correct the comment to "the only *live* SDR caller", and note the dead DELETE call so a later sweep does not re-derive it. |
| S5 | INFO (availability, AC-5 prerequisite) | The rule comment's Cypress note lists PATCH /advice, PATCH /cyclecount and GET /location/{id}. It leaves out `GET /location/search/findByGateTrue`, which is used by `cypress/support/helpers/wmsHelpers.js:77` and the pick-pack, scenario1 step5 and transfer-offsite specs. Under the override that call needs WEB_UI_VIEW_BILL_OF_LADING. | Add BILL_OF_LADING to the Cypress user's prerequisites before the AC-5 flip. |
| S6 | INFO | `LocationRepository.findPutawayCandidates` (around line 417) has no `@RestResource` annotation, so it is exported by default as `/v3/location/search/findPutawayCandidates`. Its sibling `findPutawayCandidatesByName` carries `exported = false`, and its own javadoc calls that annotation load-bearing. The Location type rule now covers the default-exported search. It exposes nothing beyond `GET /v3/location`. | Optional: add `@RestResource(exported = false)` after a caller sweep. If you do, remember the boot check does not watch this search, because it has no override. |

## Answers to the five questions

### Q1. Can a caller reach these types without the rule once a tenant enforces? No.

- **Domain type comes from the dispatch.** `SdrFunctionGuard.evaluate` reads `{repository}` from
  `URI_TEMPLATE_VARIABLES_ATTRIBUTE` and looks it up in an exact-match index of exported paths
  (`buildIndex`, "exact match only"). The lookup does not depend on the verb: there is no HTTP-method check
  anywhere in `evaluate`. So item GET, PATCH, DELETE, HEAD, non-preflight OPTIONS, the collection, `/search`,
  `/search/{search}`, `/{id}/{property}` and `/profile/{repository}` all resolve to the same domain type and
  the same rule. A real CORS preflight is short-circuited by `PreFlightHttpRequestHandler` and never reaches
  data.
- **Association paths.** `Location`, `Advice` and `Cyclecount` declare no `@ManyToOne`, `@OneToMany`,
  `@OneToOne` or `@ManyToMany`. In all of `model/`, only `User`, `UserRole`, `UserGroup` and `OutboxMessage`
  have such annotations, and `OutboxMessage`'s one hit is a comment saying there are none. So no
  `/x/{id}/{assoc}` path resolves *to* these types from an unruled owner. Their own association routes resolve
  the owning type, which is ruled.
- **Projections and excerpts.** There is no `@Projection` anywhere in `src/main`, so `?projection=` cannot
  reshape another type to embed these entities.
- **Other repositories returning these entities.** No exported repository other than the three owners has a
  method returning `Location`, `Advice` or `Cyclecount` (I grepped `List|Page|Optional<…>` and bare return
  types). The surviving exposure is *view* types that copy columns; see S2.
- **Path variants.** A wrongly-cased `{repository}` gets no handler from SDR and never reaches the guard. If
  one ever did, the guard's exact index would miss it and row 6 would deny it at enforcing modes, which is the
  fail-closed direction. `{search}` is matched by `Path.matches` = `this.path.matches("/?" + Pattern.quote(ref))`,
  which is exact and case-sensitive. If the override key misses, the code falls through to the **type** rule
  (STORAGE_LOCATION), which is still a gate, never open. Encoded values arrive already decoded. Tomcat rejects
  an encoded `/` by default, so `{search}` cannot carry the regex's optional leading slash.
- **MVC shadows.** `AdviceController` (`/v3/advice`), `LocationController` (`/v3/location`) and
  `CycleCountController` (`/v3/cycleCount`) have no `/{id}` mapping and no verb-on-root mapping. Every handler
  in them carries `@RequiresFunction`, using the same functions this commit uses. Their inherited
  `AdminController` mappings land under `/v3/advice/user/...` and similar paths, which are user-admin
  endpoints and not these entities. Nothing shadows an SDR item or search route for these types.

### Q2. Does an override make anything wider than intended? No.

Both overridden searches take no parameters (`findByGateTrue()`, `getAllCrossDockingLanes()`). Both are plain
reads that return a fixed predicate subset: `gate = true`, and `crossdockinglane = true ORDER BY name`. The
`Location` fields are warehouse metadata (name, coordinates, lane flags, `clientId`, `areaId`, `rackId`,
`typeId`, `entityLock`) and include no credentials or PII. A BOL or inbound clerk needs exactly these lists
for the dispatching screens. Each override **replaces** the type rule rather than adding to it, so a
STORAGE_LOCATION-only user loses these two searches. That is narrower, not wider. HAL `_links` in the response
point at `/location/{id}`, which stays on the type rule. The override has no parameter, so it does not have
the "parameter not bound to the principal" defect that `SdrFunctionRules` documents for `findByUsername` and
`findByGroupname`. S3 covers keeping it that way.

### Q3. Do any of these searches take a lock? No.

The only `@Lock(PESSIMISTIC_WRITE)` methods in `LocationRepository` are `findByIdForUpdate` (`:122`) and
`getAvailableTransferLanesForUpdate` (`:147`). Both are `@RestResource(exported = false)`. A case-insensitive
grep for `for update|@Lock|SKIP LOCKED|QueryHints` finds nothing in `AdviceRepository` or
`CyclecountRepository`. The only `@Modifying` there is `updateAdviceToStateById`, which is
`exported = false`. Neither override target locks. Both are unpaged `List` reads over small predicate subsets.

### Q4. Does the startup assertion refuse to boot on a stale override key? Yes.

`SdrRuleStartupCheck.afterSingletonsInstantiated` adds `findUnresolvableOverrides` to its problem list and
throws `IllegalStateException` when the list is not empty. `findUnresolvableOverrides` flags these cases:
- a domain type that is not exported;
- a `getSearchResourceMappings` call that throws (reported, not swallowed);
- `getExportedMethodMappingForPath(key.searchPath()) == null`. That method checks `mapping.isExported()`,
  so a search withdrawn with `exported = false` also fails the boot.

`findUnknownFunctions` covers the override values too (`rules.overrideKeys()` loop), so a typo in a function
name also refuses boot. CI covers it in three ways:
- `SdrRuleInventoryContextTest.everyOverrideKeyResolvesToALiveSearch` runs against the real mappings;
- `productionOverridesAreExactlyTheLocationPair` pins the exact key set;
- existing unit tests cover the unresolvable cases.

The only skip is `ResourceMappings == null`, which logs a WARN and returns. That happens only in narrowed
test contexts, and in that state no SDR handler exists to dispatch. Limitation: the check validates the
search's name, not its signature (S3).

### Q5. Is anything unsafe about shipping this while inert at OFF? No.

`evaluate` returns at `if (mode == SdrGuardMode.OFF) return SdrVerdict.allow(...)`, before it reads the
rules. Only the boot-time checks run regardless of mode, and they pass with this source:
- `Advice`, `Cyclecount` and `Location` are all among the 35 exported repositories (enumerated from
  `@RepositoryRestResource` without class-level `exported = false`);
- both override paths are exported `@RestResource(path=…)` searches;
- all four functions are `WmsConstants.FunctionEnum` constants (they compile, and existing MVC handlers
  already use them).

So the only way this commit could change behaviour at OFF is a boot failure, and the source rules that out.
The three-number arithmetic in the comments (35 / 11 / 24) matches my enumeration: 35 exported,
8 + 3 = 11 ruled.

## Security checklist

- [x] No hardcoded secrets in the diff (diff is rule tables, comments, tests)
- [x] Inputs: overridden searches take no caller parameters
- [x] Injection: no new queries; existing ones are parameterised JPQL or derived
- [x] Authorization: the verb-blind guard covers every SDR route shape for the three types. Residual
      mass-assignment on PATCH is S1 (pre-existing)
- [ ] Dependency audit: not run (the caller said read-only and no build). The commit changes no dependencies
