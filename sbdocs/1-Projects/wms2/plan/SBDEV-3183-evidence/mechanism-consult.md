# SBDEV-3183 Slice 2 — SDR un-export mechanism consult

**Question asked:** withdraw 29 domain types from the `/v3` SDR surface entirely (collection + item +
all searches). Choose between (A) class-level `@RepositoryRestResource(exported = false)`,
(B) programmatic READ-verb withdrawal in `RestConfiguration`, or (C) something else.

**Verdict: (A), class-level `exported = false`, coupled with (i) — delete the three
`SdrFunctionRules` entries in the same commit.**

**(B) is not a viable alternative. It cannot deliver the stated scope at all** — it leaves every
`/search/**` endpoint on all 29 types fully live. That is not a preference between two workable
mechanisms; it is a correctness disqualification. Details in §1.

Everything below is read from the **spring-data-rest 4.5.7 sources** actually on this build's
classpath (`~/.m2/repository/org/springframework/data/spring-data-rest-{core,webmvc}/4.5.7/
*-sources.jar`), not from reference docs. Worktree at `origin/develop` `92ca2e38`.
Line numbers are from those extracted sources. What I could not verify is listed in §8.

---

## 1. The decisive finding: `ExposureConfiguration` does not reach `/search/**`

`ResourceType` has exactly two constants:

```java
// core/.../mapping/ResourceType.java:23-25
public enum ResourceType {
    COLLECTION, ITEM;
}
```

`ExposureConfiguration.filter(...)` dispatches on that enum and on
`PropertyAwareResourceMapping` (associations) only:

```java
// core/.../mapping/ExposureConfiguration.java:136-149
HttpMethods filter(ConfigurableHttpMethods methods, ResourceType type, ResourceMetadata metadata) { ... }
HttpMethods filter(ConfigurableHttpMethods methods, PropertyAwareResourceMapping mapping) { ... }
```

There is **no search resource type**, so no filter a `withCollectionExposure` /
`withItemExposure` / `withAssociationExposure` call can install is ever consulted for a search URL.

Confirmed at the enforcement side. `verifySupportedMethod` — the single place the filtered
`SupportedHttpMethods` is actually checked — has exactly **nine** call sites in the whole of
spring-data-rest-webmvc, and every one is in `RepositoryEntityController` or
`RepositoryPropertyReferenceController`:

```
RepositoryEntityController.java:149  HEAD   COLLECTION
RepositoryEntityController.java:183  GET    COLLECTION
RepositoryEntityController.java:252  POST   COLLECTION
RepositoryEntityController.java:345  PUT    ITEM
RepositoryEntityController.java:380  PATCH  ITEM
RepositoryEntityController.java:407  DELETE ITEM
RepositoryEntityController.java:507  GET    ITEM
RepositoryPropertyReferenceController.java:381  (association)
```

`RepositorySearchController` calls it **zero times** (`grep -n "verifySupportedMethod\|ResourceType\."
RepositorySearchController.java` → no output). Its only gates are
`checkExecutability` (:298) and `verifySearchesExposed` (:346-355), both of which test
`SearchResourceMappings.isExported()` / per-method mapping — i.e. the **annotation** axis, never
the exposure-configuration axis.

### How much surface B would leave open

`RestConfiguration` does not override `exposeRepositoryMethodsByDefault`, so SDR's default applies:

```java
// core/.../config/RepositoryRestConfiguration.java:69
private boolean exposeRepositoryMethodsByDefault = true;
```

which means *every* declared query method on those repositories is an exported search unless
individually annotated `exported = false`. Counting only the **explicitly annotated** method-level
`@RestResource(...)` paths on the 29 types' repositories gives **86 live search endpoints across 21
of the 29 types** (measured; pattern excludes the class-level `@RepositoryRestResource` and
subtracts existing `exported = false` methods). 86 is a **floor**, not the total, because
unannotated query methods are exported too.

Under option B all 86+ stay reachable and ungated. Under option A all of them disappear.

**Secondary defect in B, independent of the search gap:** B does not remove the type from the HAL
root index. `GET /v3` filters purely on `isExported()`:

```java
// webmvc/.../RepositoryController.java:100-108
for (Class<?> domainType : repositories) {
    var metadata = mappings.getMetadataFor(domainType);
    if (metadata.isExported()) {
        resource.add(entityLinks.linkToCollectionResource(domainType));
    }
}
```

and B leaves `isExported()` true (§2). So the root index would keep advertising all 29 collections,
each of which then answers `405 Method Not Allowed` with an `Allow` header. That is an
advertised-but-broken surface — strictly worse for a reviewer and for an auditor than either
leaving it alone or removing it. It also matches the failure shape recorded in
`advertised-capability-is-not-exploitable-capability`, in reverse.

