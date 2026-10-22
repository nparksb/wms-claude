---
title: SBDEV-3215 — independent security review of PR #290
ticket: SBDEV-3215
pr: https://github.com/SiteBossInc/wms2-api/pull/290
branch: bugfix/SBDEV-3215-advice-state-readonly
head: 9a3658bd
reviewer: independent review lane (no prior context on the change)
date: 2026-09-03
verdict: NEEDS CHANGES
---

# SBDEV-3215 / PR #290 — independent code + security review

**Verdict: NEEDS CHANGES.** The fix is correct, the mechanism is real, and it is
*wider* than the PR claims (it also closes PUT and RFC-6902 JSON-Patch, not just
merge-PATCH). Nothing in the diff is wrong. Two things are missing:

- **H-1** — the one structurally identical sibling, `Cyclecount.state`, is left open. It is
  the *only* other entity on the repo's own `MUST_STAY_WRITABLE` list that carries a `state`
  field, its only PATCH caller is the same `saveComment` `{id, comment}` shape, and the same
  one-line fix applies. Fixing the reported instance and leaving the one sibling is exactly the
  failure mode this repo's `SdrMutatingSearchNotExportedContextTest` javadoc warns about.
- **H-2** — `state` is still settable through the **collection POST** route
  (`POST /v3/advice`), which is exposed and does **not** consult `@ReadOnlyProperty`. With
  `id` + `version` in the body that becomes an `em.merge` overwrite of an existing advice,
  which reaches the same outcome AC-1 exists to prevent.

Everything the PR asserts about the mechanism, the caller audit, the `Client` non-fix and the
test's altitude checked out — several of them I expected to find overstated and did not. The
surefire lane is clean on both refs and the identity diff is exactly the intended 3-added /
1-removed with zero collateral (§3).

Finding roster: **H-1**, **H-2** · **M-1**, **M-2** · **L-1** … **L-6**. Neither High is a
defect *in the diff* — both are the same capability reachable by a route the diff did not
close — so this is "needs changes", not "do not merge".

---

## 1. What I verified, and with what instrument

| Claim under test | Instrument | Result |
|---|---|---|
| Dependency versions | `ls ~/.m2/repository/org/springframework/data/*` | commons **3.5.7**, jpa **3.5.7**, rest-webmvc **4.5.7**, rest-core **4.5.7** — matches the test javadoc. (The **PR description** says "spring-data-commons/jpa/rest-webmvc 4.5.7", wrong for commons/jpa — see L-1.) |
| `@ReadOnlyProperty` → `isWritable() == false` | read the extracted `-sources.jar` | Exact. `AnnotationBasedPersistentProperty:74-75` is `!isTransient() && !isAnnotationPresent(ReadOnlyProperty.class)`; `JpaPersistentPropertyImpl:167-168` is `updateable && super.isWritable()`. |
| PATCH strips the field | `DomainObjectReader:253` | `if (!mappedProperties.isWritableField(fieldName)) { i.remove(); continue; }` → `MappedProperties:247-257` → `property.isWritable()`. Confirmed, before Jackson binds. |
| No effect on JPA/Hibernate persistence | `grep -rn "isWritable()"` across both sources jars | **Zero** consumers of `isWritable()` inside spring-data-commons or spring-data-jpa — only spring-data-rest reads it. Internal `advice.setState(...)` + `save()` and the JPQL bulk `updateAdviceToStateById` are structurally unaffected. |
| No effect on GET / serialization | `AbstractPersistentProperty:204`, `PersistentEntityJackson2Module.AssociationOmittingSerializerModifier.changeProperties` | `isReadable()` does not consult `@ReadOnlyProperty`; the serializer modifier consults only associations / id / version. GET output unchanged. |
| `DomainObjectReader` is not a bean in this lane | live probe in a `BaseRollbackIntegrationTest` context | `getBeanNamesForType(DomainObjectReader.class) == []`. **The PR's justification for the test's altitude is correct** — a real HTTP/merge round trip is not available here. |
| New test is not vacuous | `mvn test -Dtest=AdviceStateReadOnlyContextTest` | 2/2 green; the Spring context boots (43s, `SdrRuleStartupCheck` logs 35 exported types), `PersistentEntities` autowires, `requireProperty` asserts non-null before use. |
| Mutation check | removed `@ReadOnlyProperty`, re-ran, restored | `AC-1 stateIsNotWritable` **FAILED** — *"Expecting value to be false but was true"* — while `AC-2` stayed green. Repo left clean (`git status` empty, annotation restored). |
| `toggleEnableReceivingById` is dead | `grep -rn` over `src/`, `git grep` over the repo | No code reference remains. Two **javadoc** mentions survive (see L-2/L-3). Its sibling `updatePrinterToNullByPrinterId` is untouched and still has its live caller `PrinterController.java:168` and its own `@CacheEvict` (`ClientRepository.java:112-114`). |
| `Advice` PATCH caller audit | `git grep` against `origin/develop` of both UI repos + `oms-laravel-api` | **Holds.** Only `store/receiving/inboundNotices.js:380` (`$patch('/advice/{id}', data)`), dispatched from `closedNoticeDescription.vue:242` with a literal `{ id, comment }`. `wms2-mobile-ui` has **zero** `$patch` calls at all. The `patchAdvice` Cypress helper (`cypress/support/helpers/wmsHelpers.js:385`) is **imported but never called** in `inbound-receiving.cy.js:60`. `oms-laravel-api` PATCHes only `v3/client/{id}` (`config/wms.php:104`). |
| `Client` non-fix is genuine | `git show origin/develop:...` | **Holds, for both fields.** `editShipper.vue:56` binds `printerreceivingId` and `:101` binds `enablereceiving`, and `store/admin/shippers.js:59` PATCHes the *whole* shipper object. `WmsApiService.php:3398` sends `enablereceiving` on every client sync. A narrower one-field fix is **not** available: the UI writes both. |
| Which verbs are actually exposed | live probe over `ResourceMappings` | `Advice` COLLECTION `[GET, HEAD, OPTIONS, POST]`, ITEM `[DELETE, GET, HEAD, OPTIONS, PATCH, PUT]`. Positive control: `Customerorder` shows `[GET, HEAD, OPTIONS]` on both — the instrument can see a withdrawal. |

