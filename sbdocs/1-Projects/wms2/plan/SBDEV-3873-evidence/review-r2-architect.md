# SBDEV-3873 — ralplan round 2 — Architect review

- **Subject:** `plan-snapshot-r2.md` (frozen). Not edited.
- **Code base:** wms2-api `origin/develop` = `4960631d` (fetched 2026-10-22); wms2-web-ui `origin/develop` = `98accaf`.
- **Library sources read:** spring-data-commons 3.5.7, spring-data-jpa 3.5.7, spring-data-rest-webmvc 4.5.7 (`-sources.jar`
  from `~/.m2`, the versions Boot 3.5.9 manages).
- **Live probes (read-only GETs, no auth):** `https://wms-api.sbo.li/api/public/version`, `/actuator/info`, and the served
  Nuxt bundle on `wsl-wineco.wms.sbo.li` and `nywh-hydra.wms.sbo.li`.
- No Maven, no DB access.

## VERDICT: APPROVE (with the edits below folded in; no round 3 needed)

Counts: **High 0 · Medium 1 · Low 7**.

PR 1 and PR-W can go to the TDD gate as written once L1–L6 are folded in. **M1 must be fixed before PR 2's gate.** It is a
test-spec defect in the re-scoped T4, and today's text leaves a vacuous path open, against Principle 4.

---

## 1. Stop-gap safety (Fix A1): can `@ReadOnlyProperty` break a non-SDR write? **No. Verified.**

### 1.1 Who reads `PersistentProperty.isWritable()` / `@ReadOnlyProperty`
I ran a full grep of the three Spring Data source jars for consumers:

| Consumer | Location | Path |
|---|---|---|
| definition | commons `AnnotationBasedPersistentProperty.java:75` `.of(() -> !isTransient() && !isAnnotationPresent(ReadOnlyProperty.class))` | — |
| definition | jpa `JpaPersistentPropertyImpl.java:167-168` `return updateable && super.isWritable();` | — |
| SDR merge-PATCH | rest `DomainObjectReader.java:253` `if (!mappedProperties.isWritableField(fieldName)) { i.remove(); continue; }` | PATCH (json, merge-patch) |
| SDR PUT merge | rest `DomainObjectReader.java:688` `if (property.isIdProperty() \|\| property.isVersionProperty() \|\| !property.isWritable())` | PUT (already withdrawn on both types) |
| SDR JSON-Patch | rest `JacksonBindContext.java:73` `.filter(it -> it.isWritableField(segment))` | PATCH `application/json-patch+json` |
| SDR schema | rest `PersistentEntityToJsonSchemaConverter.java:435` | `/profile` JSON schema (marks `readOnly`; cosmetic) |

There are **no other `.isWritable(` call sites** in commons or jpa. That rules out `SimpleJpaRepository.save`/`merge`,
`JpaMetamodelEntityInformation.isNew`, `AuditingHandler`/`MappingAuditableBeanWrapperFactory`, `PersistentPropertyAccessor`,
and QBE `QueryByExamplePredicateBuilder`. Hibernate ignores `org.springframework.data.annotation.ReadOnlyProperty`, so service
writes persist.

