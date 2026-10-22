# SBDEV-3183 — security review of `6280d34c..c4e18173`

**Lane:** independent security review (`sec-mod`)
**Range reviewed:** `2a71843c` (stale-prose fixes) and `c4e18173` (nine `@Modifying` searches un-exported + invariant test).
**Base:** `origin/develop` @ `452d3ed4`. **Repo:** `v2/wms2-api`, Java 21 / Spring Boot 3.5.9.
**Date:** 2026-09-01. **Mode:** read-only on the reviewed worktree; all builds run in a separate detached worktree.

---

## 0. Instruments — what I RAN vs what I READ

### RAN

| # | Instrument | Result |
|---|---|---|
| R1 | `mvn -o test -Dtest=SdrModifyingSearchNotExportedContextTest` at `c4e18173`, in a detached worktree at `/tmp/.../scratchpad/wt-sec-mod` | **GREEN** — `Tests run: 1, Failures: 0, Errors: 0, Time elapsed: 45.64 s` |
| R2 | **Mutation check** — re-exported *two* methods (`Customerorder.updateStateByIds`, `Client.toggleEnableReceivingById`) and re-ran R1 | **RED, both mutants caught.** Reported exactly `GET /v3/client/search/toggleEnableReceivingById -> Client.toggleEnableReceivingById` and `GET /v3/customerorder/search/updateStateByIds -> Customerorder.updateStateByIds`. Route strings render with single slashes — the path-concatenation bug the test's own comment warns about is not present. |
| R3 | Python scan of all **66** files in `src/main/java/net/aim_ai/wms/repo/jpa/`: every `@Modifying` method, every `@Query` whose text contains `UPDATE`/`INSERT`/`DELETE` without `@Modifying`, every native `@Query` invoking a DB function | see §5 |
| R4 | DB probe on `dev_wh01_om1` (MCP `wms2-wineco-dev`): `pg_proc.provolatile` + `prosrc` DML regex for `transaction_summary`, `transaction_detail`, `stock_history` | see §5 |
| R5 | Cross-repo `git grep` at `origin/develop` of `wms2-web-ui` (`3117aca`), `wms2-mobile-ui` (`c79e81c`), `oms-laravel-api` (`be0f6a8b`) — bare method names, no leading-slash anchor — plus a same-field sweep (`enablereceiving`, `printerreceivingId`, customerorder/advice `state`, replenishorder `prio`) | see §1, §4 |

### READ (not executed)

- `wms2-api` `src/main` + `src/test` at `c4e18173`.
- Library sources from `~/.m2`: `spring-data-commons-3.5.7-sources.jar`, `spring-data-rest-core-4.5.7-sources.jar`, `spring-data-rest-webmvc-4.5.7-sources.jar`, `spring-orm-6.2.15-sources.jar`; `hibernate-core-6.6.39.Final.jar` (class-constant strings — `javap` is not on PATH in this environment, so bytecode was inspected by string extraction only).

### NOT done — where a live environment is required

1. **No live HTTP probe.** Every statement about what a request returns (200 / 404 / 500) is derived from library source, not observed. §2's verdict in particular would be settled in one minute by issuing `GET /v3/customerorder/search/updateStateByIds?ids=<id>&state=10` against a pre-fix build on dev.
2. **No live PATCH probe** of the residual routes in §1. Per [[sdr-write-verb-probes-400-proves-nothing]] and [[advertised-capability-is-not-exploitable-capability]], the exposure claims in §1 are *derived from configuration* (`SDR_WRITE_WITHDRAWN` membership, `SdrFunctionRules` coverage, `SecurityConfiguration` matchers) and are **advertised** capability. Confirming they are exploitable requires an actual write with a zero-function `wms_user` token.
3. **Full suite not run** — only the one new test class. Regression risk elsewhere is assessed by call-graph reading (§3), not by a suite comparison against the develop baseline.

---

## 1. Is the capability closed, or only this mechanism?

