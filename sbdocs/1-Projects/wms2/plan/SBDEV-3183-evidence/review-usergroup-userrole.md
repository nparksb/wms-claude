# Independent security review — PR #299 (SBDEV-3183, `UserGroup`/`UserRole` collection-POST withdrawal)

- **Reviewer lane:** independent, no prior context on the change; every claim re-derived from source
- **Date:** 2026-09-03
- **PR:** `SiteBossInc/wms2-api` #299 — `bugfix/SBDEV-3183-usergroup-userrole-collection-post` → `develop`
- **Head reviewed:** `201ef8a1` (+138 / −103)
- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3183-usergroup-userrole`

## Verdict

**SHIP IT.**

The escalation-path mechanism claim **holds up in full** under source-level verification against
`spring-data-rest-webmvc` / `spring-data-rest-core` **4.5.7** (the pinned version; sources jars present
in `~/.m2`). Every load-bearing sub-claim — collection POST bypassing `mergeForPut`'s
association-skipping, `UriStringDeserializer` binding the `roles` `@ManyToMany`, the `em.merge`
overwrite of an existing row, the join table being hop 2 (`mywms_group_mywms_role`), the
`SdrGuardMode#OFF` premise that made the pre-existing `SdrFunctionRules` rule inert, and zero
legitimate callers — checked out independently. There is **no pre-existing guard** that already closed
this, so the escalation story is real rather than moot.

Two findings, neither blocking: one **Medium** residual on the *same two types* via a different SDR
path that this PR did not (and did not claim to) touch, and one **Low** on the PR's framing.

---

## 1 · Escalation-path mechanism — re-derived from SDR 4.5.7 source

### (a) Collection POST binds linkable associations via `UriStringDeserializer` — **CONFIRMED**

`PersistentEntityJackson2Module.AssociationUriResolvingDeserializerModifier.updateBuilder`
(`PersistentEntityJackson2Module.java:434-476`) walks every deserializable property; for any property
where `associationLinks.isLinkableAssociation(...)` is true (`:465`) it installs a
`UriStringDeserializer` (`:470`), wrapped by `wrapIfCollection(...)` (`:471`) for `Set`/`List`-typed
properties. So `{"roles":["/v3/userRole/<id>"]}` binds to `UserGroup.roles`.

`Associations.isLinkableAssociation(PersistentProperty)` (`Associations.java:142-157`) requires three
things, all satisfied here — see §2.

### (b) `LinkedAssociationSkippingAssociationHandler` genuinely does NOT run on collection POST — **CONFIRMED**

This is the crux and it is decided in one method,
`PersistentEntityResourceHandlerMethodArgumentResolver.resolveArgument`:

- For a **collection** POST there is no `{id}` path segment, so
  `idResolver.resolveArgument(...)` returns `null` → `Optional<Serializable> id` is **empty** →
  `objectToUpdate` is **empty**.
- `read(...)` then reaches the "JSON + PUT request" branch and evaluates
  `objectToUpdate.map(it -> readPutForUpdate(request, mapper, it)).orElseGet(() -> read(request, converter, information))`.
  With `objectToUpdate` empty it takes the `orElseGet` arm — **plain `converter.read(domainType, …)`**,
  i.e. ordinary Jackson deserialization.
- The skipping handler only exists on the other arm:
  `readPutForUpdate` → `JsonPatchHandler.applyPut` → `DomainObjectReader.readPut`
  (`DomainObjectReader.java:114-122`) → `mergeForPut` (`:133-169`), which is the *only* place
  `new LinkedAssociationSkippingAssociationHandler(associationLinks, propertyHandler)` is constructed
  (`:162`; class at `:621-645`, early-returns for linkable associations at `:637-640`).

So the PR's claim is precise: the association-skipping that makes item **PUT** safe is structurally
absent from the collection-create path.

### (c) The `em.merge` overwrite step — **CONFIRMED**

- `AbstractBaseEntity` (`src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java:34-35`) declares a
  **nullable** `@Version private Integer version` alongside `@Id @GeneratedValue(SEQUENCE)`.