### 1.2 Does an MVC ObjectMapper honour it?
- SDR's mapper is **not a bean**. `RepositoryRestMvcConfiguration.java:521` reads `public ObjectMapper objectMapper() { return
  mapper.get(); }` with no `@Bean`. `persistentEntityJackson2Module(...)` is registered only on SDR's internal mappers (`:249`,
  `:600`) and is not a `Module` bean, so Boot's `JacksonAutoConfiguration` cannot pick it up for the primary mapper.
- Even if it were registered, its deserializer modifier (`PersistentEntityJackson2Module.java:434-470`) only swaps
  deserializers for lookup types and linkable associations. It never drops read-only properties. The field stripping happens
  in `DomainObjectReader`, which only SDR's `PersistentEntityResourceHandlerMethodArgumentResolver` and `JsonPatchHandler`
  construct (`RepositoryRestMvcConfiguration.java:493`).
- The app never touches it. `git grep` over `src/main` for `PersistentEntityJackson2Module|new DomainObjectReader|isWritable()`
  finds only comments (`RestConfiguration.java:608`, `Advice.java:24-25`).

### 1.3 Does anything bind JSON into `Advice` / `Cyclecount`?
- `git grep` for `@RequestBody … Advice|Cyclecount`, `readValue(…Advice|Cyclecount.class)`, `convertValue(…)`, and DTO fields
  typed as either entity returned **0**. The repo has three `convertValue` calls (`JwtAccessTokenCustomizer:59`,
  `CustomerOrderController:124`, `DashboardController:98`), and none targets these types.
- **`CycleCountController.create` does not bind an entity.** `:78`
  `public ResponseEntity<Object> create(@RequestBody Map<String,Object> reqMap, …)`, then `String name = (String)
  reqMap.get("name"); String comment = (String) reqMap.get("comment");` and
  `cyclecountService.createCycleCount(skuIdSet, areaIdSet, …, comment, name)`, which uses setters.
- The four `new Advice()` / `new Cyclecount()` sites (`FileImportController`, `rest/AdviceRestController`, `CyclecountService`,
  `ReceivingService`) all use setters.

### 1.4 Bypass check (plan's "it has no bypass")
- Advice: collection writes are withdrawn (`RestConfiguration.java:640-645`), and item PUT and DELETE are withdrawn (`:682-686`).
- Cyclecount: it is in `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` (`:798-799`), and item PUT and DELETE are withdrawn
  (`:878-880`).
- Neither type has an SDR association, so there is no property-reference route.
- Merge-PATCH and JSON-Patch both pass through `isWritableField`. Unmapped JSON keys fall to `anySetterFound` (false) and are
  removed (`MappedProperties.java:257`).
- **The claim holds.**

### 1.5 Existing tests PR 1 could break
- `git grep` over `src/test` for `patch(` near advice or cyclecount: 0 executable hits (one javadoc,
  `SdrUncalledSurfaceNotExportedContextTest:84`).
- The only `getPersistentProperty("…")` reader is T4 (`"state"`).
- T5 stays green, because `Advice.comment` stays writable.
- **No PR-1 red beyond the planned T5 wording change.**

## 2. AC-8 invariant design

- **Derivable: yes.** Use `persistentEntities.getRequiredPersistentEntity(Advice.class).doWithProperties(p -> …)` filtered by
  `p.getField() != null && p.getField().getDeclaringClass() == Advice.class`. See L5 for the trap.
- **Today's real counts:** Advice declares **19** fields (`Advice.java:12-42`). Cyclecount declares **7** (`number`, `name`,
  `clientId`, `type`, `subtype`, `state`, `comment`; `Cyclecount.java:12-35`). Neither has a getter-only property or an
  association, and `AbstractBaseEntity` contributes `id`, `created`, `modified` and `version`.
- **The thresholds (≥10, ≥5) are sound but loose.** The Advice half contains its own positive control: `comment` must appear
  as writable, so the predicate is shown able to return true. The Cyclecount half (`== {}`) relies on the threshold alone. L5
  gives a stronger second instrument.

## 3. Gates G1 / G2: executable? Yes, with two specification gaps (L1, L2)

- **G1, api.** `GET https://wms-api.sbo.li/api/public/version` answered unauthenticated today with
  `{"environment":"PRD","self":{"repository":"wms2-api","version":"0.0.42"},"drift":false}`. On PRD that is a **release tag,
  not a SHA**. The plan's wording ("reports a build containing PR 1's merge (`git merge-base --is-ancestor` …)") skips the
  tag-to-commit step.
  - Tag `v0.0.42` exists in the repo (dated 2026-10-20).
  - `/actuator/info` reports `build.time` `2026-10-21 05:30:07`, which tells apart two builds of one tag (memory
    *actuator build.time identifies the deploy*).
- **G2, web.** It is executable and sensitive **today**. The served PRD index lists `/_nuxt/{8c5edf2,5670ae2,cff8830,c6e59b2}.js`,
  with the same hashes on wsl-wineco and nywh-hydra. Chunk `c6e59b2.js` contains, minified:
  - `t.$axios.$patch("/advice/".concat(data.id),data)`
  - `t.$axios.$patch("/cyclecount/".concat(data.id),data)`

  So the "absent" half of G2 has a demonstrated positive control. The plan's pattern wording has to match this minified form
  (L2).
- **Is it sound to state the gates in release terms?** Yes. The gates hold the **merge into `develop`**, not a promotion.
  So every release that carries PR-W already postdates PR 1 being served on PRD, and likewise PR 2 after PR-W. UAT is covered
  transitively, which answers the critic's "UAT row" ask.
- **Cost:** three sequential releases. That is acceptable now, because the stop-gap closes the dangerous fields in the first
  one.

## 4. Re-scoped T4 and §8.1

### M1 (Medium). The re-scoped T4 has an empty subject set after PR 2. The plan's fallback non-vacuity guard is vacuous, and m11 is incoherent
- **Evidence:**
  - I intersected the model classes declaring `private String state` with the 47 classes parsed from `SDR_WRITE_WITHDRAWN`
    (`RestConfiguration.java:452-565`).
  - The state-bearing types **not** withdrawn are exactly `Advice` and `Cyclecount`.
  - PR 2 withdraws both. So "every exported type with a `state` property that still exposes PATCH" is the **empty set** on
    the day PR 2 lands.
  - The current T4 (`SdrMustStayWritableStateNotPatchableContextTest:72-77`, `isGreaterThanOrEqualTo(2)`) carries the same
    hazard.
- **What is wrong in the text:**
  1. *"or it asserts the scanned-set size is greater than 0 over all exported types"*. This is satisfied by any non-empty
     export list. It shows the loop ran, not that the predicate can fire. It is the vacuous pass the plan's own Principle 4
     forbids, offered as an equal alternative.
  2. **m11** ("re-scoped T4 with an empty subject set must turn red"). If AC-B4's guard asserts a non-empty found-set, it is
     **permanently red in production**, because the real set is empty. If it does not, m11 is not killed. Either way the row
     cannot be met as written.
- **Fix (text only):**
  - Make the positive control mandatory and delete the "scanned-set > 0" alternative.
  - Factor the predicate into a static method (`writableStateOnPatchExposedTypes(PersistentEntities, ExposureConfiguration)`)
    and add one test that feeds it a synthetic subject (a test-scoped `@Entity` with a writable `state`, or a stubbed
    `PersistentEntity`) and expects 1 offender.
  - Replace m11 with **m12: remove `Advice.class` from `SDR_WRITE_WITHDRAWN` *and* strip `@ReadOnlyProperty` from
    `Advice.state` → T4 red.** This is the real regression the guard exists for. m10 alone leaves T4 green because `state` is
    still annotated, so m10 cannot stand in for it.
  - Keep a second, separate sensitivity floor: "exported types with a `state` property ≥ N" (computed independently of PATCH
    exposure). It proves the `state` detection half works.

### §8.1 completeness: see L6.

## 5. Round-1 dispositions: genuinely resolved?

| Round-1 finding | Resolved? | Evidence in r2 |
|---|---|---|
| Arch M1 / Critic M1 (400 vs 422) | Yes | §5 A2 and AC-4 say 422; `RestExceptionHandler.java:60-61` maps `ApiInvalidParameterException` |
| Arch M2 / Critic M2 (PIT can't reach) | Yes, with gaps (L6) | §8.1 hand-mutant table |
| Arch M3 / Critic M3 (option C) | Yes | Fix A1, D5; §1 shows it is safe |
| Critic H1 (PR-W before PR 1) | Yes | G1 on the merge; §3 above |
| Critic M4 (gate instruments) | Mostly | G1 needs the tag mapping (L1); G2 needs the pattern and hosts (L2) |
| Arch L1 echo on open | Yes | §0 S1, Risk row 1 |
| Arch L2 405 not 404 | Yes | Risk row 1 |
| Arch L3 T4 re-scope | Partly | M1 |
| Arch L4 rollback order | Yes | §5.1 Rollback row |
| Arch L5 paired release | Yes | Driver 2, gate notes |
| Arch L6 NON_NULL | Yes | AC-5 asserts the DB |
| Arch L7 length + numbering | Length yes; numbering **no** | L7 |
| Critic L1 AC-W2 `$nextTick` | Yes | AC-W2 |
| Critic L7 AC-2 version/modified | Over-corrected | L3 |
| Critic "missing": audit log line | Not taken, not dispositioned | Note N1 |
| Critic "executor": base class for AC-2/AC-3 | Not named | Note N2 |

## 6. Findings

### Medium
**M1.** Re-scoped T4 / m11 (§4 above).

### Low
- **L1. G1 must map the PRD version string to a commit.**
  - PRD returns `"version":"0.0.42"`, not `develop-<sha>`. Write the proof as follows:
    `V=$(curl -s https://wms-api.sbo.li/api/public/version | jq -r .self.version)` → `git merge-base --is-ancestor <PR1 merge
    sha> "v$V"` → `git grep -q 'setComment' "v$V" -- src/main/java/net/aim_ai/wms/controller/AdviceController.java`.
  - Then check that `/actuator/info` `build.time` is no earlier than the tag's commit time.
  - Name the PRD api host(s). Only `wms-api.sbo.li` was probed here.
- **L2. G2 must spell out the minified pattern and the host list.**
  - **Present:** `"/advice/setComment"`.
  - **Absent:** `\$patch\("/(advice|cyclecount)/"`. As written, the plan checks only the cyclecount PATCH. The advice PATCH
    must be absent too.
  - Enumerate the PRD web hosts (`<wh>-<tenant>.wms.sbo.li`) and the chunks listed in each `index.html`.
  - Record today's positive control (both PATCH strings present in `c6e59b2.js`).
  - Add one sentence accepting that an SPA tab opened before the web deploy keeps the old JS until reload. A short soak, or
    accepting a few transient 405s, is enough.
- **L3. AC-2 cannot kill m4 as written, and the "unchanged value → no UPDATE" claim has no AC.**
  - AC-2 says `version` "may move", but m4's kill needs `version == seeded + 1`.
  - Add **AC-2b**: re-POST the same comment, and `version` is unchanged. This pins the dirty-check claim that §5 A2 and the
    idempotency checklist rely on, given that the page re-saves on every open.
- **L4. Absent `comment` now means "clear".**
  - The old merge-PATCH left an omitted key untouched. The new DTO maps a missing `comment` to `null` and clears it.
  - The UI sends `{id: data.id, comment: data.comment}`, and `JSON.stringify` drops `undefined`. So a details object whose
    `comment` was dropped by `NON_NULL` sends `{id}`. That is benign only because a missing key there means the DB value is
    already null (`closedNoticeDescription.vue:234-252`, `setInitialComment`).
  - State the semantics in §5 A2 and add `{id}` (no key) to AC-5.
- **L5. Pin AC-8's declared-property derivation and cross-instrument it.**
  - Require `p.getField().getDeclaringClass() == X.class`. **Not `p.getOwner()`**: the owner is `Advice` for inherited
    properties too, which pulls in `id`, `created`, `modified` and `version` and tempts a name-based exclusion.
  - Assert that the scanned set equals the reflection set (`X.class.getDeclaredFields()`, non-static, non-synthetic):
    19 and 7 today. This replaces the loose ≥10 and ≥5 floors with a second instrument that also catches a field Spring Data
    stops reporting.
- **L6. §8.1 gaps.** Add four mutants:
  - (a) Remove `@ReadOnlyProperty` from one Cyclecount field (for example `clientId`) → AC-8 (Cyclecount half) and AC-9
    (cyclecount PATCH; extend AC-9 to cover the mutated field or use `name`).
  - (b) The service skips `null` (`if (comment != null)`) → AC-5.
  - (c) `orElseGet(Advice::new)` or a swallowed not-found → AC-6.
  - (d) PR 2: remove `Cyclecount.class` from `SDR_WRITE_WITHDRAWN` → AC-B1/B2.
  - Optional: extend AC-9 with one `application/json-patch+json` `replace /externalid` case, since `JacksonBindContext:73` is
    a separate code path from `doMerge:253`.
- **L7. Section numbering and the residual list.**
  - §3 is still missing (§2 → §4), and "### 5.1 Prerequisites" sits under §7. §11 says this was fixed.
  - The residual list (§5 A1, Risk row 7) names `created`, `modified` and `version` but not `id`. `id` is also writable
    metadata, and binding a different id fails in Hibernate rather than corrupting data. List it for completeness.

### Notes (unscored)
- **N1.** The critic's suggested `LOG.info("setComment adviceId={} by {}", id, principal)`, without the text, is neither
  adopted nor declined in §11. Disposition it either way.
- **N2.** Name the base class for AC-2/AC-3: Testcontainers plus real filter chain, e.g. `BasePostgresIntegrationTest` +
  `@AutoConfigureMockMvc`, per the critic's `UserRoleRenameUniqueRaceIntegrationTest:59-62` precedent. `BaseControllerIntegrationTest`
  is H2.
- **N3.** After PR 1, `/v3/profile/advice` JSON schema marks 18 fields `readOnly`. No caller reads the profile; this is
  cosmetic.

## 7. Consensus addendum

- **Antithesis (steelman):** the stop-gap makes PR 2 nearly redundant. With every field but `Advice.comment` fenced and an
  invariant test guarding drift, two more releases of cross-repo choreography buy only the closure of `created`, `version`
  and a gated comment write. That is the risk of a 405 regression traded for a marginal security gain.
- **Rebuttal:** the field fence is enforced by a test, not by structure. A future `@MappedSuperclass` field or a new
  inherited column bypasses "declared on Advice". `created` is writable now. And the verb's existence keeps
  `SdrFunctionRules`/guard-mode coupling alive. Withdrawal removes the whole class of drift for one config line.
- **Tradeoff tension:** gate strictness vs latency. Holding merges until PRD serves the predecessor costs three release
  cycles. The stop-gap is what makes that latency tolerable, so the safety of the long tail now rests on AC-8/AC-9 being
  non-vacuous (L5, L6).
- **Synthesis:** keep the plan's shape, keep the annotations after PR 2 (already planned), and make the invariant tests the
  strongest instruments in the plan (L5, M1).

## References
- `v2/wms2-api/src/main/java/net/aim_ai/wms/model/Advice.java:10-42`: 19 declared fields; `state` `@ReadOnlyProperty` at `:31`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/model/Cyclecount.java:9-35`: 7 declared fields; `state` `@ReadOnlyProperty` at `:31`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java:17-35`: inherited `id`/`created`/`modified`/`version`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/RestConfiguration.java:452-575, 640-645, 682-686, 798-805, 857-880, 887-893`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/CycleCountController.java:76-92`: `create` binds `Map<String,Object>`
- `v2/wms2-api/src/test/java/net/aim_ai/wms/security/SdrMustStayWritableStateNotPatchableContextTest.java:51-82`: T4
- `v2/wms2-api/src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java:1112`: `hasSize(231)`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java:60, 200, 384`
- `v2/wms2-web-ui/components/receiving/closed/closedNoticeDescription.vue:209-252`
- spring-data-rest-webmvc 4.5.7: `DomainObjectReader.java:244-256, 688`; `JacksonBindContext.java:73`;
  `MappedProperties.java:247-258`; `PersistentEntityJackson2Module.java:434-470`; `RepositoryRestMvcConfiguration.java:249, 493, 521, 600`
- spring-data-jpa 3.5.7 `JpaPersistentPropertyImpl.java:167-168`; spring-data-commons 3.5.7 `AnnotationBasedPersistentProperty.java:75`