**Short answer: only this mechanism, and for three of the five mutations the capability is trivially reproducible at the *same* privilege level by a different verb on the same entity.** The commit is still correct and should ship — but it must not be described as closing these mutations.

Load-bearing configuration facts, all read at `c4e18173`:

- `RestConfiguration.java:355` `SDR_WRITE_WITHDRAWN` — contains `Customerorder` and `Replenishorder`. **Does not contain `Client` or `Advice`.** (`Adviceposition` is in the list; `Advice` is not — easy to misread.)
- `SdrFunctionRules.java:176–202` — rules exist for exactly five types: `User`, `UserFunction`, `UserGroup`, `UserGroupUser`, `UserRole`. Nothing else is ruled.
- `SdrFunctionGuard.java:210` — `if (mode == SdrGuardMode.OFF) { … }` short-circuits; OFF is the shipped default, so no rule enforces anything today anyway.
- `SecurityConfiguration.java:179` — `.requestMatchers("/v3/**", "/putawayConfig/**").hasAnyAuthority(Authority.WMS_USER_ROLE)`. Every `/v3/**` route, SDR included, requires only the `wms_user` role — **zero functions**.
- `SecurityConfiguration.java:151` — `"/rest/**"` is inside a `.permitAll()` matcher list, i.e. the internal surface is **unauthenticated**. Per [[wms2-rest-surface-internal-only-jwt-deferred]] this is an accepted decision, not a new finding; it is recorded here because it changes the shape of the enumeration.

| Mutation | Closed by this commit? | Remaining reachable paths for an authenticated `wms_user` holding ZERO functions |
|---|---|---|
| `customerorder.state` (arbitrary value, arbitrary id set) | Search route gone | **None found for the arbitrary form.** SDR item/collection writes were withdrawn by `6280d34c` (`Customerorder` ∈ `SDR_WRITE_WITHDRAWN`, `WRITE_VERBS` = POST/PUT/PATCH/DELETE, `RestConfiguration:28`). `CustomerOrderController` (`/v3/customerOrder`) exposes three write routes, all `@RequiresFunction`-gated (`:61`, `:89`, `:114`), none of which sets an arbitrary state. `UtilRestController` sets `State.RAW` at `:1092–1099` but is annotated **`@Service`, not `@RestController`** — its mappings do not route ([[wms2-utilrestcontroller-is-service-not-restcontroller]]). |
| `advice.state` | Search route gone | 🔴 **`PATCH /v3/advice/{id}` with `{"state": "<anything>"}`.** `Advice` is not in `SDR_WRITE_WITHDRAWN`, is not ruled, and `Advice.java:22` declares `private String state` with no `@JsonIgnore` / `@ReadOnlyProperty`. It is deliberately on `SdrWriteWithdrawalContextTest`'s `MUST_STAY_WRITABLE` list because `wms2-web-ui store/receiving/inboundNotices.js:380` does `$axios.$patch('/advice/' + data.id, data)`. **The capability is fully intact and the value is not even constrained to the `AdviceState` vocabulary** — it is a free `String`. |
| `replenishorder.prio` (3 methods) | Search routes gone | `POST /v3/replenishOrder/updatePriority` and `/update` — both `@RequiresFunction(WEB_UI_VIEW_REPLENISHMENT_ORDER)` (`ReplenishOrderController.java:142`, `:78`). SDR item writes are withdrawn (`Replenishorder` ∈ `SDR_WRITE_WITHDRAWN`). **Effectively closed** for a zero-function actor. |
| `client.enablereceiving` | Search route gone | 🔴 **`PATCH /v3/client/{id}` with `{"enablereceiving": false}`.** `Client` is not in `SDR_WRITE_WITHDRAWN`, is not ruled. `Client.java:20` — plain `Boolean enablereceiving`, no read-only annotation. The MVC twin `POST /v3/client/toggleReceiving` **is** gated (`ClientController.java:174`), so the gate and the un-export together leave the SDR PATCH as the open door. Also `POST /v3/client/create` (`ClientController.java:89`) carries **no `@RequiresFunction`** and accepts `enablereceiving` — creation only, not modification of an existing client, but it is an ungated `Client` write. |
| `client.printerreceivingId` | Search route gone | 🔴 **`PATCH /v3/client/{id}` with `{"printerreceivingId": null}`.** Same reasoning. MVC twins `POST /v3/client/setPrinter` (`ClientController.java:154`) and `GET /v3/printer/delete/{id}` (`PrinterController.java:155`) are both gated. `POST /v3/client/create` again accepts the field ungated. |