### Two things the fix does that the PR does not claim (both good)

- **PUT is also closed.** `readPutForUpdate` → `readPut` → `mergeForPut` →
  `MergingPropertyHandler.doWithPersistentProperty`, which opens with
  `if (property.isIdProperty() || property.isVersionProperty() || !property.isWritable()) return;`
  (`DomainObjectReader.java:685`). `Advice` is a mutable persistent entity, so the
  `immutableTarget` branch is not taken and the handler runs. `PUT /v3/advice/{id}` with a
  `state` cannot move it.
- **RFC-6902 `application/json-patch+json` is also closed.** `JacksonBindContext:71-73` resolves
  a patch path segment through `MappedProperties.forDeserialization(...).isWritableField(segment)`,
  so `[{"op":"replace","path":"/state",...}]` cannot resolve a writable property either.

Both are worth stating in the PR body — a future reader who only knows "merge-PATCH" may
re-open the question.

---

## 2. Findings

### H-1 (High) — the sibling was not swept: `Cyclecount.state` is still open

`src/main/java/net/aim_ai/wms/model/Cyclecount.java:21`

I enumerated every `@Entity` in `src/main/java/net/aim_ai/wms/model/` carrying a `state`
field and intersected it with the write-withdrawal list. **Fifteen entities have `state`;
thirteen are in `RestConfiguration.SDR_WRITE_WITHDRAWN`. Exactly two are not: `Advice` and
`Cyclecount`.** That is confirmed independently against the repo's own enumeration —
`SdrWriteWithdrawalContextTest.java:146-157` pins `MUST_STAY_WRITABLE` to ten types
(`Section, Advice, Boxtype, Client, Cyclecount, Location, LocationType, Sysprop, UserGroup,
UserRole`), and `Advice` and `Cyclecount` are the only two of the ten with a `state` field.

`Cyclecount` is not a near-miss, it is the same defect in the same shape:

| | `Advice` | `Cyclecount` |
|---|---|---|
| exported | `AdviceRepository.java:19` `path = "advice"` | `CyclecountRepository.java:15` `path = "cyclecount"` |
| in `SDR_WRITE_WITHDRAWN` | no | no |
| `state` field | `Advice.java:32` | `Cyclecount.java:21` |
| its withdrawn mutating search | `updateAdviceToStateById` (`AdviceRepository.java:36`) | — |
| only PATCH caller | `saveComment`, `{id, comment}` (`store/receiving/inboundNotices.js:380`) | `saveComment`, `{id, comment}` (`store/internalOps/cycleCount.js:250`, dispatched from `plannedCycleCountDescription.vue:92`) |
| Cypress PATCH | helper, zero callers | `wmsHelpers.js:859`, body `{ id }` only |
| mobile-ui PATCH | none | none |