- Spring Data JPA's `JpaMetamodelEntityInformation.isNew` keys on a non-primitive version attribute
  (`version == null`). A body carrying `"version": N` therefore makes the entity **not new**, so
  `SimpleJpaRepository.save` calls `em.merge(...)` rather than `em.persist(...)`.
- `RepositoryEntityController.postCollectionResource` (`:246-263`) hands the payload straight to
  `saveAndReturn(...)` → `invoker.invokeSave(...)`.
- `UserGroup` is the **owning** side of the join table, so merging with a populated `roles` set
  rewrites the `mywms_group_mywms_role` rows.

Net: `POST /v3/userGroup {"id":X,"version":N,"number":…,"clientId":…,"roles":["/v3/userRole/<privileged>"]}`
updates the **existing** group X and rebinds its roles. (The `@NotNull number`/`clientId` fields are
trivially echoed back from the still-exposed `GET /v3/userGroup/{id}`.)

### (d) Was an existing guard already closing it? — **NO**

Checked explicitly, because if one existed the escalation story would be moot rather than
merely closed twice:

- `git grep -n "exported" -- src/main/java/net/aim_ai/wms/model src/main/java/net/aim_ai/wms/repository`
  returns **one hit, and it is a javadoc word in `User.java:31`** — no `@RestResource(exported = false)`
  and no `@ReadOnlyProperty` on `UserGroup.roles` or `UserRole.functions`.
- `UserRoleRepository` and `UserGroupRepository` (both in `src/main/java/net/aim_ai/wms/repo/jpa/`) are
  plain `@RepositoryRestResource(...)` — exported. The `exported = false` markers in those files are on
  **individual query methods** (`findByUsername`, `findHolderNamesByIds`, `deleteGroupById`,
  `deleteRoleById`), not on the repository, so they do not affect the aggregate resource.
- The one mechanism that *did* nominally cover these two types — `SdrFunctionRules` entries at
  `SdrFunctionRules.java:190` (`UserGroup` → `USER_ADMIN_VIEW`) and `:202` (`UserRole`) — is inert, see §3.

---

## 2 · `UserGroup.roles` is a linkable `@ManyToMany` onto hop 2 — CONFIRMED

`src/main/java/net/aim_ai/wms/model/UserGroup.java:22-28`:

```java
@ManyToMany(fetch = FetchType.EAGER, cascade = CascadeType.PERSIST)
@JoinTable(
    name = "mywms_group_mywms_role",
    joinColumns = {@JoinColumn(name = "grouplist_id")},
    inverseJoinColumns = {@JoinColumn(name = "rolelist_id")}
)
private Set<UserRole> roles = new HashSet<>();
```

That is **exactly** hop 2 of the four-hop access chain documented in
`RestConfiguration.java:108-116` — `mywms_user → mywms_group_mywms_user → mywms_group_mywms_role →
mywms_role_mywms_function → mywms_function`. Not a lesser relationship.

`isLinkableAssociation` satisfied on all three conditions: it is a JPA association; `UserGroup`'s own
metadata exports the property (no `exported = false`); and the **target** type `UserRole` has an
exported repository.

**Symmetric case, worth naming because the PR does not:** `UserRole.functions`
(`UserRole.java:27-33`) is `@ManyToMany` onto `mywms_role_mywms_function` — **hop 3**. So the
`UserRole` half of this PR closes `POST /v3/userRole {"id":…,"version":…,"functions":[…]}`, which is the
*more direct* primitive (grant an arbitrary function to a role you already hold, no group step). See
finding L-1.

---

## 3 · The `SdrGuardMode#OFF` premise — verified against live databases

The PR argues the pre-existing `SdrFunctionRules` coverage "closed nothing" because every tenant sits
at `OFF`. `SdrFunctionGuard.java:206-210` short-circuits and allows when `modeProvider.current()` is
`OFF`, and `SdrGuardModeProvider.current()` (`:62-74`) returns `OFF` when the
`WMS2_SDR_READ_GUARD_MODE` sysprop row is absent, unparseable, or lookup fails.