---

## 2. Q1 — Does `ExposureConfiguration` disabling GET leave `isExported() == true`? **Yes.**

The two concerns are separated in the constructor of the metadata object. `isExported()` reads the
**mapping**; the exposure config only wraps `getSupportedHttpMethods()`:

```java
// core/.../mapping/RepositoryAwareResourceMetadata.java:64-67
CrudMethodsSupportedHttpMethods httpMethods = new CrudMethodsSupportedHttpMethods(
        repositoryMetadata.getCrudMethods(), provider.exposeMethodsByDefault());
this.crudMethodsSupportedHttpMethods = new ConfigurationApplyingSupportedHttpMethodsAdapter(
        provider.getExposureConfiguration(), this, httpMethods);

// :106-108
@Override
public boolean isExported() {
    return mapping.isExported();          // <- CollectionResourceMapping, i.e. the ANNOTATION axis
}

// :151-153
@Override
public SupportedHttpMethods getSupportedHttpMethods() {
    return crudMethodsSupportedHttpMethods;   // <- the ONLY thing ExposureConfiguration touches
}
```

`ConfigurationApplyingSupportedHttpMethodsAdapter` implements only `getMethodsFor(ResourceType)`,
`getMethodsFor(PersistentProperty)` and `allowsPutForCreation()`. It cannot influence
`isExported()`.

**Both consequences the lead asked me to confirm are confirmed:**

1. **B does NOT trip the stale-rule boot failure.** `SdrRuleStartupAssertion.findStaleRules`
   (`security/SdrRuleStartupAssertion.java:54-65`) flags on `metadata == null ||
   !metadata.isExported()`. B changes neither. The three ruled types stay non-stale.
2. **B does NOT remove the resource from the HAL root index** — shown in §1 above.

Note that consequence 1 is **not** an advantage for B. It is the mechanism telling the truth: B
does not actually withdraw the resource, so the rule that guards it is correctly still required.

---

## 3. Q2 — Does class-level `exported = false` remove it from the root index and make `isExported()` false? **Yes to both, and it goes further than the question assumes.**

`RestConfiguration` sets `RepositoryDetectionStrategies.ANNOTATED`, which resolves as:

```java
// core/.../mapping/RepositoryDetectionStrategy.java:94-125
ANNOTATED {
    public boolean isExported(RepositoryMetadata metadata) {
        return isExplicitlyExported(metadata.getRepositoryInterface(), false);
    }
};
private static boolean isExplicitlyExported(Class<?> type, boolean fallback) {
    RepositoryRestResource restResource = AnnotationUtils.findAnnotation(type, RepositoryRestResource.class);
    if (restResource != null) { return restResource.exported(); }   // <- reads exported() directly
    ...
}
```

That result is stored as `repositoryExported` in `RepositoryCollectionResourceMapping`
(`:83  this.repositoryExported = strategy.isExported(metadata);`) and surfaces as
`RepositoryAwareResourceMetadata.isExported()`. So `isExported()` → **false**.

Three consequences, all verified from source:

**(a) The URL stops mapping entirely — this is stronger than a 405.**

```java
// webmvc/.../RepositoryRestHandlerMapping.java:153-157
String repositoryBasePath = getRepositoryBasePath(repositoryLookupPath);
if (!mappings.exportsTopLevelResourceFor(repositoryBasePath)) {
    return null;                      // no handler at all
}
```
```java
// core/.../mapping/PersistentEntitiesResourceMappings.java:101-113
public boolean exportsTopLevelResourceFor(String path) {
    for (ResourceMetadata metadata : this) {
        if (metadata.getPath().matches(path)) { return metadata.isExported(); }
    }
    return false;
}
```

`lookupHandlerMethod` returning `null` withdraws **every** URL under `/v3/<path>/**` in one move —
collection, item, all searches, `OPTIONS`, `HEAD`, and any association resource. This is why A is
whole-type withdrawal and B is not.

**(b) Searches are additionally cut off upstream**, belt-and-braces:

```java
// core/.../mapping/RepositoryResourceMappings.java:109-117
if (resourceMapping.isExported()) {
    for (Method queryMethod : repositoryInformation.getQueryMethods()) { ... }
}
```
An unexported type produces an **empty** `SearchResourceMappings`.

**(c) It DOES trip the boot failure — confirmed precisely, including the `hasMappingFor` subtlety.**

This is worth spelling out because the obvious reading is wrong. `findStaleRules` guards with
`hasMappingFor` first (`SdrRuleStartupAssertion.java:116-119`), and one might expect an unexported
repository to have no mapping. It has one:

```java
// core/.../mapping/RepositoryResourceMappings.java:124-136
public boolean hasMappingFor(Class<?> type) {
    if (super.hasMappingFor(type)) { return true; }
    if (repositories.hasRepositoryFor(type)) { return true; }   // <- TRUE regardless of export
    return false;
}
```

and `populateCache` (`:67-93`) creates and caches a `RepositoryAwareResourceMetadata` for **every**
entity that has a repository — the detection strategy is passed *into* the mapping, it does not
filter the loop. `getMetadataFor` does not filter either
(`PersistentEntitiesResourceMappings.java:57-62` — a plain `cache.computeIfAbsent`).

So for an un-exported type: `hasMappingFor` → **true**, `getMetadataFor` → **non-null**,
`isExported()` → **false** ⇒ `findStaleRules` takes the second branch and emits
`"<Type> (mapping exists but exported=false)"` ⇒ `SdrRuleStartupCheck.afterSingletonsInstantiated`
throws `IllegalStateException` ⇒ **refusal to boot, on every tenant, fleet-wide.**

The three rules at `SdrFunctionRules.java:220-222` (`UserGroupUserRole`, `UserRoleUserFunction`,
`UserUserRole` → `USER_ADMIN_VIEW`) **must be deleted in the same commit.** The existing error
message already instructs exactly this: *"Delete the rule deliberately in the same commit that
un-exports the resource."* This is designed behaviour, not an obstacle to route around.

---

## 4. Q3 — Does either mechanism affect internal Java calls through the repository bean? **Neither does. Confirmed, and there is an in-repo empirical precedent.**

Repository bean creation is spring-data-jpa/commons; `@RepositoryRestResource` and `@RestResource`
are read **only** by spring-data-rest's mapping layer — `RepositoryDetectionStrategy:112-122` and
`RepositoryCollectionResourceMapping:77-80`, both via `AnnotationUtils.findAnnotation`, both purely
to build HTTP metadata. Nothing in the proxy/factory path consults them.

The repo already proves this empirically for the method-level form: `deleteByRoleId` carries
`@RestResource(exported = false)` (`UserRoleUserFunctionRepository.java:70`) and is called from
`UserRoleService.deleteRole`; `deleteByGroupId` likewise
(`UserGroupUserRoleRepository.java:52`, called from `UserGroupService`). Both work today.

**Correction to a premise in the brief.** The task states *"the only internal caller we found is
`AccessService:204` `findByRolelistIdAndFunctionlistId`"*. That undercounts substantially. A
`grep` over `src/main` for the reverse lookups on the three ruled types returns **15 call sites**:

```
UserRoleService.java:169,178   findByRolelistIdAndGrouplistId
UserRoleService.java:209,283   findByRolelistId
UserRoleService.java:284       findByRolesId
UserGroupService.java:184      findByGrouplistId
AccessService.java:204         findByRolelistIdAndFunctionlistId
AccessService.java:274         findByRolelistIdAndGrouplistId
AccessService.java:297,322,350 findByGrouplistId
AccessService.java:328,356     findByRolelistId
UserFunctionService.java:49,58 findByRolelistIdAndFunctionlistId
```

This **does not change the verdict** — all fifteen are direct bean calls and every one is
unaffected by un-exporting. But the count should be corrected in the plan, because "one caller"
invites the reader to think the methods are near-dead and could simply be deleted. They are load-
bearing: `UserRoleService:283-284` is the SBDEV-3011 role-delete refusal check, and
`AccessService:297-356` is on the access-decision path.

---

## 5. Q4 — The three association resources. **No difference, and the reason is stronger than "none of the 29 owns one."**

Association exposure keys off the **target** type's export flag:

```java
// webmvc/.../mapping/Associations.java:142-157
public boolean isLinkableAssociation(PersistentProperty<?> property) {
    ...
    ResourceMetadata metadata = mappings.getMetadataFor(property.getOwner().getType());
    if (metadata != null && !metadata.isExported(property)) { return false; }
    metadata = mappings.getMetadataFor(property.getActualType());
    return metadata == null ? false : metadata.isExported();     // <- TARGET type
}
```

So the risk to check is not "does one of the 29 own an association" but **"is one of the 29 the
target of an association from a still-exported type"** — that would silently drop `_links` entries
and change serialization on resources we are not touching (`DefaultLinkCollector:167,209`;
`PersistentEntityJackson2Module:276,465`).

Measured: the entire `model/` package contains **exactly three** JPA association annotations,
consistent with the documented v2 convention of manual FK relationships only.