So `@ReadOnlyProperty` on `Cyclecount.state` is exactly as safe to ship as the one in this
diff, by the same audit, and its absence means a zero-function `wms_user` can still move a
cycle count's workflow state over `PATCH /v3/cyclecount/{id}`. `CyclecountService` drives that
field through a real state machine (`CyclecountService.java:94/118/157/169` — `CREATED` /
`CANCELLED`), so an arbitrary write to it is a data-integrity defect, not a cosmetic one.

This is the repo's documented fix discipline (*sibling sweep · invariant-over-instance*), and
the sibling test in this very package makes the argument at length:
`SdrMutatingSearchNotExportedContextTest.java:88-92` — *"The security lane reported the three
… Written as a general rule and measured at runtime, the same defect appears nine times …
Fixing the reported instances would have shipped, looked complete, and left six."*

**Recommended:** add `@ReadOnlyProperty` to `Cyclecount.state` in this PR and extend the new
test to cover it. Ideally replace the two per-field pins with one invariant —
*"no exported, non-write-withdrawn domain type exposes a writable `state` property"* — driven
off `ResourceMappings` + `PersistentEntities`, which would also catch the next entity added to
`MUST_STAY_WRITABLE`. Note `@ReadOnlyProperty` appears **nowhere else** in `src/main`, so there
is currently no rail at all preventing this class of regression.

If the tier policy pushes this to its own ticket rather than into this PR (authz + data
integrity ⇒ T3 ⇒ *propose, never file*), then it must at minimum be **proposed on
SBDEV-3215 before merge** and the PR body must stop reading as if the capability is closed.

### H-2 (High) — `Advice.state` is still writable over the collection POST route

`src/main/java/net/aim_ai/wms/RestConfiguration.java:355` (`Advice` absent from
`SDR_WRITE_WITHDRAWN`)

`@ReadOnlyProperty` is consulted on **exactly three** paths: merge-PATCH (`DomainObjectReader.doMerge`),
PUT-with-existing-object (`MergingPropertyHandler`) and JSON-Patch (`JacksonBindContext`).
The **create** path takes a fourth branch that consults none of them:

```
PersistentEntityResourceHandlerMethodArgumentResolver.read(...)   // :176-199
  ├─ PATCH + Jackson converter   → readPatch → doMerge            ← honours isWritable
  ├─ Jackson converter, id present → readPutForUpdate → mergeForPut ← honours isWritable
  └─ else                        → read(request, converter, information)   // :233-237
                                   → converter.read(domainType, …)  ← PLAIN JACKSON
```

`PersistentEntityJackson2Module` registers only `AssociationUriResolvingDeserializerModifier`
(association URI resolution); `grep isWritable` over the whole of spring-data-rest-webmvc finds
it in `DomainObjectReader`, `MappedProperties`, `JacksonBindContext` and
`PersistentEntityToJsonSchemaConverter` — **not** in the Jackson module or the message converter.
So a whole-representation read does not filter non-writable properties.

Measured: `POST /v3/advice` is exposed (live probe: `Advice COLLECTION = [GET, HEAD, OPTIONS,
POST]`), and deserializing a whole representation sets the field:

```
PROBE[objectMapper] readValue(create) -> id=4242 version=0 state=FINISHED
```

Because `AbstractBaseEntity` carries `@Version` (`AbstractBaseEntity.java:34`) and a public
`setId`/`setVersion`, a body carrying `id` **and** `version` deserializes to a non-new entity,
so `SimpleJpaRepository.save` takes `em.merge` rather than `em.persist` — i.e.
`POST /v3/advice {"id":…, "version":…, "state":"FINISHED", …}` overwrites the existing row's
state, reaching the outcome AC-1 exists to prevent, for the same zero-function `wms_user`.