**Association endpoints / cascades / event handlers.** SDR generates exactly three association resources repo-wide (`User.groups`, `UserGroup.roles`, `UserRole.functions` — the only `@ManyToMany @JoinTable` mappings; `RestConfiguration:445` comment, consistent with what I read). None touches these five fields. The only `@RepositoryEventHandler` beans are `SdrCacheEvictionEventHandler` and `PutawayConfigRepositoryEventHandler`, both eviction-only — neither writes a domain field.

### What this enumeration method CANNOT see

- **Transitive mutation through business routes.** I enumerated *direct* writers of the five fields. A gated business route that legitimately sets `customerorder.state` as a side effect (e.g. a picking or BOL transition) is not counted, because it is not the arbitrary-value capability. If the question is "can a zero-function user move an order's state at all by any route", this review does not answer it.
- **`/rest/**`.** Unauthenticated by configuration. `AdviceRestController` sets `AdviceState.OPEN` at `:269, :401, :500, :531, :627, :689` — on create/import flows, not arbitrary. I did not exhaustively enumerate that surface; it is out of scope by the standing decision.
- **Anything reached by reflection, SpEL, or a dynamically-registered handler.** Not searchable by grep.

---

## 2. Severity calibration — did the pre-fix bulk UPDATEs actually commit?

**The nine split cleanly in two, and the split is decided by one annotation.** This is a code derivation; see §0 item 1 for the live probe that would settle it.

### The chain

1. `RepositorySearchController` (spring-data-rest-webmvc 4.5.7) declares **no `@Transactional`** and only `GET`/`OPTIONS`/`HEAD` mappings (`:101, :118, :134, :163, :226, :264, :283`). It never calls `verifySupportedMethod` — confirming the brief's premise. `ResourceType` really is `COLLECTION, ITEM;` only (`ResourceType.java:25`), so `ExposureConfiguration` structurally cannot reach a search.
2. `spring.jpa.open-in-view=false` (`src/main/resources/application.properties:67`, and the same in `application-integration.properties:31`). **No OSIV EntityManager is bound**, so nothing outside the repository proxy supplies a transaction.
3. `@EnableJpaRepositories(basePackages = "net.aim_ai.wms.repo.jpa", transactionManagerRef = "tenantTransactionManager")` — `TenantDatabaseConfig.java:22–25`. `enableDefaultTransactions` is **not** set, so it defaults to `true`.
4. `TransactionalRepositoryProxyPostProcessor.RepositoryAnnotationTransactionAttributeSource.computeTransactionAttribute` (spring-data-commons 3.5.7). For a `@Query` method the target class is `SimpleJpaRepository`, which does not declare it, so `ClassUtils.getMostSpecificMethod` returns the interface method and the class-level `@Transactional(readOnly = true)` on `SimpleJpaRepository` is **never consulted**. The last fallback is:

   ```java
   Method targetClassMethod = repositoryInformation.getTargetClassMethod(method);
   if (targetClassMethod.equals(method)) {
       return null;
   }
   ```

   `DefaultRepositoryInformation.getTargetClassMethod:72` — `composition.findMethod(method).orElse(method)` — returns the method itself for a query method with no implementation counterpart. **So the attribute is `null` and the `TransactionInterceptor` starts no transaction.**
