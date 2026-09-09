# SBDEV-3183 Slice 2 — security review

**Commit** `aec71edb` "SBDEV-3183 Slice 2: withdraw 29 caller-less domain types from the SDR surface"
**Branch** `feature/SBDEV-3183-sdr-unexport-uncalled`, parent `origin/develop` @ `92ca2e38`
**Worktree** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3183` (read-only; nothing edited, stashed or checked out)
**Reviewer lane** security · **Date** 2026-09-01

---

## 0. Method — what was run vs what was read

**Run (commands, in the reviewed worktree or on extracted jars):**

- `git show aec71edb` (full diff), `git show --stat`.
- Extracted `spring-data-rest-webmvc-4.5.7-sources.jar` (125 files) and
  `spring-data-rest-core-4.5.7-sources.jar` (93 files) from `~/.m2` into scratch, and read the dispatch,
  mapping and serialization classes directly. **Every library claim below is from that source, not from
  memory or documentation.**
- A class-level export map over all 66 files in `src/main/java/net/aim_ai/wms/repo/jpa/` — parsing the
  first `@RepositoryRestResource(...)` annotation and its continuation lines, **not** a bare
  `grep 'exported = false'`, which matches method-level `@RestResource` and inverts the verdict on
  `User`, `UserGroup`, `UserRole` and `UserGroupUser`. Result: **29 withdrawn / 33 exported / 4 with no
  annotation** (the 4 are un-exported anyway under `ANNOTATED`, see §1.2).
- A duplicate-path scan over all 62 class-level `path=` values, exact and `tolower`.
- `grep -rn '@ManyToOne|@OneToMany|@OneToOne|@ManyToMany'` over all 74 classes in
  `net.aim_ai.wms.model` (4 hits, one a comment).
- A fifth independent caller sweep: `git grep` of the 29 exact URL path strings across
  `v2/wms2-web-ui`, `v2/wms2-mobile-ui`, `v2/omsv2-UI`, `v2/oms-laravel-api` at their checked-out
  `develop`, plus `sbdocs/9-System/scripts`.

**Read only (not executed):** the wms2-api test suite. **I did not build and did not run Maven** — other
lanes are active and concurrent Maven in one worktree produces false reds. Every statement about test
outcomes below is about what the test *asserts*, not about a green run.

**Not verifiable without a live environment, and stated as such wherever it appears:** actual HTTP status
codes, actual response bodies, and per-tenant `los_sysprop` values.

---

## 1. Does the mechanism actually close the surface? — **Yes, more completely than the commit claims**

### 1.1 Withdrawal happens at the HandlerMapping, above every controller

`RepositoryRestHandlerMapping.lookupHandlerMethod` (spring-data-rest-webmvc 4.5.7):

```java
String repositoryBasePath = getRepositoryBasePath(repositoryLookupPath);