**Confidence and its limit.** The route exposure and the whole-representation deserialization
are both *measured*. What is **reasoned from source, not executed**, is the final hop — that
SDR's own `ObjectMapper` behaves like the plain one here. That mapper bean only exists in the
MockMvc web-context lane, which does not boot (SBDEV-2217), so I could not round-trip an actual
`POST`. The source read is unambiguous (no writability filter on that path), but it is one
instrument short of a demonstrated exploit, and the report should be read that way.

**Recommended:** decide and record which of these it is, before merge —
(a) close it (either put a `state`-shaped guard on the create path, or accept that
`Advice`'s *collection* POST has no caller — the UI creates advices through
`AdviceController` `POST /v3/advice/create`, `AdviceController.java:72`, never the SDR
collection route — in which case withdrawing collection-POST for `Advice` is cheap and safe);
or (b) explicitly scope it out on the ticket as a known residual. What it must not do is ship
described as "the field is closed", because it is closed on three of four write paths.

Note that `DELETE /v3/advice/{id}` is exposed too. That is pre-existing and out of this
ticket's scope, but it belongs in the same residual note.

### M-1 (Medium) — AC-2's "verify against the real payload" is not what the test does

`src/test/java/net/aim_ai/wms/security/AdviceStateReadOnlyContextTest.java:73-81`

The ticket's AC-2 says *"the comment-save flow … is unaffected — **verify against the real
payload, not a synthetic one**"*. The test asserts `Advice.comment`'s
`PersistentProperty.isWritable() == true`. That is a property-level entitled control, not a
payload-level one: it would pass even if something else in the merge path rejected a
`{id, comment}` body.

I do not think a better instrument exists in this lane (no `DomainObjectReader` bean, no
MockMvc lane — both verified above), so this is a **documentation** finding, not a demand to
rewrite the test: say plainly on the ticket that AC-2 is satisfied at property altitude and why
the payload altitude is unavailable, rather than checking AC-2 off as written. The javadoc
already explains the altitude choice well; the AC's own wording is what is unmet.

### M-2 (Medium) — AC-3 asks for PIT; the mutation check was manual

The PR says *"Mutation-checked: removed `@ReadOnlyProperty`, confirmed the test reds"*, and I
reproduced that (it reds correctly, and only AC-1 reds). AC-3 asks for PIT.

PIT mutates bytecode operators and **cannot** add or remove an annotation, so PIT is
structurally incapable of covering this assertion — the manual removal is the right instrument
and the repo's own guidance to prefer PIT does not apply here. But the AC should be amended to
say so rather than being reported as met by a different method; otherwise the next reader
assumes a PIT run exists.

### L-1 (Low) — PR description misstates two dependency versions

The PR body says *"spring-data-commons/jpa/rest-webmvc **4.5.7**"*. Actual: commons **3.5.7**,
jpa **3.5.7**, rest-webmvc **4.5.7**. The test javadoc gets all three right
(`AdviceStateReadOnlyContextTest.java:36-37`); only the PR body is wrong. Cosmetic, but this
is a security change whose whole argument is version-specific.

### L-2 (Low) — stale javadoc asserts the deleted method still needs withdrawing

`src/test/java/net/aim_ai/wms/security/SdrMutatingSearchNotExportedContextTest.java:50-52`

Still reads *"the three that genuinely committed … `Advice.updateAdviceToStateById`,
`Client.toggleEnableReceivingById`, `Client.updatePrinterToNullByPrinterId`"*, and at `:66-68`
still describes both `Advice` and `Client` as fully open. After this PR one of the three no
longer exists and `Advice.state` is closed on the PATCH/PUT/JSON-Patch paths. The test body
itself is a runtime invariant over `ResourceMappings` and is unaffected — this is purely the
prose. Per the repo's own "retitling a section leaves the rule asserted below it" lesson, the
assertion in the prose is what the next reader will act on.

### L-3 (Low) — one more stale reference to the deleted method

`docs/plan/completed/SPRING_BOOT_35_MODERNIZATION_PLAN.md:192` lists
`toggleEnableReceivingById` among `ClientRepository`'s six methods. It is a *completed* plan
doc, so leaving it is defensible as a historical record — flagging only so the decision is
deliberate.

### L-4 (Low) — the eviction pin was rewritten as a name hardcode where deriving was one loop away

`src/test/java/net/aim_ai/wms/unit/config/ClientRepositoryModifyingEvictionUnitTest.java:118`