Queried directly:

| Environment | Result |
|---|---|
| **prd** `wh01_hydra_v2` (Hydra — the only v2 prod client) | **no `WMS2_SDR_READ_GUARD_MODE` row at all** → `OFF` |
| **dev** wineco | row present, `sysvalue = 'OFF'` |

Positive control on the prd query (a zero-scan needs one): the same statement reported
`sysprop_rows = 145` and `sdr_keys = 0`, so the table is populated and readable — the zero is a true
zero, not a broken instrument.

Same query also confirms the target is a real, populated structure on prd:
`mywms_group = 9`, `mywms_role = 9`, `mywms_group_mywms_role = 14`.

**Premise verified.** The rules really were inert, and the exclusion this PR reverses really did leave
the route open.

---

## 4 · Zero legitimate collection-POST callers — re-derived against `origin/develop`

Swept all three client repos at freshly-fetched `origin/develop` (not the local checkouts):
wms2-web-ui `290fae70`, wms2-mobile-ui `3744a185`, oms-laravel-api `8ccad384`.

Every write-verb call naming `userGroup`/`userRole` (8 store calls + 2 Cypress helpers) resolves to a
**named MVC subpath**, never the bare collection root:

| Call site | Verb | URL | Resolves to |
|---|---|---|---|
| `store/admin/group.js:133` | POST | `/userGroup/saveGroupRoles` | `UserGroupController.saveGroupRoles` `@PostMapping:137` |
| `store/admin/group.js:160` | POST | `/userGroup/create` | `UserGroupController.create` `@PostMapping:84` |
| `store/admin/group.js:148` | PUT | `/userGroup/{id}` | SDR **item** route (untouched by this PR) |
| `store/admin/role.js:103` | POST | `/userRole/saveRoleFunctions` | `UserRoleController.saveRoleFunctions` `@PostMapping:127` |
| `store/admin/role.js:133` | POST | `/userRole/create` | `UserRoleController.createRole` `@PostMapping:79` |
| `store/admin/role.js:118` | PUT | `/userRole/{id}` | SDR **item** route (untouched) |