if (!mappings.exportsTopLevelResourceFor(repositoryBasePath)) {
    return null;
}
```

and immediately below it:

```java
protected HandlerMethod handleNoMatch(Set<RequestMappingInfo> requestMappingInfos, String lookupPath,
        HttpServletRequest request) throws ServletException {
    return null;
}
```

`getRepositoryBasePath` takes the **first path segment** of the repository lookup path. So one check
governs **all seven** `{repository}`-carrying routes at once — `/{repository}`, `/{repository}/{id}`,
`/{repository}/search`, `/{repository}/search/{search}`, `/{repository}/{id}/{property}`,
`/{repository}/{id}/{property}/{propertyId}`. There is no per-controller opt-in to miss. Collection, item
**and** `/search/**` go together. **Confirmed.**

`exportsTopLevelResourceFor` resolves to the metadata flag
(`PersistentEntitiesResourceMappings`):

```java
for (ResourceMetadata metadata : this) {
    if (metadata.getPath().matches(path)) {
        return metadata.isExported();
    }
}
```

### 1.2 `exported = false` really does reach `isExported()` under this app's strategy

`RepositoryCollectionResourceMapping` sets `this.repositoryExported = strategy.isExported(metadata)`.
`RestConfiguration.java:436` selects the strategy:

```java
config.setRepositoryDetectionStrategy(RepositoryDetectionStrategy.RepositoryDetectionStrategies.ANNOTATED);
```

`ANNOTATED.isExported` is `isExplicitlyExported(metadata.getRepositoryInterface(), false)`, and

```java
RepositoryRestResource restResource = AnnotationUtils.findAnnotation(type, RepositoryRestResource.class);
if (restResource != null) {
    return restResource.exported();
}
```

So the annotation attribute is read directly. **Confirmed.** The `false` fallback also means the four
repositories carrying no `@RepositoryRestResource` at all (`OutboxMessageRepository`,
`RestIdempotencyRepository`, `PutawayConfigAuditRepository`, `CustomerorderCancellationLogRepository`)
were never exported — no gap hiding behind them.

### 1.3 `/search/**` is closed twice over

Independently of the handler mapping, `RepositoryResourceMappings.getSearchResourceMappings` refuses to
populate the search list at all:

```java
if (resourceMapping.isExported()) {
    for (Method queryMethod : repositoryInformation.getQueryMethods()) { ... }
}
```

A withdrawn type's `SearchResourceMappings` is therefore **empty**, not merely unroutable. That is a
useful second instrument: `SdrSurfaceInventoryContextTest`'s runtime TSV dump will show zero SEARCH rows
for all 29 the next time it runs.

### 1.4 The HAL root index, the profile index and ALPS all drop the 29

`RepositoryController.listRepositories`:

```java
for (Class<?> domainType : repositories) {
    var metadata = mappings.getMetadataFor(domainType);
    if (metadata.isExported()) {
        resource.add(entityLinks.linkToCollectionResource(domainType));
    }
}
```

`ProfileController.listAllFormsOfMetadata` has the identical `if (mapping.isExported())` filter, and
`/profile/{repository}` + the ALPS descriptor are guarded by
`ResourceMetadataHandlerMethodArgumentResolver.resolveArgument`:

```java
if (mapping.getPath().matches(repositoryKey) && mapping.isExported()) {
    return mapping;
}
...
throw new HttpClientErrorException(HttpStatus.NOT_FOUND);
```

Both `ProfileController` and `AlpsController` are `@BasePathAwareController`, i.e. served by
`BasePathAwareHandlerMapping`, which does **not** carry §1.1's `exportsTopLevelResourceFor` guard — so
this argument-resolver check is the *only* thing closing them, and it happens to be sufficient. Worth
recording, because it is the one place the mechanism does not come from §1.1.

**Note the positive side effect not claimed in the commit message.** `SecurityConfiguration.java:151`
lists `"/v3"` under `permitAll()`:

```java
.requestMatchers(
    "/", "/v3", "/v3/token", "/error", "/rest/**", "/api/**", ...
).permitAll()
```

`GET /v3` is the HAL root index — an **unauthenticated** enumeration of every exported collection URL.
This commit shrinks that public list from 62 entries to 33. That is a real reduction in unauthenticated
reconnaissance surface and belongs in the ticket's benefit column. (Read from code; not confirmed against
a live instance.)

### 1.5 The ExposureConfiguration rejection is correct — verified independently

Two facts, both from the 4.5.7 sources rather than from the commit message:

1. `ResourceType` declares exactly `COLLECTION, ITEM;` — nothing for search.
2. `grep -rn verifySupportedMethod` over the whole webmvc jar returns **three** sites:
   `RootResourceInformation` (the two overloads), `RepositoryEntityController` (COLLECTION/ITEM only) and
   `RepositoryPropertyReferenceController` (the `PersistentProperty` overload).
   `RepositorySearchController.java` contains **zero** matches for
   `Exposure|supportedHttpMethods|getSupportedHttpMethods`.

So an `ExposureConfiguration` filter cannot reach `/{repository}/search/**` at all. Had that route been
taken, every search on all 29 types would have stayed open while the change looked like a withdrawal.
**The commit's reasoning holds; I reached it independently.**

---

## 2. Resulting HTTP behaviour, and whether it leaks

Spring Security's `FilterChainProxy` runs before the `DispatcherServlet`, so authorization is decided
before the missing handler is ever discovered. Against
`SecurityConfiguration.java:178` — `.requestMatchers("/v3/**", "/putawayConfig/**").hasAnyAuthority(Authority.WMS_USER_ROLE)`:

| Caller | `GET /v3/billoflading` | `GET /v3/billoflading/search/findByX` | `GET /v3/itemdata` (still exported) |
|---|---|---|---|
| unauthenticated | **401** (bearer entry point) | **401** | **401** |
| authenticated, no `wms_user` | **403** | **403** | **403** |
| authenticated `wms_user` | **404** | **404** | 200 |

**No 404-vs-403 discrimination exists for the callers that matter.** An anonymous or unauthorised caller
gets the same 401/403 for a withdrawn path, an exported path and a path that never existed — the
authorization decision is made on the `/v3/**` pattern alone and never consults the SDR mappings.

The only differential is visible to an already-authorised `wms_user`: 404 (withdrawn) vs 200 (exported).
That discloses nothing incremental, because the exported set is already fully enumerable from `GET /v3`,
which is `permitAll()` (§1.4).

**Body shape.** `net.aim_ai.wms.exceptions` has three advices (`RestExceptionHandler`,
`RestEndpointExceptionHandler`, `MobileEndpointExceptionHandler`); none registers
`@ExceptionHandler(Exception.class)`, `NoHandlerFoundException` or `NoResourceFoundException`. So a
withdrawn path falls to Boot's default `/error` (itself `permitAll`) and renders the standard
`{"timestamp","status":404,"error":"Not Found","path":...}` with no stack trace under Boot 3 defaults.
**Derived from code; not confirmed against a running instance.**

---

## 3. Did deleting the three `SdrFunctionRules` entries open anything? — **No. Strictly more closed.**

### 3.1 Net effect

Before: `UserGroupUserRole` / `UserRoleUserFunction` / `UserUserRole` were exported, their **reads** open
to any `wms_user` (the rule bit only at `ENFORCE_RULED`, and every tenant is at `OFF`), their **writes**
already disabled — the first two by `RestConfiguration`'s exposure blocks, `UserUserRole` by SBDEV-3157's
`SDR_WRITE_WITHDRAWN` loop.

After: unrouted at every mode, no rule needed. The rule that was deleted was closing nothing today.
**Strictly more closed, in every mode, with no mode dependency.**

### 3.2 The deletion was mandatory, not cosmetic — confirmed

`SdrRuleStartupAssertion.findStaleRules`:

```java
} else if (!metadata.isExported()) {
    stale.add(domainType.getSimpleName() + " (mapping exists but exported=false)");
}
```

`SdrRuleStartupCheck.afterSingletonsInstantiated` turns any non-empty `problems` list into an
`IllegalStateException`. Leaving the three rules in place would have failed the boot on every tenant.
The commit's claim is accurate.

### 3.3 The re-export scenario — mostly guarded, with one asymmetry worth naming

If someone later re-exports one of the three (a one-annotation change) and forgets the rule:

- **The exposure blocks in `RestConfiguration` come back to life.** `ExposureConfiguration` filters are
  registered per domain type and consulted at metadata construction; re-export restores the route *and*
  the filter, so the write verbs stay disabled. The "belt-and-braces" label on those blocks is accurate,
  not decoration. Both blocks now carry a `⚠ … this block is a no-op today` comment plus an explicit
  *"Hop 1 (UserGroupUser, immediately above) is NOT un-exported … Do not delete the two together"* — good.
- **The boot check will not catch the missing rule.** This is deliberate and documented in
  `SdrRuleStartupAssertion`'s javadoc (*"the symmetric check … cannot be implemented here and should not
  be faked"*) — there is no tenant context at `afterSingletonsInstantiated`. So a re-export with no rule
  reopens the read at `OFF`, `SHADOW` and `ENFORCE_RULED`; only `FAIL_CLOSED` denies.
- **CI does catch it**, for all 29. `SdrRuleInventoryContextTest.theAuthorizationGraphIsExported` gained
  `.doesNotContain("UserGroupUserRole", "UserRoleUserFunction", "UserUserRole")`, and
  `SdrUncalledSurfaceNotExportedContextTest.withdrawnDomainTypesAreNotExported` covers the full 29.

I checked that those pins actually execute, given this repo's history of `*IT` classes that run in
neither lane: both class names end in `Test`, matching surefire's default
`**/*Test.java` include, and `pom.xml:518-521` excludes only `**/*IntegrationTest.java` and
`**/*E2ETest.java`. So they run under `mvn test`. (Read from `pom.xml`; not confirmed by a run.)

---

## 4. The access-decision chain — **untouched, in both directions**

**Hop 1 is intact.** `UserGroupUserRepository` carries a class-level annotation with no `exported`
attribute (verified by the parsing pass in §0, not by a bare grep), keeps its `USER_ADMIN_VIEW` rule at
`SdrFunctionRules.java:193`, and its `RestConfiguration` hop-1 exposure block is byte-identical in the
diff. The five remaining ruled types are `User`, `UserFunction`, `UserGroup`, `UserGroupUser`,
`UserRole` — all five verified still exported.

**No repository bean was removed.** `exported = false` affects only
`RepositoryDetectionStrategy`; the beans come from `@EnableJpaRepositories(basePackages = …)` in
`landlord/config/TenantDatabaseConfig.java`. `AccessService`, `UserRoleService`, `UserGroupService` and
`UserFunctionService` still inject all three withdrawn join repositories and are unaffected. The
`user → group → role → function` walk in `UserRepository.getAllRoles` is a native query and never went
near SDR.

**The URI-binding escalation route is unchanged.** The `PATCH /v3/user/{id}` with
`{"groups":["/v3/userGroup/51856"]}` mechanism documented in `RestConfiguration` depends on
`Associations.isLinkableAssociation`, which depends on the association **target** type being exported.
The entire model has exactly three JPA associations:

- `User.groups → UserGroup` (`User.java:63`)
- `UserGroup.roles → UserRole` (`UserGroup.java:22`)
- `UserRole.functions → UserFunction` (`UserRole.java:27`)

All three targets remain exported, so nothing about that mechanism moved in either direction. The join
entities (`UserGroupUserRole` etc.) are separate mappings of the same physical tables and are not
referenced by any `@JoinTable`, so withdrawing them cannot perturb the association metadata.

### 4.1 The mirror risk — checked and clear here, but it is the trap for Slice 3

`PersistentPropertyResourceMapping.isExported()`:

```java
ResourceMapping typeMapping = mappings.getMetadataFor(property.getAssociationTargetType());