The old test looped over a two-element `String[]` of method names; the rewrite replaces it with
`String name = "updatePrinterToNullByPrinterId";`. The stated intent (AC-29, and the
`@DisplayName`) is an *invariant* — every `@Modifying` write on `ClientRepository` must carry
`@CacheEvict(clients, allEntries)`. Neither the old nor the new form enforces that: both pin
named methods, so a newly added `@Modifying` method without eviction passes.

This is not a regression — the PR only shrank a list it had to touch. But it was the moment to
derive the set instead: `ClientRepository.class.getMethods()` filtered on
`isAnnotationPresent(Modifying.class)` turns a name pin into the invariant the display name
already claims, and removes the need to edit this test the next time a method is added or
deleted.

### L-5 (Low) — the test javadoc slightly overstates what the assertion discriminates

`AdviceStateReadOnlyContextTest.java:40-44` argues the assertion is stronger than an
annotation-presence check because it would catch *"a JPA `@Column(updatable = false)` on a
sibling"*. In fact `@Column(updatable = false)` on `state` **also** drives
`isWritable()` to false (via `JpaPersistentPropertyImpl`'s `updateable`), so the assertion
pins the *outcome* and cannot distinguish which mechanism produced it. That is the right
choice — outcome over instance — but the stated reasoning does not follow.

---

## 3. Test suite — re-measured, both refs, compared by identity (AC-4)

I ran the surefire lane twice: once on the PR head, once on `origin/develop` in a separate
temporary worktree (separate worktrees, one build at a time — never two Maven runs in one
worktree). The branch is exactly **1 commit ahead of, 0 behind, `origin/develop`**, so
`f440b534` is the correct baseline.

| | `mvn clean test` | unique test identities |
|---|---|---|
| baseline `origin/develop` @ `f440b534` | **6240 / 0 failures / 0 errors / 67 skipped** — BUILD SUCCESS | 6229 |
| PR head `9a3658bd` | **6242 / 0 failures / 0 errors / 67 skipped** — BUILD SUCCESS | 6231 |

Identity diff (`comm` over the two sorted surefire-XML identity sets, `LC_ALL=C`) — **exactly
the intended delta, zero collateral**:

```
ONLY IN BRANCH (added, 3)
  net.aim_ai.wms.security.AdviceStateReadOnlyContextTest#stateIsNotWritable
  net.aim_ai.wms.security.AdviceStateReadOnlyContextTest#commentRemainsWritable
  net.aim_ai.wms.unit.config.ClientRepositoryModifyingEvictionUnitTest#modifyingMethod_carriesAllEntriesEviction

ONLY IN BASELINE (removed, 1)
  net.aim_ai.wms.unit.config.ClientRepositoryModifyingEvictionUnitTest#bothModifyingMethods_carryAllEntriesEviction
```

**No regressions in the surefire lane.** The claim holds.

Two scope notes on the instrument, so a pass is not read as more than it is:

- **The deleted integration-test scaffolding was not executing in either measured run.**
  `ClientRepositoryIntegrationTest$ToggleEnableReceivingById`'s two tests appear in **neither**
  identity set (baseline included), and `ClientControllerLegacyIntegrationTest` is class-level
  `@Disabled` (`:42`). Their home is the failsafe lane (`pom.xml:715-718` includes
  `**/*IntegrationTest.java`; surefire excludes it at `:564-567`), which is the pre-existing
  broken lane (SBDEV-2217) and out of scope here. So the deletions remove no *executing*
  coverage — but neither run says anything about `mvn verify`.
- **L-6 (Low) — the PR's reported figure does not reproduce.** The PR body says
  `6230/0/0/67`. Freshly measured today: **6242** on the branch, **6240** on develop
  (`Skipped: 67` matches on both). The 6230 figure matches neither surefire total; it is one
  below the branch's *unique identity* count (6231), so it looks like a differently-derived
  number reported as the surefire total. Substance is unaffected — 0/0 either way — but the
  numbers in the PR body should be replaced with the pair above plus the identity diff, which
  is what AC-4 actually asks for.

---

## 4. Housekeeping

- The mutation check and the two throwaway probes were run inside the worktree and fully
  reverted. Final state: `git status --short` empty on `bugfix/SBDEV-3215-advice-state-readonly`
  @ `9a3658bd`, `Advice.java` byte-identical to the committed version.
- All maven runs were serialized — one build at a time in this worktree — to avoid the known
  false-red mode from concurrent Maven in a single worktree.
