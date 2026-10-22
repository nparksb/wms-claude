# Independent review — PR #300 (SBDEV-3183, M-1: `disablePutForCreation` on UserGroup/UserRole)

- **Repo / PR**: `SiteBossInc/wms2-api` #300, `bugfix/SBDEV-3183-usergroup-userrole-put-for-creation` -> `develop`
- **Tip reviewed**: `babefe04` (parent `afbc302f` = merged #299)
- **Diff**: 2 files, +143 / -16 — `src/main/java/net/aim_ai/wms/RestConfiguration.java`, new `src/test/java/net/aim_ai/wms/security/AccessChainPutForCreationWithdrawalContextTest.java`
- **Reviewed**: 2026-09-03, independent lane. Every upstream citation re-derived from the pinned 4.5.7 sources; every UI claim re-derived from a freshly-fetched `origin/develop`. Nothing below is taken from the PR body.
- **Verdict**: **SHIP IT** — 0 High, 2 Medium (both follow-ups, neither in this PR's declared scope), 4 Low.

---

## 1. Mechanism — re-derived from spring-data-rest 4.5.7 sources

Unpacked `spring-data-rest-core-4.5.7-sources.jar` and `spring-data-rest-webmvc-4.5.7-sources.jar` and read the
four types directly. All five sub-claims hold.

**(a) `disablePutForCreation()` is the correct — and only — lever.** Repo-wide grep for
`allowsPutForCreation|verifyPutForCreation` across both jars returns exactly one consumer chain:

```
RepositoryEntityController.java:347-348   if (payload.isNew()) { resourceInformation.verifyPutForCreation(); }
RootResourceInformation.java:142-148      verifyPutForCreation() -> if (!supportedHttpMethods.allowsPutForCreation()) reject(...)
ConfigurationApplyingSupportedHttpMethodsAdapter.java:72-73  allowsPutForCreation() -> configuration.allowsPutForCreation(resourceMetadata)
ExposureConfiguration.java:129-131        allowsPutForCreation(Class) -> creationViaPut.apply(domainType)
```

There is no other write to `creationViaPut` and no other reader. `withItemExposure(... disable(PUT))` cannot
reach it: `creationViaPut` is a **separate field** from the `collection`/`item`/`property` filter chains
(`ExposureConfiguration.java:35-41`), so the PR's assertion that narrowing `WRITE_VERBS` on the ITEM axis does
not touch `allowsPutForCreation()` is correct, and confirmed structurally rather than by testimony.

**(b) It defaults to allowed.** Two independent defaults, both `true`:
`ExposureConfiguration.java:41` — `private Function<Class<?>, Boolean> creationViaPut = __ -> true;` and
`SupportedHttpMethods.java:49` — `default boolean allowsPutForCreation() { return true; }`.

**(c) It was uncalled before this PR.** `grep -n forDomainType RestConfiguration.java` over the pre-PR file
(and the full diff) shows this is the first `disablePutForCreation` call site in the codebase. Confirmed.

**(d) Per-type composition is safe, in both orders.** `TypeBasedExposureConfigurer.disablePutForCreation`
(`ExposureConfiguration.java:206-214`) captures the previous function and chains:

```java
Function<Class<?>, Boolean> current = config.creationViaPut;
config.creationViaPut = type -> this.type.isAssignableFrom(type) ? false : current.apply(type);
```

So the two calls accumulate; neither clobbers the other, and neither is affected by the other
`forDomainType(UserGroup.class)` / `forDomainType(UserRole.class)` blocks in this file — those go through
`withItemExposure`/`withAssociationExposure`, which write `config.item` / `config.property`, disjoint fields.
Call ordering is irrelevant. I also checked the adversarial direction: the **global**
`ExposureConfiguration.disablePutForCreation()` (line 65-69) *replaces* rather than chains
(`this.creationViaPut = __ -> false`) — but replacing with a strictly-more-restrictive constant cannot re-open
these two, so even a later global call is safe. (It is the *over*-gating direction that is unrailed — see M-2.)

**(e) The rejection is a real 405, not a silent behaviour change.** `RootResourceInformation.reject`
(`:160-167`) throws `HttpRequestMethodNotSupportedException(method, supported-minus-PUT)`, which Spring MVC's
`DefaultHandlerExceptionResolver` maps to **405** with an `Allow` header. Same shape as every other withdrawal
in this sweep.

**Ordering detail worth recording** (not in the PR, and it is what makes the sibling analysis in §4 decidable):
`verifySupportedMethod(PUT, ITEM)` runs at `RepositoryEntityController:344`, **before**
`verifyPutForCreation()` at `:348`. So for any type whose item PUT is already withdrawn,
`allowsPutForCreation()` is never consulted and PUT-for-creation is unreachable regardless of its value. The
gap only exists where item PUT stays open.

**Lazy read, not a snapshot.** `RepositoryAwareResourceMetadata` builds the adapter in its constructor
(`:64-67`) holding a *reference* to the live `ExposureConfiguration`; `allowsPutForCreation()` delegates at
call time. So it does not matter whether resource metadata is constructed before or after
`configureRepositoryRestConfiguration` runs. No initialisation-order hazard.

---

## 2. Threat model — the gap is real, and the exploit framing is slightly stronger than the mechanism

The gap is real. `PersistentEntityResourceHandlerMethodArgumentResolver:121-124` resolves
`objectToUpdate = invokeFindById(urlId)`; `read(...)` at `:194-195` takes `readPutForUpdate` **only when that
Optional is present**, otherwise plain `converter.read(...)`. `payload.isNew()` is therefore exactly
"the URL id resolved to nothing", and on that branch `LinkedAssociationSkippingAssociationHandler` is never
constructed, so URI-bound associations survive deserialization. `UserGroup.roles` is
`@ManyToMany(fetch = EAGER, cascade = CascadeType.PERSIST) @JoinTable(name = "mywms_group_mywms_role", ...)`
(`UserGroup.java:22-28`) — the cascade means the join rows are written on the create. Confirmed.

**L-1 (Low) — the escalation framing overstates what a fresh-id PUT achieves.** Both the new javadoc and the
PR body say the fresh-id PUT "was the same hop-2 bind `configureAccessChainMembershipWriteExposure` exists to
prevent". It is not quite the same bind. `configureAccessChainMembershipWriteExposure` prevents binding roles
onto an **existing** group — including the one the attacker already belongs to, which is what confers
privilege. A fresh-id PUT creates a **new** group carrying those roles, and that group confers nothing until
someone is joined to it — hop 1 (`UserGroupUser`) has both collection and item `WRITE_VERBS` withdrawn
(`RestConfiguration.java:201-203`) and hop 2 (`UserGroupUserRole`) is un-exported entirely. Same for
`UserRole.functions`: a forged privileged role is inert until attached to a group.

So this PR is **defence-in-depth plus a data-integrity fix** (an unprivileged `wms_user` could plant a forged
privileged group/role in the admin catalogue, where an administrator might later attach it), not the closure of
a live self-grant. That is still worth closing and the fix is correct — the finding is about claim precision,
which this repo treats as load-bearing. Suggested rewording: "creates a new UserGroup/UserRole carrying
URI-bound privileged associations, the same *construction* route collection POST used — inert until hop 1/2,
both of which are closed, but a catalogue-integrity defect and a defence-in-depth hole".

**Sub-detail, also Low**: `AbstractBaseEntity:19-20` is
`@Id @GeneratedValue(strategy = SEQUENCE, generator = "entity_gen")`. Although the resolver copies the URL id
onto the new object when the row is absent (`:147-158`), Hibernate's sequence generator overwrites it, so the
row does **not** land at the requested id. Irrelevant to the fix; relevant if anyone writes an HTTP-level
regression test asserting "no row at 999999" — that assertion would pass vacuously.

---

## 3. Caller safety — re-derived against freshly fetched `origin/develop`, not a local checkout

Fetched both UIs first. **`wms2-web-ui` `origin/develop` = `290fae7`**, **`wms2-mobile-ui` `origin/develop` = `3744a18`**.

- `git grep '\$put(' origin/develop -- '*.js' '*.vue' | grep -i 'usergroup\|userrole'` returns **exactly two**
  lines repo-wide:
  - `store/admin/group.js:146-148` — `const urlPart = '/' + data.id;` then `$put('/userGroup' + urlPart, data)`
  - `store/admin/role.js:116-118` — `const urlPart = '/' + data.id;` then `$put('/userRole' + urlPart, data)`
- The only dispatchers are `components/admin/userManagement/groups/editGroup.vue:72` and
  `.../roles/editRole.vue:80`, both guarded by `if (this.editMode === 'Edit')`, and in that mode
  `this.item = Object.assign({}, this.itemToEdit)` — an existing grid row, so `data.id` is a live row's id.
  In `'Create'` mode both components dispatch a *different* action entirely.
- Creation does not go through SDR at all: `saveGroup` -> `$post('/userGroup/create')` (`group.js:158-161`)
  and `saveRole` -> `$post('/userRole/create')` (`role.js:131-133`), both MVC controller routes, untouched by
  `ExposureConfiguration`.
- `wms2-mobile-ui` at `3744a18`: `git grep -n 'userGroup\|userRole'` over `store/`, `pages/`, `components/`
  returns **zero** hits. There is no mobile caller to break.

**The PR's caller-safety claim is verified and, if anything, understated** — disabling PUT-for-creation on
these two types costs nothing, because the only two live PUT callers target an existing row and the create
flows never touch SDR.

---

## 4. Scope and sibling gaps

**Scope is exactly right and does not touch anything else.** The new method calls only
`forDomainType(UserGroup.class)` / `forDomainType(UserRole.class)` and only `disablePutForCreation()`, which
writes a field disjoint from every other `forDomainType` block in the file (§1d). The call site is appended
last in `configureRepositoryRestConfiguration` (`:822`); ordering is provably irrelevant. The neighbouring
`configureMustStayWritableCollectionCreateWriteExposure` javadoc was correctly updated from "not closed" to
"closed by `configureAccessChainPutForCreationWriteExposure`", so the file does not carry two contradicting
comments. Good hygiene.

**The escalation-shaped subset of the gap IS fully closed.** SDR generates association resources only for
`isAssociation()` properties, and the file's own audit note (`:509-517`) says exactly three exist repo-wide —
`User.groups`, `UserGroup.roles`, `UserRole.functions`, the only `@ManyToMany @JoinTable` mappings. I did not
take that on trust for the axis that matters: `User`'s item verbs are withdrawn wholesale
(`RestConfiguration.java:274-275`, plus `User` is in `SDR_WRITE_WITHDRAWN`), so per the §1 ordering detail
`verifySupportedMethod(PUT, ITEM)` rejects before `allowsPutForCreation()` is ever consulted. That leaves
`UserGroup` and `UserRole` — precisely the two this PR closes. **No association-binding sibling was missed.**

### M-1 (Medium) — `Boxtype` and `Sysprop` keep PUT-for-creation, bypassing the collection-POST withdrawal they got in this same sweep

I enumerated the residual exhaustively rather than spot-checking. Exported surface is **35 domain types**
(`SdrRuleStartupCheck` boot log from my own test run: "35 exported domain type(s), 5 ruled, 30 unruled").
The 5 ruled are `User`, `UserFunction`, `UserGroup`, `UserGroupUser`, `UserRole`
(`SdrFunctionRules.java:176,180,190,193,202`); the 30 unruled are named in the log. Cross-referencing against
every `withItemExposure` call in `RestConfiguration.java` (all 13 sites listed by grep):

| Exported type(s) | item PUT after this PR | PUT-for-creation |
|---|---|---|
| 23 of the unruled, in `SDR_WRITE_WITHDRAWN` (`:504-506`) | withdrawn | unreachable |
| `User`, `UserFunction`, `UserGroupUser`, `UserRoleUserFunction`, `UserGroupUserRole` | withdrawn | unreachable |
| `Advice` (`:618-619`), `Client` (`:788-789`), `Section` (`:792-793`), `Location` (`:796-797`), `Cyclecount` (`:808-809`), `LocationType` (moved to `SDR_WRITE_WITHDRAWN`) | withdrawn | unreachable |
| `UserGroup` (`:278-281`), `UserRole` (`:283-286`) | **open** (deliberate) | **closed by this PR** |
| **`Boxtype` (`:800-801`), `Sysprop` (`:804-805`)** | **open** (deliberate — live UI callers) | **still open** |

`Boxtype` and `Sysprop` are the complete residual. Both are in
`MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` (`:727-730`) — this sweep deliberately withdrew
`POST /v3/boxtype` and `POST /v3/sysprop` — yet `PUT /v3/boxtype/{unused-id}` and
`PUT /v3/sysprop/{unused-id}` still reach `createAndReturn` and still create a row. **The collection-create
withdrawal on those two types does not currently achieve what its javadoc says it achieves**, by exactly the
mechanism this PR was written to close.

Why this is Medium and not High: I checked both entities for a bindable association and there is none —
`grep -n 'ManyToMany|ManyToOne|OneToMany|OneToOne|JoinTable'` over `model/Boxtype.java` and `model/Sysprop.java`
returns nothing, and the grep is not a false zero (both files exist, are non-empty, and a control
`grep -c '@'` returns 8 and 7 annotation lines respectively). So there is no privilege binding — the residual
is a plain row-creation capability. It is not nothing: `Sysprop` is per-tenant warehouse configuration
(`WMS2_SDR_READ_GUARD_MODE` among others), and where a tenant has **no** row for a given key, PUT-for-creation
is the route that introduces one while collection POST is closed. Mitigating: item PUT to an *existing*
sysprop is already open and live (`store/admin/configuration.js`, two dispatched PUTs), so an attacker who can
reach this can already modify existing sysprops; creation is a marginal addition.

**Suggested fix** — three lines in the method this PR just created, and it makes the method's name honest:

```java
config.getExposureConfiguration().forDomainType(Boxtype.class).disablePutForCreation();
config.getExposureConfiguration().forDomainType(Sysprop.class).disablePutForCreation();
```

Verify first that no UI caller PUTs to a fresh boxtype/sysprop id — from §3's method,
`store/masterData/packaging.js` and `store/admin/configuration.js` are the files to check. (Note the method
would then no longer be "access chain" only; consider renaming, or leaving these two in a sibling method.)
Per the ticket policy this is sub-T3 and belongs on the existing SBDEV-3183 ticket, not a new one.

### M-2 (Medium) — the over-gating rail does not rail this mechanism's actual blast radius

`itemPutToExistingIdRemainsExposed` asserts `getMethodsFor(ResourceType.ITEM).contains(PUT)`. That is a
**different field** from the one the fix writes (§1d: `item` vs `creationViaPut`), and
`disablePutForCreation` provably cannot change it. So the rail cannot fail in response to any misuse of the
mechanism it is railing:

- Replace the two type-scoped calls with the **global** `config.getExposureConfiguration().disablePutForCreation()`
  (`ExposureConfiguration.java:65-69`, one line shorter, an easy future "simplification") and
  PUT-for-creation is silently withdrawn for **all 35 exported types** — and all three tests stay green.
- That is precisely the blast-radius failure this file elsewhere treats as the thing to pin: the
  `configureAccessChainMembershipWriteExposure` javadoc (`:203-206`) says "a bare `withCollectionExposure`
  would make the *entire* HAL API read-only. `AccessChainSdrWriteExposureUnitTest` pins that blast radius".
  The new mechanism has the identical global-vs-scoped hazard and got no equivalent pin.

The rail *is* meaningful against one thing — it would catch someone reaching for `disablePutOnItemResources()`
by mistake — and the two withdrawal assertions are **not** vacuous (I traced
`ResourceMappings.getMetadataFor` -> `RepositoryAwareResourceMetadata.getSupportedHttpMethods()` ->
`ConfigurationApplyingSupportedHttpMethodsAdapter`, which always delegates to the live configuration; there is
no `NoSupportedMethods.INSTANCE` path here that could make them pass for the wrong reason). But the rail as
written does not constrain the axis the fix moves.

**Suggested fix** — one assertion, a positive control on the same boolean for a type outside the fix:

```java
assertThat(mappings.getMetadataFor(Client.class).getSupportedHttpMethods().allowsPutForCreation())
        .as("blast-radius rail: disablePutForCreation must be type-scoped, not global — Client's item PUT is "
          + "withdrawn but its allowsPutForCreation flag is a separate field and must still read true")
        .isTrue();
```

`Client` is the right choice rather than `Boxtype`/`Sysprop`: it survives M-1 being fixed later, and it also
documents the non-obvious fact that `allowsPutForCreation()` stays `true` on a type whose item PUT is
withdrawn. This is 3 lines and cheap enough to fold into this PR rather than defer.

---

## 5. Test quality

Read `AccessChainPutForCreationWithdrawalContextTest.java` in full.

**Pins the right thing.** `ResourceMetadata.getSupportedHttpMethods().allowsPutForCreation()` is the exact
boolean `RootResourceInformation.verifyPutForCreation()` reads (§1a) — one hop from the production decision,
not a proxy for it. Keyed on resource metadata rather than on `RestConfiguration`'s method list, which is the
right choice (a test that asserted "the method is called" would survive the method being made a no-op).

**Not vacuous** in the failure mode that usually bites metadata-level pins — see §M-2 for the trace showing the
adapter is always the live one. Both withdrawal assertions carry a real `.as(...)` explaining what the failure
means. Mutation direction confirmed independently below.

**Verified green here.** `mvn -o test -Dtest=AccessChainPutForCreationWithdrawalContextTest` in the PR worktree:
exit code 0, context started, 3 tests. (Toolchain: `PATH`/`JAVA_HOME` per the sdkman paths.) The change also
compiles clean — `jdtls` is not installed in this environment, so the successful compile of both `src/main`
and `src/test` in that Maven run stands in for `lsp_diagnostics`, and is strictly stronger evidence.

### L-2 (Low) — the pin is configurational, not behavioural

No test issues `PUT /v3/userGroup/{unused-id}` with a `roles` URI array and asserts 405 + zero rows written.
I verified the 405 myself from the 4.5.7 sources (§1e), so the behaviour is not in doubt — but the *repo's own
suite* does not hold that evidence, and a future spring-data-rest upgrade that changed the
`verifySupportedMethod`/`verifyPutForCreation` ordering or the reject shape would not red anything here. Rated
Low rather than Medium because the class javadoc cites `CustomerorderTransferLaneSdrWriteContextTest` as the
established house style for exactly this trade-off, so it is a consistent choice, not an oversight. If a
behavioural row is ever added, note the §2 sub-detail: assert "no new row for that name", not "no row at id
999999" — the sequence generator makes the latter vacuous.

### Gaming analysis

Ways the tests could pass without the fix working, and whether they are open:

| Attack on the test | Open? |
|---|---|
| Metadata resolves to `NoSupportedMethods` (everything false) | **Closed** — no such path for a repository-backed exported type; and test 3 would red |
| Fix replaced by a global `disablePutForCreation()` (over-gates all 35 types) | **OPEN** — see M-2 |
| `configureAccessChainPutForCreationWriteExposure` not wired into `configureRepositoryRestConfiguration` | Closed — assertions read the real context; PR reports mutation-checking exactly this, and the mechanism confirms it would red both |
| `withItemExposure(disable(PUT))` added for these types instead (over-gating via the wrong lever) | Closed — test 3 reds |
| Assertions made against a stale/snapshot metadata | Closed — adapter delegates live (§1) |

---

## 6. Suite-count claim (`6269/0/0/67`, +3)

**Arithmetic is consistent, not independently reproduced.** The diff touches exactly two files and adds
exactly three `@Test` methods; no existing test file is modified, added, or deleted, so +3 from a 6266 baseline
is what the diff predicts, and 67 skips carrying over unchanged is expected.

I deliberately **did not** run the full suite. Three sibling review lanes are active against this same
worktree, and concurrent Maven in one worktree is a known false-red generator in this repo. What I did verify
directly is that the new class compiles and passes green (exit 0). I therefore do not assert the 6269 figure;
I assert only that nothing in the diff is inconsistent with it. **L-4 (Low)** if the ticket needs that number
signed off: re-run `mvn clean test` once, alone in a worktree — and note `mvn` without `clean` runs stale
deleted test classes, which is a separate known trap here.

---

## 7. Findings summary

| # | Sev | Conf | Finding | Where |
|---|---|---|---|---|
| M-1 | Medium | High | `Boxtype` + `Sysprop` keep PUT-for-creation, bypassing the collection-POST withdrawal they got in this same sweep. Complete residual — enumerated exhaustively against all 35 exported types. No bindable association on either, so no escalation. | `RestConfiguration.java:320-330`, `:727-730`, `:800-805` |
| M-2 | Medium | High | Over-gating rail asserts a field the fix provably cannot touch; a global `disablePutForCreation()` would withdraw PUT-for-creation on all 35 types with all 3 tests green. 3-line fix. | `AccessChainPutForCreationWithdrawalContextTest.java:73-85` |
| L-1 | Low | High | Escalation framing overstated: a fresh-id PUT creates a *new* group/role (inert until hop 1/2, both closed), it does not bind roles onto the attacker's own group. Defence-in-depth + catalogue integrity, not a live self-grant. | new javadoc `:296-300`; PR body ¶1 |
| L-2 | Low | Medium | Config-level pin, no HTTP-level 405 / no-row-created assertion. Consistent with house style. | test class |
| L-3 | Low | Low | Javadoc asserts "Nam's call, per the ticket policy" — an in-code attribution of human approval I cannot verify from the repo. Flag for the author, not a defect. | `RestConfiguration.java:707-710` |
| L-4 | Low | High | `6269/0/0/67` not independently reproduced (sibling lanes share this worktree). Arithmetic consistent with the diff; new class verified green alone. | PR body |

None are blocking. M-1 and M-2 are follow-ups on the existing SBDEV-3183 ticket (sub-T3, so per the ticket
policy they go on that ticket, not a new one); M-2 is cheap enough that folding it into this PR is reasonable.

## 8. Positive observations

- **Every upstream citation in the PR body and javadoc checks out against the pinned 4.5.7 sources.** The
  `creationViaPut = type -> this.type.isAssignableFrom(type) ? false : current.apply(type)` quote is verbatim
  and correctly interpreted; the `verifyPutForCreation` -> `HttpRequestMethodNotSupportedException` claim is
  correct; the `payload.isNew()` branch analysis is correct. This is unusually well-grounded for a config
  one-liner — I found nothing overstated except the threat framing in L-1.
- **The caller-safety claim was verified against a freshly-fetched `origin/develop`, and re-verifying it
  reproduced the same answer** (web-ui `290fae7`, mobile-ui `3744a18`) — including the detail that the create
  flows use MVC `POST /userGroup/create` and `/userRole/create`, so SDR PUT-for-creation has no legitimate
  caller at all on these types.
- **The association-binding class of the gap is genuinely, provably complete**, and I verified the closure
  independently of the file's own audit note by checking that `User`'s item PUT withdrawal short-circuits
  `verifyPutForCreation` via the `:344`-before-`:348` ordering.
- **Correct decision to make this its own method and its own PR** rather than a rider on #299 — a mechanism
  the codebase had never used, with a global variant one keystroke away, deserves its own reviewable unit.
- **The stale `🔴 Not closed` residual paragraph on the neighbouring method was rewritten to point at the new
  method** instead of being left to contradict it. This file is heavily commented and that discipline is what
  keeps it trustworthy.
- **Choosing to keep item PUT open and close only PUT-for-creation is the minimal correct cut** — it withdraws
  exactly the unguarded route and leaves both live UI callers untouched.