**Gating checked per-method, not per-class** (the task rightly insisted, given SBDEV-3013's history of
gates that didn't cover what was assumed): the four POST handlers above carry no method-level
annotation, but are covered by the **class-level**
`@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_USER_MANAGEMENT)` at
`UserGroupController.java:46` and `UserRoleController.java:39`, and both classes are members of
`FunctionGuardInterceptor.GUARDED` (`FunctionGuardInterceptor.java:144-145`) — which is what makes the
class annotation actually enforce rather than sit inert. Neither controller declares any
`@Put/@Patch/@DeleteMapping`.

*Known limitation, documented in-repo at `UserGroupController.java:32-45` and not relevant to these
routes:* the class-level annotation does not reach the nine handlers **inherited** from
`AdminController` (the interceptor keys on `getDeclaringClass()`); those carry
`@PreAuthorize(IS_SB_ADMIN)` instead.

**Dynamic-URL hunt** (what a literal grep would miss): the four `'/userGroup' + urlPart` /
`'/userRole' + urlPart` concatenations look computed but are not — `urlPart` is a `const` bound to
`''` three lines above in both POST cases, and `'/' + data.id` in both PUT cases, so no path yields a
bare collection root. web-ui's only generic `$post(url, payload)` helper
(`store/admin/labelPrinting.js:256`) has four literal in-file callers, all label-printing. mobile-ui
contains **zero** occurrences of either type. OMS reaches WMS only through `WmsApiService`'s
config-key helper, and `config/wms.php` has no `userGroup`/`userRole` key; its four bare-collection
keys are consumed GET-only. Filesystem `grep -rn -a` (defeating both the gitignored `reports/` dir and
ugrep's binary skip) returned exactly the `git grep` set.

**Instrument sanity:** the sweep did surface all 10 known write sites, so the zero on bare-collection
POST is a true zero.

---

## 5 · Item verbs unaffected, existing fencing untouched — CONFIRMED

The diff touches exactly three things: the `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` array
(`RestConfiguration.java:663-666`, +`UserGroup.class, UserRole.class`), the surrounding javadoc, and
two test files. `configureAccessChainMembershipWriteExposure` and `configureRoleFunctionWriteExposure`
are **not modified and not duplicated**.

Still in force, unchanged:

| Route | State | Citation |
|---|---|---|
| `/v3/userGroup/{id}/roles` (association) | writes disabled | `RestConfiguration.java:266-268` |
| `/v3/userRole/{id}/functions` (association) | writes disabled | `:98-100` |
| `/v3/userGroup/{id}` item PATCH + DELETE | disabled | `:277-280` |
| `/v3/userRole/{id}` item PATCH + DELETE | disabled | `:282-285` |
| `/v3/userGroupUser`, `/v3/userGroupUserRole` | all writes disabled | `:200-214` |
| `/v3/userRoleUserFunction` | un-exported entirely (Slice 2) | `:91-94` (belt-and-braces) |
| `/v3/userGroup/{id}` and `/v3/userRole/{id}` item **PUT** | **kept** (UI needs it) | pinned by `AccessChainSdrWriteExposureUnitTest.adminAggregateWritesAreUntouched:238-241` |

The "item PUT is safe" premise those kept routes rest on is itself correct **for an existing target**:
`readPut` deserializes the body into an `intermediate` (so `roles` *is* bound there), then `mergeForPut`
copies onto the target via `doWithProperties` — which never visits associations — and
`doWithAssociations(LinkedAssociationSkippingAssociationHandler)`, which early-returns for linkable
ones. The target keeps its original `roles`. **But see finding M-1: that reasoning does not extend to a
PUT whose target does not exist.**

---

## 6 · The redesigned blast-radius sentinels — mechanism checked and mutation reproduced

**Mechanism.** `ExposureConfiguration.filter(methods, type, metadata)` (`ExposureConfiguration.java:136-146`)
dispatches to a single composed `ComposableFilter` per axis. Every `forDomainType(...)` registration is
wrapped by `withTypeFilter` (`:152-160`):

```java
return (metadata, httpMethods) ->
    type.isAssignableFrom(metadata.getDomainType())
        ? function.filter(metadata, httpMethods)
        : httpMethods;   // ← pass-through, no fallback
```

There is **no fallback branch** that could coincidentally restrict an unmatched class. The base filters
are `AggregateResourceHttpMethodsFilter.none()` / `AssociationResourceHttpMethodsFilter.none()`. The
tests' `filterAggregate`/`aggregate` helpers mock only `ResourceMetadata.getDomainType()`, which is the
sole input the predicate consults — so the fixture is faithful.

`UnconfiguredSentinelType` is a `private static final class` visible only inside each test file,
extending `Object`, and no rule in `RestConfiguration` targets `Object` or any supertype of it.
Matching is on `isAssignableFrom`, so a hypothetical future `forDomainType(SomeBaseClass.class)` rule
*would* catch subtypes — irrelevant here, but worth knowing before reusing the pattern.

**Mutation check A — global unscoped exposure (the one the PR claims).** Injected at the top of
`configureRepositoryRestConfiguration`:

```java
config.getExposureConfiguration()
    .withCollectionExposure((metadata, httpMethods) -> httpMethods.disable(WRITE_VERBS));
```

(Top-of-method is the *subtle* placement: a bare `withCollectionExposure` **replaces** `this.collection`
(`ExposureConfiguration.java:45-49`), so placing it first lets the scoped rules survive as `andThen`
composition — the realistic "someone added a global rule" shape, rather than one that wipes everything.)

Result — **both redesigned sentinels red, and nothing else**:

```
[ERROR] AccessChainSdrWriteExposureUnitTest.unconfiguredDomainTypeIsUntouchedByAnyFilter:273
[ERROR] SdrWriteExposureUnitTest.unconfiguredDomainTypeIsUntouchedByAnyFilter:212
[ERROR] Tests run: 18, Failures: 2, Errors: 0, Skipped: 0
```

2 failures out of 18 tests in those two classes — the pins are **specific**, not incidentally coupled to
other assertions. This is the property the old entity-keyed sentinel could never demonstrate cleanly.

**Mutation check B — the withdrawal itself.** Removed `UserGroup.class, UserRole.class` from the array:

```
[ERROR] MustStayWritableCollectionPostWithdrawalContextTest.collectionPostIsWithdrawnEverywhere:164
[INFO]  SdrWriteWithdrawalContextTest — Tests run: 3, Failures: 0   (correctly unaffected)
```

Note this one is a **context** test (`BaseRollbackIntegrationTest`, ~19 s) measuring the deployed
`ResourceMappings`, not a mocked filter — so it proves the withdrawal actually lands on the real
exported resource, not merely that the config expresses it.

**Both mutations reverted; `git status --porcelain` returns 0 lines. Worktree clean.**

**Arithmetic checked:** `SdrWriteWithdrawalContextTest.MUST_STAY_WRITABLE` has **9** members
(`:168-180`); minus `Advice` (covered by its own `configureAdviceCollectionCreateWriteExposure`) = **8**,
matching both the `isEqualTo(8)` sensitivity check and the 8-entry withdrawal array. Consistent.

---

## 7 · Suite claim — reproduced

`mvn clean test` in this worktree:

```
[WARNING] Tests run: 6266, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
```

**Exactly the PR's claimed `6266/0/0/67`.** All four relevant classes ran and were green:
`SdrWriteWithdrawalContextTest` (3), `MustStayWritableCollectionPostWithdrawalContextTest` (4),
`AccessChainSdrWriteExposureUnitTest` (12), `SdrWriteExposureUnitTest` (6). No surefire regressions.
(The known-broken SBDEV-2217 failsafe/IT lane was not exercised and is not implicated.)

---

## Findings

### M-1 · Medium — the same association-binding path is still open on the item PUT these two types keep, via SDR's PUT-for-creation

**Not introduced by this PR and outside its stated scope. Should not block the merge.** Raised because
it lands on the *same two types*, by the *same mechanism*, and because it makes a safety claim the
codebase repeats in several places narrower than it is written.

`PUT /v3/userGroup/{id}` where `{id}` **does not exist** takes the identical plain-Jackson path this PR
just closed on the collection route. In
`PersistentEntityResourceHandlerMethodArgumentResolver.resolveArgument`, `id` is present but
`resourceInformation.getInvoker().invokeFindById(it)` returns empty, so `objectToUpdate` is empty and
`read(...)` again falls to `orElseGet(() -> read(request, converter, information))` — **plain
`converter.read`, no `mergeForPut`, no `LinkedAssociationSkippingAssociationHandler`.** The resolver
then builds the payload via `build.forCreation()`, so `payload.isNew()` is true and
`RepositoryEntityController.putItemResource:347` calls `verifyPutForCreation()`.

That check passes: `RootResourceInformation.verifyPutForCreation:142-149` rejects only when
`allowsPutForCreation()` is false, and `ExposureConfiguration`'s `creationViaPut` defaults to
`__ -> true` (`:42`). **`disablePutForCreation()` is never called anywhere in `RestConfiguration.java`**
(grep: zero hits), and item PUT is deliberately kept for both types.

Effect at `SdrGuardMode#OFF` — i.e. everywhere today:

- `PUT /v3/userGroup/<any-unused-id>` with `{"roles":["/v3/userRole/<privileged>"]}` creates a **new**
  `UserGroup` pre-bound to arbitrary roles.
- `PUT /v3/userRole/<any-unused-id>` with `{"functions":["/v3/userFunction/<any>"]}` creates a **new**
  `UserRole` holding arbitrary functions.

…for any authenticated zero-function `wms_user`. (`@GeneratedValue(SEQUENCE)` means the attacker does
not control the resulting id, and `@NotNull number`/`clientId` are trivially supplied.)

**This is not a completed privilege escalation today**, and that is why it is Medium and not High: hop 1
is closed (`UserGroupUser` collection+item writes disabled at `RestConfiguration.java:200-203`, `User`
association writes at `:261-263`), so the attacker cannot join the group they just created. It *is*
unfenced row creation into the access-control tables by a caller with no user-management function.

The precision problem it exposes: `RestConfiguration.java:270-272` states
*"PUT is safe (mergeForPut skips linked associations) and is kept where the UI needs it"*, and
`UserRoleRepository`'s javadoc says the same. Both are true **only for an existing target**. This PR's
new javadoc leans on the same framing — *"a path `mergeForPut`'s `LinkedAssociationSkippingAssociationHandler`
does not run"* — implying that property is unique to collection-create. It is not.

**Recommended follow-up (not for this PR):** either call
`config.getExposureConfiguration().disablePutForCreation()` (no UI depends on creating by client-chosen
id — every UI create goes through `/create` on the controller), or qualify the three "PUT is safe"
javadoc statements to say *"safe for an existing target; PUT-for-creation takes the plain-Jackson
path."* Per the ticket policy this is T3-shaped (access-control mechanism), so **propose to Nam rather
than file**.

*Confidence:* derived from framework source + repo config, **not** exercised against a running
instance. The config facts (`disablePutForCreation` never called; item PUT kept) are certain; the
end-to-end reachability is a source-level inference and deserves a live probe before any fix is scoped.

### L-1 · Low — the javadoc names only the hop-2 case; the `UserRole` half closes hop 3 and is not described

`RestConfiguration.java:629-651` and the matching test javadoc both narrate only
`POST /v3/userGroup … "roles":[…]` (hop 2, `mywms_group_mywms_role`). The `UserRole` inclusion is
carried as "symmetrically" without saying what it closes:
`POST /v3/userRole {"id":…,"version":…,"functions":["/v3/userFunction/<any>"]}` rebinds
`mywms_role_mywms_function` — **hop 3**, the surface `configureRoleFunctionWriteExposure` (door ①) exists
to fence, and the more direct primitive of the two (no group step needed). Given how carefully this
file records *why* each rule exists, the second type deserves its own sentence rather than inheriting
the first's.

### L-2 · Low / informational — the redesigned sentinel is near-tautological for the scoped case

`UnconfiguredSentinelType` can only ever fail if a **global** (unscoped) filter appears — for scoped
rules the assertion is true by construction. That is precisely the blast-radius property the sentinel is
meant to pin, and mutation A proves it is killable, so this is a **note, not a defect**. It is a strict
improvement over the previous design, which had burned through three production entities
(`Itemdata` → `Client` → `UserGroup`) and, per its own forward warning, had no fourth candidate left.
Recording it so nobody later reads the tautology as a reason to delete the pin — which is exactly the
failure mode the old comment chain kept warning about.

---

## What I checked and found nothing wrong with

- No accidental duplication of, or edit to, `configureAccessChainMembershipWriteExposure` /
  `configureRoleFunctionWriteExposure`.
- Ordering: `configureMustStayWritableCollectionCreateWriteExposure` runs at `:756`, before
  `configureRoleFunctionWriteExposure` at `:774`; irrelevant, since all `forDomainType` registrations
  compose with `andThen`.
- No reverse association exists on `UserRole` back to `UserGroup` (the model declares only `functions`),
  so there is no `/v3/userRole/{id}/groups` route to worry about.
- The renamed exclusion set `RULED_ELSEWHERE` → `ITEM_VERBS_AUDITED_ELSEWHERE` is applied to the item-verb
  check only, and removed from the collection-POST and collection-GET traversals — the sensitivity
  assertion (`isEqualTo(8)`) and the `REQUIRED_ITEM_VERBS` key-set pin both remain non-vacuous.
- Both controller files are byte-identical to `origin/develop` — this PR changed configuration and tests
  only.