| owner | field | join table | **target** | target in the 29? |
|---|---|---|---|---|
| `User.java:63` | `groups` | `mywms_group_mywms_user` | `UserGroup` | no |
| `UserGroup.java:22` | `roles` | `mywms_group_mywms_role` | `UserRole` | no |
| `UserRole.java:27` | `functions` | `mywms_role_mywms_function` | `UserFunction` | no |

(The fourth grep hit, `OutboxMessage.java:25`, is a javadoc line reading *"No `@ManyToOne` — manual
FK per v2 conventions."*, not an annotation.)

All three targets are in the evidence file's B.4 "already ruled" bucket. **No association resource
changes under either option.** And because there are no other associations anywhere in the model,
the association-inlining side effect cannot occur for any of the 29 — a risk that would have been
real in a conventionally-mapped codebase.

Also checked and clear: no `RepositoryEntityLinks` / `EntityLinks` / `linkToCollectionResource`
usage anywhere in `src/main`, and no `@Projection` / `excerptProjection` referencing any of the 29.
Nothing in application code depends on these types having a HAL representation.

---

## 6. Q5 — Accidental re-export, and reviewer visibility

| | (A) class-level annotation | (B) programmatic |
|---|---|---|
| Where the decision lives | on the repository interface, the file you already have open | 400+ lines away in `RestConfiguration` |
| A new dev adds a query method | inert — the type is unmapped | **silently exported and ungated** |
| Someone copies a sibling repository as a template | copies `exported = false` with it | copies nothing |
| Re-export by accident | needs a deliberate edit to that annotation | any refactor of the exposure lambdas |
| Re-export caught at boot? | **yes** — an un-ruled type is logged; a re-export that re-strands a rule throws | no |
| Reviewer reading the repository interface | sees it | sees nothing |

A is better on every axis. The asymmetry that matters most is row 2: under B, the type stays
exported, so **every future query method added to any of those 29 repositories becomes a live,
ungated `/v3/<path>/search/...` endpoint the moment it is written** — because
`exposeRepositoryMethodsByDefault` is `true`. Under A it is inert. Given that 21 of the 29 are
report/monitor/position types that plausibly grow query methods, this is a live drift risk, and it
is precisely the class of drift `wms2-function-gate-anti-drift-only-covers-guarded-classes`
records this codebase repeatedly failing to catch.

The one genuine cost of A: the decision is spread across 29 files instead of centralised in one.
Mitigate with a single shared comment string citing SBDEV-3183 §B.5 on each annotation, and pin the
set in a context test (see §7) so the *inventory* stays centralised even though the *mechanism* is
distributed. That preserves B's only real advantage without adopting B.

---

## 7. Recommendation on the coupled decision, and on `RestConfiguration:67`

**Take (i): un-export and delete the three `SdrFunctionRules` entries in the same commit.**

- It is not optional. Per §3(c), leaving them is a boot failure, not a style choice.
- It is strictly safer than gating. An un-exported path cannot be over-gated, mis-ruled, or
  re-opened by a rule-table edit. `SdrFunctionRules`' own javadoc at `:214-219` already says the
  `UserUserRole` rule "gates a table with no rows" and confers nothing.
- `USER_ADMIN_VIEW` on these three is a ceiling, not a fit — the same shape the rules file's own
  comment warns about. Removing the surface removes the question.

### Is `RestConfiguration:67` a real requirement or a stale one? **Stale, on its own terms.**

The comment reads:

> `// GET is kept: findByRolelistId / findByFunctionlistId are legitimate reverse lookups.`

It is stale for two independent reasons:

1. **It never claimed an HTTP client.** Read in context, the sentence justifies keeping GET while
   withdrawing the *write* verbs — the surrounding javadoc's stated reason for preserving GET
   anywhere in this block is `store/admin/role.js`, and that caller reads
   `GET /v3/userRole/{id}/functions` — the **`UserRole` association**, which is not being
   un-exported and is unaffected. No caller of `/v3/userRoleUserFunction/search/findByRolelistId`
   is named there or anywhere else.
2. **"Legitimate reverse lookups" describes the Java methods, not the HTTP routes.** All 15
   internal callers (§4) go through the bean. Un-exporting removes the *route* and keeps the
   *method*. The stated legitimacy survives intact.

Four independent caller-detection methods (evidence §B.5, methods A–D) found zero HTTP callers.
So un-exporting contradicts **no** real requirement. I would delete that sentence rather than leave
it — it is the kind of comment that will be read in two years as evidence a client exists.

### Coupled cleanup that will otherwise rot

Un-exporting `UserRoleUserFunction` and `UserGroupUserRole` makes their write-exposure
configuration dead code:

- `RestConfiguration:68-71` — `forDomainType(UserRoleUserFunction.class)` collection + item
- `configureAccessChainMembershipWriteExposure` — `forDomainType(UserGroupUserRole.class)`
  collection + item

These become no-ops (the filter is never consulted for an unmapped type). They are harmless at
runtime but actively misleading: they read as protections. **`SdrWriteExposureUnitTest` will not
fail** — it calls `ExposureConfiguration.filter` directly against a fixture rather than through the
deployed mappings (`:124`, `:131`, `:138`), so it will keep passing green against a surface that no
longer exists. That is a green-test-proving-nothing shape. Either delete both blocks with a comment
pointing at the un-export, or leave them with an explicit "belt-and-braces, type is un-exported by
SBDEV-3183" note — but decide deliberately.

Untouched and still required: `UserGroupUser` (B.4, ruled, has a live caller) and the `User` /
`UserGroup` / `UserRole` association and item withdrawals. Those stay exactly as they are.

### One context test WILL go red — expected, and it is the right one

`SdrRuleInventoryContextTest.theAuthorizationGraphIsExported()` (`:87-99`) hard-asserts that the
three types are exported, by name:

```java
// src/test/java/net/aim_ai/wms/security/SdrRuleInventoryContextTest.java:98
.contains("User", "UserFunction", "UserGroup", "UserGroupUser", "UserGroupUserRole",
        "UserRole", "UserRoleUserFunction", "UserUserRole");
```

Un-exporting `UserGroupUserRole`, `UserRoleUserFunction` and `UserUserRole` makes this fail. That is
correct behaviour, not collateral damage — the assertion's own `.as(...)` message anticipates
exactly this change:

> *"if these stop being exported, Slice 1 is closing a door that is already shut and the rules
> should be deleted rather than left as decoration"*

**Remove those three names from the list** (keep `User`, `UserFunction`, `UserGroup`,
`UserGroupUser`, `UserRole`, which stay exported) in the same commit, and update the `.as(...)`
message to cite SBDEV-3183. Do not weaken the assertion to `containsAnyOf` or delete the test.

The sibling test `everyRuledDomainTypeIsExported()` (`:46-59`) is the coupling enforcer and needs
**no** edit: it passes iff the three rules are deleted alongside the un-export. If someone un-exports
without deleting the rules, it goes red before the boot check is ever reached. Leave it exactly as is.

`SdrSurfaceInventoryContextTest`'s only assertion is `isGreaterThan(20)` (`:121-123`), deliberately
not a ratchet. 62 − 29 = 33 exported types remain, so it stays green with margin.

### Suggested guard for the new invariant

Add to a context test: assert that each of the 29 has `hasMappingFor == true` **and**
`isExported() == false`, and that `SdrFunctionRules.ruledDomainTypes()` intersects the 29 in the
empty set. That pins both halves — the withdrawal and the rule deletion — and will fail loudly if
anyone re-exports one without restoring a rule. Mutation-check it by flipping one annotation back.

---

## 8. What I did NOT verify

Flagging these rather than asserting them:

- **Nothing was run.** No boot, no test, no live request. Every Spring behaviour above is read from
  the 4.5.7 sources on this build's classpath. It is the right version, but it is static reading.
  The five-item floor still wants a failing test first: the cheapest instrument is a context test
  asserting `isExported() == false` for one of the 29, confirmed red before the annotation lands.
- **Exact HTTP status for a withdrawn path.** `lookupHandlerMethod` returns `null`, so other
  `HandlerMapping`s get a chance and `DispatcherServlet` 404s if none match. I did not confirm no
  other mapping in this app claims `/v3/**`, nor how `SecurityConfiguration` rule D
  (`/v3/**` requires `wms_user`) orders against it — an unauthenticated caller plausibly still sees
  401 rather than 404. Worth one probe row, but it does not affect the choice.
- **The 29-type list itself.** Taken as given from evidence §B.5; I did not re-run the four
  caller-detection methods. I did independently confirm the three ruled types are in that list and
  that their `SdrFunctionRules` entries exist at `:220-222`.
- **86 as a search count.** That is explicitly-annotated method-level `@RestResource` paths only,
  and is a **floor** — `exposeRepositoryMethodsByDefault` is `true`, so unannotated query methods
  are exported too. I did not enumerate the true total.
- **Springdoc / OpenAPI output.** Not checked whether `/swagger-ui` reflects SDR withdrawal.
- (This item was open when drafted and is now **closed** — resolved in §7 under "One context test
  will go red". Neither inventory test hard-asserts a count; one hard-asserts three type *names*.)