return typeMapping != null && typeMapping.isExported()
        ? annotation.map(it -> it.exported()).orElse(true)
        : false;
```

When the association **target** is un-exported, the property stops being a linkable association. In
`PersistentEntityJackson2Module.AssociationOmittingSerializerModifier`, only `isLinkableAssociation`
properties are replaced by a `_links` entry — everything else is serialized **inline** through
`NestedEntitySerializer`. So un-exporting a type that some *still-exported* type points at converts a
link into an inlined nested object and **increases** disclosure on the parent's payload.

Zero occurrences in this commit, because none of the three JPA associations targets any of the 29. But
this is not a property a reader would guess, and Slice 3 will be picking from a set where it can bite.
**Recommend recording it in the plan's mechanism section.**

---

## 5. Over-withdrawal

**The eleven kept-writable resources are all verified still exported** by the class-level parse:
`Section`, `Advice`, `Boxtype`, `Client`, `Customerorder`, `Cyclecount`, `Location`, `LocationType`,
`Sysprop`, `UserGroup`, `UserRole`. The `Cyclecount`, `CustomerorderBatch` and `Pickingorder` exclusions
are real — all three appear in my EXPORTED column.

The `MUST_REMAIN_EXPORTED` rail in `SdrUncalledSurfaceNotExportedContextTest` pins exactly those eleven,
and the split of `SdrWriteWithdrawalContextTest`'s loop into `stillExported` / `withdrawnEntirely` is
correct: 27 of that test's 47 are now un-exported (`UserGroupUserRole` and `UserRoleUserFunction` were
never in the 47 — they came from `RestConfiguration`'s access-chain blocks, not SBDEV-3157's sweep), and
collapsing the two causes would indeed have destroyed the anti-rename property. **The arithmetic
reconciles.**

### 5.1 A fifth caller-detection method, run here

`SdrUncalledSurfaceNotExportedContextTest`'s own javadoc lists `omsv2-UI` among the repositories **not**
searched. I searched it: it contains **no `/v3/` reference and no WMS API base URL** anywhere in `src/`,
`.env*` or `vite.config*` (`grep -rIn -E "v3/|wms.*baseURL|VITE_WMS|WMS_API"` → zero hits). It talks to
`oms-laravel-api`, not to wms2-api. **That repository is cleared.**

`git grep` of all 29 exact `path=` strings across the four client repos returned only:

- `/report/parcelMonitorView` (many Cypress hits) → `ReportController`, a plain MVC route, not the SDR
  path. Consistent with the commit's classification of `ParcelMonitorView`.
- Two markdown hits in `oms-laravel-api`, one of which is finding **L6** below.

`sbdocs/9-System/scripts` is clean.

### 5.2 The HAL `_links` caveat is narrower than the test states

The test javadoc warns that `oms-laravel-api`'s `WmsApiService` falls back to a `_links.self` href, so a
caller can reach a path present in no source literal. That fallback exists in exactly one place —
`app/Services/WmsApiService.php:3365`, inside `resolveWmsClientId`, scoped to `Client`, which stays
exported. Combined with §4 (only three associations in the whole model, none targeting a withdrawn
type), **no exported resource's HAL payload contains a link to any of the 29**. The residual
HAL-discovery risk is confined to hrefs OMS may have persisted from a past `GET /v3` root index. That is
a materially smaller residual than the javadoc implies and the plan can say so.

---

## Findings

No High or Medium findings. The mechanism does what the commit says it does, and every direction I could
find in which a withdrawal can *open* something was checked and is clear.

### L1 — Stale surface-count literals in security-critical comments, in more files than the commit swept

The commit says *"Corrected rule-count literals in 6 files (8 -> 5)"*. It corrected the **rule** counts;
the **surface** counts were not swept, and one file was corrected inconsistently.

- `src/main/java/net/aim_ai/wms/security/SdrFunctionGuard.java:266-267` — untouched by this commit, still
  reads: *"with 8 rules present and fail-closed semantics, enforcing here would 403 the other 54 exported
  domain types"*. Now 5 rules, 33 exported, 28 unruled.
- `src/main/java/net/aim_ai/wms/security/SdrGuardMode.java:9` — **half-edited**: the diff changed
  `8 rules` → `5 rules` but left `54`, producing an internally inconsistent sentence
  (*"5 rules present, flipping a single boolean would 403 the other 54 domain types"*; 33 − 5 = 28). Its
  sibling `RequiresFunction.java:55` got the same edit right — *"five … leaving 28 exported types
  untouched"* — so the two now disagree.
- Also stale on `62`: `SdrRuleStartupAssertion.java:34` (*"all 62 types"*), `SdrFunctionGuard.java:387`
  (*"the 62 paths today"*), `SdrFunctionRules.java:28` (*"14 of the 62 exported types"*), and in tests
  `SdrRuleStartupCheckUnitTest.java:157`, `SdrGuardModeProviderUnitTest.java:62`,
  `SdrFunctionGuardUnitTest.java:358`, `SdrRuleInventoryContextTest.java:150`,
  `SdrWriteWithdrawalContextTest.java:48` (*"347 exported searches plus 62 collection reads"* — the search
  figure is now materially smaller too, per §1.3).

Comment-only, no behavioural effect. Raised because this codebase's own convention treats a stale literal
in a security comment as a defect — `SdrWriteWithdrawalContextTest` moved a count out of `@DisplayName`
into an assertion for exactly this reason, and `SdrFunctionGuard` carries two `⚠ CORRECTED` paragraphs
about the same failure mode. **The `SdrGuardMode.java:9` half-edit is the one to fix first**: a sentence
that is internally inconsistent reads as a typo and invites the next reader to "fix" the wrong half.

### L2 — `SdrFunctionGuard.buildIndex` indexes un-exported metadata, and its stated safety justification no longer covers the population it now has

`buildIndex` iterates the full mappings and indexes every entry:

```java
for (ResourceMetadata metadata : resourceMappings) {
    String path = metadata.getPath().toString();
    ...
    ResourceMetadata previous = index.putIfAbsent(path, metadata);
```

`PersistentEntitiesResourceMappings.iterator()` returns `cache.values()` with **no `isExported` filter**,
so all 29 withdrawn entries are in that index. The javadoc justifies the collision branch with *"Cannot
happen through Spring Data REST, which rejects duplicate exported paths at startup"* — a guarantee that
covers **exported-vs-exported only**. Nothing stops a future repository from taking a path equal to a
withdrawn one, and `cache.values()` is backed by a `HashSet`, so which entry wins `putIfAbsent` is
nondeterministic across JVM runs. The consequence is the one the collision counter was written to catch:
one resource gated on another's rule.

This commit raised the un-exported population from 4 to 33, i.e. it multiplied a latent condition by
roughly eight.

**Verified clear today:** all 62 class-level `path=` values are distinct, and remain distinct under
`toLowerCase`. So this is latent, not live.

**Fix is one line and is strictly correct** — only an exported path can ever be dispatched to the guard:

```java
if (!metadata.isExported()) continue;
```

placed at the top of the `buildIndex` loop. Row 6 (`metadata == null` → deny when enforcing) already
handles anything that would then fail to resolve.

### L3 — The property that decided the mechanism is not pinned by any test

The commit's entire case for `exported = false` over `ExposureConfiguration` is `/search/**`. No test in
the commit touches a search mapping: `SdrUncalledSurfaceNotExportedContextTest` asserts only
`metadata.isExported()`.

That is *adequate today* — §1.1 and §1.3 show `isExported() == false` transitively implies both the
missing route and the empty `SearchResourceMappings` on 4.5.7. But the deciding property survives only as
long as that library behaviour does, and a reader cannot see it from the test.

One line in `withdrawnDomainTypesAreNotExported` would pin it:

```java
assertThat(mappings.getSearchResourceMappings(domainType)).isEmpty();
```

Cheap, and it makes the test assert the thing the commit message argues.

### L4 — Re-export is guarded only by two named lists, and the boot check is deliberately blind to it

Detail in §3.3. The asymmetry is real and documented: a **rule on an un-exported type** refuses the boot;
an **exported type with no rule** is silently allowed at every mode below `FAIL_CLOSED`. So re-export
without restoring a rule is caught by CI (both pins exist and both run) but not by the runtime.

No change requested — the design reason in `SdrRuleStartupAssertion`'s javadoc is sound and the CI pins
are adequate. Recorded so the next reviewer does not assume the boot check is symmetric, which its
neighbouring `⚠` comment in `SdrFunctionRules` could be read to imply.

### L5 — `/v3/profile/<withdrawn>` answers 500, not 404

`ResourceMetadataHandlerMethodArgumentResolver` throws
`new HttpClientErrorException(HttpStatus.NOT_FOUND)` from an argument resolver.
`grep -rn HttpClientErrorException` over the whole webmvc jar shows **SDR itself registers no handler for
it**, and this app has no catch-all `@ExceptionHandler(Exception.class)`, so it surfaces as a container
500 rather than a 404.

Not an oracle — a name that never existed takes the identical code path and produces the identical 500 —
and it is SDR's pre-existing behaviour for any un-exported repository, so this commit changes the extent
(29 new paths) and not the kind. Raised only so that no plan or ticket text claims *"withdrawn paths
return 404 everywhere"*: 404 for `/v3/<withdrawn>`, 500 for `/v3/profile/<withdrawn>`. Both are behind
`wms_user`. **Derived from code; not confirmed against a running instance.**

### L6 — `/v3/inventoryRecord` is named as a target endpoint in OMS's own integration spec

`v2/oms-laravel-api/docs/functional-specs/22-wms-integration.md:140`, in the section prescribing how to
repair OMS's known-broken `inventory_adjust` call:

> The real endpoints are on `StockUnitController` (`/v3/stockUnit`): … plus Spring Data REST reads at
> `/v3/stockunit`, `/v3/stockrecord`, `/v3/stockView`, `/v3/inventoryRecord`.

`InventoryRecord` is one of the 29 withdrawn. The other three named there (`stockunit`, `stockrecord`,
`stockView`) all remain exported.

**There is no live caller** — `git grep -nIE 'inventoryRecord' -- app config routes database` in
`oms-laravel-api` returns only local PHP variables over OMS's own `product_inventory` tables, never an
HTTP call. So the four caller-detection methods were not wrong; this is *documented forward intent*,
which is a category no caller sweep can see.

This is the single strongest over-withdrawal signal I found. The failure mode is mild — the same document
already says *"do not wire a caller to them without first confirming the endpoint exists in wms2-api"*, so
an OMS engineer would hit a 404 during development, not in production, and the revert is one annotation.

**Recommendation:** keep the withdrawal, and either (a) add a line to that OMS doc noting
`/v3/inventoryRecord` was withdrawn by SBDEV-3183 and must be re-exported if the repointing work
proceeds, or (b) note it on the ticket so the OMS side is told. Do not silently leave a spec pointing at
a path that now 404s.

---

## Verdict

**The mechanism is sound and I found no way in which this commit opens anything.** Class-level
`@RepositoryRestResource(exported = false)` removes collection, item, `/search/**`, association and
profile/ALPS routes together, at the handler-mapping layer, and drops the type from both the HAL root
index and the profile index — verified against the 4.5.7 sources rather than assumed. The
`ExposureConfiguration` rejection reasoning is correct and I reproduced it independently. The three rule
deletions were mandatory, and their net effect is strictly more closed. The access chain is intact: hop 1
untouched, all three JPA association targets still exported, every repository bean still injected.

Six Low findings. **L2** (one-line `buildIndex` filter) and the `SdrGuardMode.java:9` half of **L1** are
the two I would fix before merge; **L6** needs a message to the OMS side rather than a code change.