5. None of `CustomerorderRepository`, `ReplenishorderRepository`, `ClientRepository`, `AdviceRepository` carries an interface-level `@Transactional` (checked individually).
6. With no transaction, `SharedEntityManagerCreator` creates a fresh `EntityManager` (`executeUpdate` is in `queryTerminatingMethods`, **not** in `transactionRequiringMethods`, so Spring itself does not block it — `SharedEntityManagerCreator.java:77–86`). Hibernate then does. `hibernate-core-6.6.39.Final` `AbstractSharedSessionContract` carries the constant *"Query requires transaction be in progress, but no transaction is known to be in progress"* and the field `allowOutOfTransactionUpdateOperations`; `hibernate.allow_update_outside_transaction` is **not set anywhere** in this repo's resources, so it is `false`.

### Verdict

| Method | `@Transactional` on the method? | Pre-fix runtime outcome (derived) |
|---|---|---|
| `Customerorder.updateStateByIds` | ❌ | `TransactionRequiredException` → **HTTP 500, no mutation** |
| `Customerorder.markClientHasNoSection` | ❌ | same |
| `Customerorder.releaseDueFutureTransferOrders` | ❌ | same |
| `Replenishorder.updatePriorityByIdIn` | ❌ | same |
| `Replenishorder.bulkUpdatePriorityForItems` | ❌ | same |
| `Replenishorder.bulkUpdatePriorityForItemsWithOldPriority` | ❌ | same |
| `Advice.updateAdviceToStateById` | ✅ `@Transactional` (`AdviceRepository.java:29`) | **REQUIRED, readOnly = false, `tenantTransactionManager` → real committed mutation** |
| `Client.toggleEnableReceivingById` | ✅ (`ClientRepository.java:69`) | **real committed mutation** |
| `Client.updatePrinterToNullByPrinterId` | ✅ (`ClientRepository.java:141`) | **real committed mutation** |

**Correction to the prior lane's framing.** H1's headline instance — `customerorder.state` settable to an arbitrary value on an arbitrary id set over GET — is, on this reading, the **weakest** of the nine: it was almost certainly a 500. The three that genuinely committed are the three carrying explicit `@RestResource(path=…, rel=…)`, i.e. the deliberately-named ones. H1.5's caution was right to raise the question and slightly wrong about the mechanism: the failure is *no transaction at all* (`TransactionRequiredException`), not a read-only transaction hitting Postgres `25006`. `25006` is what the transaction map records for bulk JPQL inside a `readOnly = true` boundary; that boundary is not reached here, because the query method never acquires one.

**Severity, restated:** **High** for `Client.toggleEnableReceivingById` and `Client.updatePrinterToNullByPrinterId` and `Advice.updateAdviceToStateById` — a committed, unauthenticated-by-function, GET-reachable write against a shared config/state table. **Low** for the other six as an exposure (a 500 an attacker can trigger at will is a nuisance, not a data-integrity event) but **correct to fix anyway**: the annotation that makes them harmless is one line away from being added by a future maintainer who wants the internal caller to stop depending on an ambient transaction, at which point six silent High findings appear with no test to catch them. The invariant is the durable part of this commit, not the nine annotations.

---

## 3. Does the fix introduce new risk?

`exported = false` removes the HTTP route only; the Java method is untouched. I verified each internal caller and its transaction context:

| Method | Internal caller | Caller's transaction |
|---|---|---|
| `updateStateByIds` | `CustomerorderBatchService.finalizeClubLine:702` | `@Transactional(value = "tenantTransactionManager", rollbackFor = …)` ✅ |
| `markClientHasNoSection` | `ReleaseOrderJobService:802` ← `OrderReleaseJob:214` | `REQUIRES_NEW` ✅ |
| `releaseDueFutureTransferOrders` | `ReleaseOrderJobService:831` ← `OrderReleaseJob:130` | `REQUIRES_NEW` ✅ |
| `updatePriorityByIdIn` | `ReplenishOrderJobService.updateReplenishmentOrderPriorityBulk:254` | `REQUIRES_NEW` ✅ |
| `bulkUpdatePriorityForItems` | `ReplenishorderService:281` | `@Transactional("tenantTransactionManager")` ✅ |
| `bulkUpdatePriorityForItemsWithOldPriority` | `ReplenishorderService:297` | same ✅ |
| `updateAdviceToStateById` | `ReturnAdviceAutoReceiveService:688` | method carries its own `@Transactional` ✅ |
| `updatePrinterToNullByPrinterId` | `PrinterController.deletePrinter:168` | method carries its own `@Transactional` ✅ |
| `toggleEnableReceivingById` | 🔴 **NONE** | — |

