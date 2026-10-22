---
head: 76f60dc2
lane: Phase 3b independent code review (PR 1, wms2-api)
reviewer: code-reviewer (separate lane; did not author)
date: 2026-10-22
verdict: APPROVE
counts: {high: 0, medium: 0, low: 9}
---

# SBDEV-3873 PR 1: code review

head: 76f60dc2

Scope: `git diff origin/develop...76f60dc2` in `.claude/worktrees/wms2-api/SBDEV-3873` (11 files, +948/-3).
Plan scope: §5 Fix A1/A2, §8 PR-1 ACs, §8.1. Read-only lane: no mvn, no checkout, no edits (a full suite was running in the worktree).

## Verdict

**APPROVE. High 0 · Medium 0 · Low 9.** Every Low finding is about a comment or how strong a test is. No production behaviour defect was found.

## What was verified (method, not just assertion)

| Claim | Method | Result |
|---|---|---|
| Fence covers every declared field | grep of every non-static field declaration in `Advice.java` / `Cyclecount.java` against the diff | Advice: all 17 declared fields except `comment` annotated. Cyclecount: all 7 annotated. No `@Transient` or getter-only property on either. |
| `@ReadOnlyProperty` reaches nothing outside SDR | grep `isWritable` across the spring-data-commons 3.5.7, spring-data-jpa 3.5.7 and spring-data-rest-webmvc 4.5.7 sources jars | Only consumers: `JpaPersistentPropertyImpl` (its own flag), SDR `MappedProperties`, `DomainObjectReader` (PATCH merge, PUT merge), `JacksonBindContext` (JSON-Patch), and `PersistentEntityToJsonSchemaConverter` (the profile schema; see L2). Hibernate, auditing and Spring Data JPA's repository paths never read it. |
| No non-SDR JSON→entity path is affected | grep `readValue/convertValue/treeToValue(...Advice/Cyclecount.class)`, `TypeReference<Advice/Cyclecount>`, `@RequestBody Advice/Cyclecount` in `src/main` | None. OMS create (`/rest/advice/create`) and `CycleCountController.create` build the entities through setters, which the annotation does not touch. |
| Other SDR verbs on these types | `RestConfiguration` `configureAdviceCollectionCreateWriteExposure`, `configureAdviceItemVerbWriteExposure`, the must-stay-writable methods | Collection POST is withdrawn on both types; item PUT/DELETE too. Item PATCH (merge and JSON-Patch) is the only write verb left, and the fence covers it. |
| `NON_NULL` drops a null `comment` from the `Map` response | `javap -c` on jackson-databind 2.19.4 `ObjectMapper.setSerializationInclusion` | `JsonInclude.Value.construct(incl, incl)`: content inclusion is NON_NULL too, so null map values are dropped. Plan §5 A2's claim holds. |
| Column width 255 | `V2.2.00__base_v2_schema.sql` (advice: `comment character varying(255)`) and `v1-to-v2-onboarding/.../V1.0.01__wms_tables.sql` (same) | Both tenant schema lineages are 255. |
| 422/404/409 mapping | `RestExceptionHandler` :60 (`ApiInvalidParameterException` → 422), :200 (`EntityNotFoundException`), :384 (`ObjectOptimisticLockingFailureException` → 409) | Correct. A commit-time `OptimisticLockException` is translated by `HibernateJpaDialect` into `ObjectOptimisticLockingFailureException`, so the 409 reaches the handler. |
| Id type | `AdviceCommentRequest(Long id, String comment)` | `Long`, with no `(Integer)` cast (the sibling `setPurchaseOrderNumber` has one, at `AdviceController.java`, `((Integer) reqMap.get("id")).longValue()`). Large ids are safe. |
| Transaction manager | `AdviceService.setComment` | `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, the same as the plan. |
| LOG labels | `AdviceController.setComment` | `"start setComment id={}"` and `"end setComment id={}"` name only the method itself (CLAUDE.md corollary at :335). |
| Existing tests broken by the fence | grep `src/test` for `patch(` on `/v3/advice`/`/v3/cyclecount`, and for `isWritable`/`"comment"` property assertions | Only T5 (updated in 76f60dc2) and `SdrMustStayWritableStateNotPatchableContextTest` (state only, unaffected). |
| Cypress callers (web, origin/develop) | `git grep patchAdvice/patchCycleCount` | `patchCycleCount` sends `{id}` only; `patchAdvice` is imported but unused. Neither breaks under the fence. |

## Issues

All Low. Each has a quoted snippet, a failure scenario and a fix.

### [LOW] L1: present-tense comments describe the post-PR-W world as if it were true at PR 1
Confidence: HIGH
- `src/main/java/net/aim_ai/wms/model/Cyclecount.java` (SBDEV-3215 block):
  `// (SBDEV-3873: ... and the readonly comment box no longer echoes a PATCH.)`
- `src/test/java/net/aim_ai/wms/security/AdviceStateReadOnlyContextTest.java` class javadoc:
  `... and the UI saves the comment through {@code POST /v3/advice/setComment}.`
- `src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` row comment:
  `Gated on the Inbound BOL screen's own function — the only caller is closedNoticeDescription.vue.`
- `src/main/java/net/aim_ai/wms/model/Advice.java` header: `the comment is saved through POST /v3/advice/setComment`

Failure scenario: at PR 1 the web UI still sends `PATCH /v3/cyclecount/{id}` on every planned-count open, and still saves the advice comment through `PATCH /v3/advice/{id}`. `setComment` has **no** caller until PR-W ships. Someone reading the Cyclecount comment while preparing PR 2, or while triaging a PATCH they see in a log, is told the PATCH no longer happens. That is the exact claim gate G2 exists to prove rather than assume.

Fix: use future/conditional tense tied to PR-W. For example, "the readonly box's echo PATCH now binds nothing; PR-W deletes the echo"; "the UI moves to POST /v3/advice/setComment in PR-W"; "its caller (from PR-W) is closedNoticeDescription.vue".

### [LOW] L2: completeness word "only" in the Advice fence comment omits a consumer
Confidence: HIGH
- `Advice.java`: `// The annotation is read only by SDR's web binding (DomainObjectReader / JacksonBindContext); Hibernate and every service setter are unaffected.`

`PersistentEntityToJsonSchemaConverter.java:435` (`boolean isNotWritable = property.map(it -> !it.isWritable())`) also reads it. After this PR, `GET /v3/profile/advice` and `/v3/profile/cyclecount` (Accept `application/schema+json`) mark every field `readOnly: true`. No UI consumes that today, so nothing breaks. But the sentence makes a completeness claim, and the method behind it is not stated.

Fix: "read only by Spring Data REST (the PATCH/PUT merge in DomainObjectReader, JSON-Patch via JacksonBindContext, and the profile JSON schema)". Name the method: grep for `isWritable` across the three spring-data sources jars at the pinned versions.

### [LOW] L3: "for any caller" overstates the pre-fix exposure
Confidence: MEDIUM
- `Advice.java`: `Before this the PATCH bound clientId, type, externalid, transferId and the rest for any caller.`

`SdrFunctionRules.java:434` maps `Advice → INBOUND_BOL_VIEW` (and `:437` maps `Cyclecount → CYCLECOUNT_VIEW`). Under `ENFORCE_RULED` the PATCH needs that function, so "any caller" holds only in the OFF/observe modes. A reader who sizes the blast radius from this comment would get it wrong. That is a doc-only consequence.

Fix: "for any caller the SDR guard admits (any authenticated user below ENFORCE_RULED; INBOUND_BOL holders at it)".

### [LOW] L4: the AC-4 and AC-10 422 assertions are status-only, so the cause of the 422 is unpinned
Confidence: HIGH
- `AdviceSetCommentContextTest.java:270-273`: `.isEqualTo(422);` (256-char comment)
- `AdviceSetCommentContextTest.java:361-364`: `.isEqualTo(422);` (missing id)

Any 422 passes either test. `RestExceptionHandler` emits 422 from at least five handlers (:60, :116, :154, :164, :182). `mutation-pr1.md` confirms that the context-test "kills" of m3 and m10 came from a servlet exception (`DataIntegrityViolation`, `InvalidDataAccessApiUsage`), not from these assertions. The attributable kills are the unit twins. Scenario: a future refactor moves validation to bean validation, or wraps the service so that some other 422 fires (for example a `BusinessException` → 422 path). The tests stay green even if the length check is gone, for as long as the other 422 comes first.

Fix: also assert the error body names the parameter. `ApiErrorMessage` carries the second constructor argument (`"comment"` / `"id"`), so assert it with an `.as("422 must come from the comment-length check")` message.

### [LOW] L5: the JSON-Patch 400 assertion is status-only and has no positive control
Confidence: MEDIUM
- `SdrPatchFieldFenceContextTest.java:197-201`: `.isEqualTo(400);`

Any 400 satisfies it: a malformed patch document, a content-type or converter change, a `HttpMessageNotReadableException` from an unrelated cause. Both the status and the unchanged field would then be green with the fence removed, as long as the request fails for another reason first. m5 was killed here only because the request was otherwise well-formed. Nothing in the test proves that.

Fix: add a positive control in the same class. A JSON-Patch `replace /comment` on the same advice returns 2xx and writes, which proves the patch document and media type are accepted. Optionally also assert the 400 body mentions `externalid`.

### [LOW] L6: lenient scalar coercion on `AdviceCommentRequest.id`
Confidence: LOW
- `AdviceCommentRequest.java`: `public record AdviceCommentRequest(Long id, String comment)`

Jackson's default `ACCEPT_FLOAT_AS_INT` (on) truncates `{"id": 87150.9}` to 87150, and scalar coercion accepts `{"id":"87150"}`. The endpoint is gated and its only planned caller sends a numeric id, so there is no realistic exploit. It is noted only because the review brief asked about id parsing.

Fix: none required. If wanted, mark the record component `@JsonFormat(shape = NUMBER_INT)`, or reject a non-integral `id` in the service.

### [LOW] L7: UTF-16 length differs from PostgreSQL's character count for astral characters
Confidence: HIGH
- `AdviceService.java`: `if (comment != null && comment.length() > ADVICE_COMMENT_MAX_LENGTH)`

`varchar(255)` counts characters (code points). `String.length()` counts UTF-16 units. A comment of 128–255 emoji fits the column but gets a 422. The failure is conservative (never a 500 or a truncation), and it matches the browser `maxlength="255"` that PR-W adds, which also counts UTF-16 units. But plan §5 A2's "(UTF-16 length, matching `varchar(255)`)" is not literally true.

Fix: keep the behaviour. Correct the plan wording, or the constant's javadoc, to say "UTF-16 units; conservative vs varchar's code-point count; matches the browser maxlength".

### [LOW] L8: small hygiene items in the service and the unit test
Confidence: HIGH
- `AdviceService.java` javadoc lists `@throws` 422 and 404, but not the 409 that plan §5 A2 relies on (`ObjectOptimisticLockingFailureException` on commit).
- `ADVICE_COMMENT_MAX_LENGTH` is declared mid-class, between two methods.
- `import net.aim_ai.wms.exceptions.ApiInvalidParameterException;` is placed after `BusinessException` (out of alphabetical order in an otherwise sorted block).
- `AdviceServiceUnitTest.java` `SetComment` uses inline FQNs (`java.util.Optional.of`, `net.aim_ai.wms.exceptions.ApiInvalidParameterException.class`) instead of imports.

Fix: add the `@throws` line for the 409, move the constant up to the other constants, and add the imports.

### [LOW] L9: TDD-time tense left in the context test javadoc
Confidence: HIGH
- `AdviceSetCommentContextTest.java:46-47`: `the handler, its DTO and {@code AdviceService.setComment} do not exist when this class is written (TDD gate)`

After 37cfa4ee they exist. The sentence explains why the test goes through HTTP, and that is still valid, but it now reads as a statement about the current tree.

Fix: change it to "did not exist when this class was written".

## Open questions (low-confidence, non-blocking)

None at CRITICAL/HIGH.

## Notes that are not defects (checked and cleared)
- **Fixture hygiene:** both new context tests seed through `TransactionTemplate` and delete by id in `@AfterEach`, inside `try/finally` with `SecurityContextHolder.clearContext()`. JUnit uses a fresh instance per test, so a stale `adviceId` cannot leak between tests. `clientId = 1L` meets the `advice.client_id` FK on the H2 seed (the tests are recorded passing).
- **H2 base vs commit semantics:** `BaseRollbackIntegrationTest` has no class-level transaction, so the request commits. `reload()` reads in a fresh transaction, so the AC-2 `version == seeded+1` and AC-2b `version unchanged` assertions are meaningful. Hibernate dirty checking is the same on H2 and PG.
- **AC-2 non-vacuity:** every posted extra (`externalid`, `clientId 999`, `type REGULAR`, `allowoverdelivery true`, `state OPEN`) differs from the seeded value (`EXT-…`, `1`, `RETURN`, `false`, `CLOSED`). The reflection-driven `declaredColumns` comparison also covers columns added later.
- **AC-6:** it asserts the ProblemDetail `title`/`detail`, so the 404 that a missing route returns cannot satisfy it.
- **AC-3:** it asserts `requiredFunction == WEB_UI_VIEW_INBOUND_BOL`, and the mode is pinned to OFF, so the 403 must come from `@RequiresFunction`.
- **AC-8:** "declared" uses `getField().getDeclaringClass()`, cross-checked against reflection, and a writable property with no field fails the test instead of being skipped. This matches plan §5 A1 exactly.
- **The response map:** it is `HashMap` with `NON_NULL`. A null comment returns `{"id":…}` only, which the plan intends. AC-5 correctly asserts the DB rather than the response.
- **The inherited `AbstractBaseEntity` fields:** `created`, `modified` and `version` stay SDR-bindable. That is the residual plan §5 A1 accepts until PR 2. It is not a finding.

## Positive observations
- The fence is stated and tested as an invariant built from runtime `PersistentEntities`, cross-checked against reflection, rather than as a hand list. A new column fails the build.
- The endpoint uses a typed record DTO, `Long` ids, real 422/404/409 statuses instead of the repo's 200-with-`errors` shape, and an entity save, so `@Version` and dirty checking apply. AC-2b pins the no-op re-save, which matters because the page re-saves on every open.
- Validation runs before the load, and the unit twins pin that with `verifyNoInteractions(adviceRepository)`.
- AC-7 sits where the plan requires (the real service with mocked collaborators), with an observable-effect HTTP twin added on top.
- Every new assertion carries an `.as(...)` that names the mutant it guards. 14/14 hand mutants were killed (`mutation-pr1.md`).
- The existing comments from SBDEV-3215 were annotated as superseded rather than silently left contradicting the new fence.

## Recommendation
**APPROVE.** There are no High or Medium findings. L1 (comment tense) and L4/L5 (attribution of the status-only assertions) are the ones worth fixing in the same pass, as repo policy requires fixing Low findings too.