**No scheduled job, event handler or internal Java caller depended on the HTTP route.** All eight surviving callers go through the repository proxy, so both the `@Transactional` and the `@CacheEvict` interceptors still apply — `@CacheEvict` on an interface method is honoured (the repo's own AC-28 records this), and nothing about `exported = false` changes the proxy chain. **`updatePrinterToNullByPrinterId`'s eviction still fires** on the `PrinterController.deletePrinter` path, which was the reason it was placed on the repository method in the first place. No regression there.

### 🔴 M-1 (Medium) — `Client.toggleEnableReceivingById` is now unreachable dead code, and its javadoc now asserts the opposite

`ClientRepository.java:44–77`. The SBDEV-3176 javadoc that justifies the `@CacheEvict` says, verbatim:

> *"This method is exported (the interface carries `@RepositoryRestResource` and the detection strategy is `ANNOTATED`), so it also answers at `GET /v3/client/search/...` — a mutating GET, exercised by `ClientControllerLegacyIntegrationTest`."*
>
> *"Annotating the callers instead would have closed one entry point and left the other: **this one has no in-process caller at all — the SDR route is its ONLY caller.**"*

`c4e18173` removes that only caller. Consequences, in order of importance:

1. **The method is now dead.** Zero HTTP callers, zero Java callers (verified by grep over all of `src/main`). It is the only one of the nine in that position.
2. **Its `@CacheEvict(value = "clients", allEntries = true)` is now a permanent no-op** — the very thing the javadoc's last paragraph warns about ("without that this annotation would be a silent permanent no-op"). No cache correctness is lost, because the surviving `enablereceiving` writers each carry their own evict (`ClientController.toggleReceiving:174` has `@CacheEvict`) or publish an SDR repository event that `SdrCacheEvictionEventHandler` sees. But the annotation is now misleading.
3. **The javadoc is actively false and self-contradictory as committed.** A reader arriving at SBDEV-3176's reasoning will conclude the SDR route exists. The `⚠ SBDEV-3183` comment sits *below* the javadoc and does not retract it — the same failure shape as [[retitling-a-section-leaves-the-rule-asserted-below-it]].
4. Its cited witness, `ClientControllerLegacyIntegrationTest.toggleEnableReceivingByIdTest:216`, does `get(urlBase + "/search/toggleEnableReceivingById")` and asserts `status().isOk()` — which would now be a 404. **No test actually breaks**, because the whole class is `@Disabled("Legacy test infrastructure incompatible with multi-tenant architecture…")` at `:42`. So the javadoc cites a disabled test as evidence that a now-deleted route is exercised. Nothing on disk contradicts it.

**Recommendation.** Either delete the method (preferred — dead code with a dead annotation), or amend the SBDEV-3176 javadoc in place so it does not assert an export that no longer exists, and drop the now-inert `@CacheEvict`. Do not leave it as-is: this is the exact "plausible-sounding reconciliation that stops the next reader from re-measuring" that the same commit's own `SdrWriteWithdrawalContextTest` javadoc apologises for elsewhere.

### L-1 (Low) — the invariant's correctness rests on an undocumented library detail

`SdrModifyingSearchNotExportedContextTest:105` iterates `SearchResourceMappings` directly. `SearchResourceMappings.iterator()` (spring-data-rest-core 4.5.7, `:159–160`) returns `mappings.values().iterator()` — **unfiltered** — while the sibling accessors on the same class (`:91`, `:106`, `:125`) all filter on `MethodResourceMapping::isExported`. The test is nonetheless correct today only because the list is pre-filtered at construction: `RepositoryResourceMappings.java:113`, `if (methodMapping.isExported()) { mappings.add(…) }`. A future Spring Data REST release that populates the map fully and relies on the accessors to filter would turn this test into a false RED flagging the very methods it protects. Fail-safe direction, so Low. One defensive line (`if (!search.isExported()) continue;`) would pin it to the contract the test actually means.

### L-2 (Low) — `POST /v3/client/create` is ungated and writes both fields

`ClientController.java:89` — `@PostMapping("/create")` with **no `@RequiresFunction`**, only the `@CacheEvict`. It sets `enablereceiving` (`:107–111`) and `printerreceivingId` (`:113–115`) from a caller-supplied `ClientUploadDto`. Its three siblings on the same controller (`setSection`, `setPrinter`, `toggleReceiving`) are all gated on `WEB_UI_VIEW_CLIENT`. This is out of scope for the nine and is *creation*, not modification, but it is an ungated `Client` write sitting next to three gated ones and is likely an SBDEV-3017 miss. Per the ticket policy this belongs on the **existing** SBDEV-3183 ticket only if its own tier is sub-T3; otherwise propose, do not file.

---

## 4. The three explicitly-exported ones — is an out-of-repo consumer plausible?

`Advice.updateAdviceToStateById`, `Client.toggleEnableReceivingById`, `Client.updatePrinterToNullByPrinterId` each carried `@RestResource(path=…, rel=…)`, i.e. somebody named them for export. The commit's own comment makes this argument and I agree with it; two additions.

**Evidence for "no consumer" (R5).** All nine names return **zero hits** across the three consumer repos at `origin/develop`, searched by bare name, case-sensitive and case-insensitive. The instrument was validated against known-present strings (`enablereceiving`, `customerorder`, `printerreceiving`) in the same repos and ref, so a zero here is a real absence, not a tooling gap. Notably `oms-laravel-api/app/Services/WmsApiService.php:3391` and two of its docs *mention* `/toggleReceiving` in prose as a warehouse-operator endpoint — but that is the **MVC** route (`POST /v3/client/toggleReceiving`), which is untouched by this commit, and there is no call site for the SDR search name.

**Failure mode if an unsearchable consumer exists: HTTP 404, not 405.** Derived from `RepositorySearchController.checkExecutability:298–308`:

```java
var searchMapping = verifySearchesExposed(resourceInformation);
var method = searchMapping.getMappedMethod(searchName);
if (method == null) {
    throw new ResourceNotFoundException();
}
```

`getMappedMethod` reads the map that `RepositoryResourceMappings:113` only ever populates with exported mappings, so an un-exported search name is simply absent → `ResourceNotFoundException` → **404**. This is the worse of the two failure modes for diagnosis: a 405 would tell an operator "wrong verb, the resource exists"; a 404 reads as "wrong URL / wrong environment / bad deploy" and will send someone hunting in the wrong place. `/v3/client/search` itself still returns 200 with a shortened link list, so the discrepancy is discoverable — but only if someone thinks to look.

**Residual risk: Low-to-Medium, and irreducible from inside this repo.** Ops scripts, Postman collections, cron wrappers and partner integrations are not in any of the three searched repos. `updatePrinterToNullByPrinterId` is the least likely to have one (it nulls a FK as a precondition for deleting a printer — an odd thing to call standalone); `toggleEnableReceivingById` is the most likely, because "turn receiving off for this client" is exactly the shape of an operational one-liner, it has a documented MVC twin that people know about, and it is the one method whose *only* caller was the HTTP route. **Recommendation:** mention the 404 and the surviving `POST /v3/client/toggleReceiving` equivalent in the PR description / release note, so that if a 404 does surface in dev or UAT the mapping to the replacement route is one search away.

---

## 5. What the invariant CANNOT see, expressed as remaining exposure

Measured (R3) over all **66** repository interfaces:

- **31** `@Modifying` methods total.
- **18** carry a method-level `exported = false` (9 pre-existing + the 9 this commit added).
- **7** sit on repositories whose class-level `@RepositoryRestResource(exported = false)` removes the whole resource: `Adviceposition.updateAdvicepositionToStateByAdviceId`, `BillofladingPosition.deleteBolPositionById` / `.deleteBolPositionsCarrierIds`, `Billoflading.deleteBolByBolNumber`, `CustomerorderPosition.updateStateByOrderIds` / `.releaseDueFutureTransferOrderPositions`, `PickingorderPosition.assignToteToAllPositions`.
- **6** sit on `OutboxMessageRepository` and `RestIdempotencyRepository`, which carry **no** `@(Repository)RestResource` at all. `RestConfiguration.java:482` sets `RepositoryDetectionStrategies.ANNOTATED`, so these are not exported.

18 + 7 + 6 = 31. **The `@Modifying` axis is completely covered — zero exported bulk mutations remain, and R1/R2 confirm the invariant both passes and is armed.**

### Genuinely outside the invariant

| Residual | Measured | Assessment |
|---|---|---|
| Native/JPQL `@Query` performing DML **without** `@Modifying` | **2 candidates, both false positives.** `StockunitRepository.getStockUnitsByItemDataId` and `…ForUpdate` matched only on `FOR UPDATE OF stockunit` (`:212`), which is a locking clause, not DML. No CTE-with-DML (`WITH x AS (UPDATE …) SELECT`) found. | **Zero real exposure on this axis today.** But nothing pins it: a native `INSERT`/`UPDATE` without `@Modifying` would be invisible to the new test *and* to `SdrLockingSearchNotExportedContextTest`. A companion assertion over `@Query` text would close it cheaply. Low. |
| Exported searches invoking a PL/pgSQL function | **5 searches → 3 distinct functions**: `ClientRepository.getTransactionSummary`/`getTransactionDetail`, `StockrecordRepository.transactionSummaryByClientNumberBetweenDates`/`transactionDetailByClientNumberAndSkuBetweenDates`, `StockViewRepository.stockHistoryAfterAsOfDate`. R4 on `dev_wh01_om1`: all three declared `VOLATILE`, **no DML in any body** by regex (`stock_history` 2 805 chars, `transaction_summary` 6 520, `transaction_detail` 16 012). | `VOLATILE` here is Postgres' *default* when unspecified, so it is not evidence of mutation. No body contains DML. **Caveat this measurement:** the regex inspects the top-level `prosrc` only — a function that calls another function which writes would not show. Verified on `dev_wh01_om1` only; prd/UAT bodies were not checked and could differ ([[wms2-utc-v1205-hardcoded-function-list]] shows these functions do drift between environments). |
| Mutation performed *downstream* of an exported read | Not measurable statically | The invariant's own javadoc names this. A `@Query` that reads, whose result a repository fragment or an `@PostLoad` listener then writes, is invisible. None found by inspection, but the search was not exhaustive. |
| `@Lock` availability lever | Covered by the sibling `SdrLockingSearchNotExportedContextTest`, not re-verified here | — |

### Claim-discipline note on the test's own numbers

The test asserts `exportedSearches > 100` with a comment recording "249 exported searches were measured on 2026-09-01". I attempted to verify that figure by raising the floor and re-running; the result is reported in §6 below. The floor-not-exact-count choice is right, and the vacuity guard is genuinely load-bearing — without it a traversal bug would make the offender assertion trivially green.

---

## 6. Measured search count — the comment's 249 is the PRE-fix number

**RAN (R6):** raised the sensitivity floor to `isGreaterThan(999999)` in the detached worktree and re-ran, to make the assertion print the live value:

```
[the traversal must actually reach the exported searches — …]
Expecting actual:
  240
to be greater than:
  999999
```

**240 exported searches at `c4e18173`, not 249.** The arithmetic is exact and self-explaining: `249 − 9 = 240`. The nine methods this commit un-exported are filtered out of the iteration at construction (`RepositoryResourceMappings:113`), so they no longer count. The figure in the comment was therefore measured on the **pre-fix** tree and now sits in the post-fix file describing a world that no longer exists.

Harmless to the assertion (the floor is 100 and 240 clears it comfortably), but it is a number a future reader will re-quote. Recorded as **L-5** below. It also independently corroborates §5's count: the commit un-exported exactly nine searches, no more and no fewer.

---

## 7. Findings summary

| ID | Severity | Finding |
|---|---|---|
| **H-1** | **High** | `advice.state` is **not** closed. `PATCH /v3/advice/{id}` sets it to any `String` for any authenticated `wms_user` holding zero functions — `Advice` ∉ `SDR_WRITE_WITHDRAWN`, ∉ `SdrFunctionRules`, guard OFF. Same capability as the withdrawn search, different verb. |
| **H-2** | **High** | `client.enablereceiving` and `client.printerreceivingId` are **not** closed. `PATCH /v3/client/{id}` reaches both, same privilege level. The gated MVC twins (`toggleReceiving`, `setPrinter`) and this un-export together fence two of three mechanisms; the SDR item PATCH is the one left open. This is the [[a-guard-fences-the-mechanism-you-aimed-at]] shape, and it is the same shape as SBDEV-3142's "19 gates, zero datasets". |
| **M-1** | **Medium** | `Client.toggleEnableReceivingById` is now unreachable dead code with an inert `@CacheEvict`, and the SBDEV-3176 javadoc directly above it still asserts that the SDR route exists and is exercised by a test that is `@Disabled`. Delete the method or amend the javadoc — see §3. |
| **M-2** | **Medium** | The commit's per-method comments state, on all nine, that these were "reachable as `GET /v3/<resource>/search/<name>` by any authenticated `wms_user`". For **six of the nine** that is very likely false — no transaction attribute resolves, so the request 500s (§2). The comments will be read as a record of six exposures that did not exist. Correct them, or the next reader inherits an inflated history. This changes prose, not the fix. |
| **L-1** | Low | The invariant relies on `RepositoryResourceMappings:113` pre-filtering, not on anything it asserts; `SearchResourceMappings.iterator()` is unfiltered. One defensive `search.isExported()` check makes it robust. §3. |
| **L-2** | Low | `POST /v3/client/create` (`ClientController:89`) is ungated and writes `enablereceiving` + `printerreceivingId`. Likely an SBDEV-3017 miss; adjacent, not caused by this commit. §3. |
| **L-3** | Low | No invariant covers DML in a `@Query` without `@Modifying`. Zero instances today (R3), so this is a pin, not a fix. §5. |
| **L-5** | Low | `SdrModifyingSearchNotExportedContextTest:120` records "249 exported searches were measured on 2026-09-01". Live value at `c4e18173` is **240** (R6) — the 249 is the pre-fix count, `249 − 9 = 240`. Assertion is unaffected; the recorded number is wrong for the tree it ships in. §6. |
| **L-4** | Low | If an out-of-repo consumer of the three deliberately-exported searches exists, it gets a **404**, which misdiagnoses as a bad URL rather than a withdrawn capability. Name the replacement route in the release note. §4. |

## 8. Verdict

**The commit is correct and should ship.** The invariant-over-instance choice is the right one and is the durable value here: it turned three reported instances into nine, R3 independently confirms the `@Modifying` axis is now completely covered, and R2 confirms the assertion is armed rather than vacuous.

**It must not be described as closing these mutations.** Three of the five underlying capabilities (`advice.state`, `client.enablereceiving`, `client.printerreceivingId`) remain reachable at the identical privilege level over `PATCH` on the same entity, because `Advice` and `Client` are on the must-stay-writable side of SBDEV-3157's split. H-1 and H-2 are the substantive findings; M-2 is a correction to how the fix should be described.

Neither H-1 nor H-2 is a regression introduced by this commit — both predate it. Under the ticket policy they are findings from an implementation visit and, being sub-T3 individually but arguably T3 as a set (authz, multi-entity), the safe call is to **propose** them rather than file, capped at one per fix visit, for Nam to confirm.
