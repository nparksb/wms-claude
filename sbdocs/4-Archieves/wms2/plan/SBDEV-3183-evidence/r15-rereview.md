---
title: SBDEV-3183 r15 — scoped re-review of the review-fix round
date: 2026-10-21
ticket: SBDEV-3183
kind: evidence (review lane, read-only)
worktree: .claude/worktrees/wms2-api/SBDEV-3183-r15
range: 38a1c1ac..f91548a3 (5d4ebac5, 8d78c58a, 29814e05, a26f926f, 08212401, f91548a3)
verdict: COMMENT (no blocking finding)
---

# SBDEV-3183 r15: re-review of the review-fix round

**Verdict: COMMENT.** There are 4 findings, all Low: 3 at HIGH confidence and 1 at MEDIUM. None is High or Medium. Every prior finding in scope is fixed in substance, not just reworded. Two of the fixes have a residual gap (R2 and R3), and one fix introduced a new false claim (R1).

I did not run Maven and did not edit the worktree.

## How I checked it
- **Diff.** I read `git diff 38a1c1ac..HEAD` in full: 9 files, +130/−34.
- **Repositories under the pins.** I read `ReceivingDtoViewRepository.java` and `PrinterRepository.java` in full, because the F3 pins assert against them.
- **Merged-annotation check.** I read `NativeQuery.class` from spring-data-jpa 3.5.7 (`~/.m2`, the version Boot 3.5.9 manages). Its constant pool references `org/springframework/data/jpa/repository/Query`, `AliasFor` and `nativeQuery`, so it is a composed `@Query(nativeQuery = true)`.
- **Pickingorder callers.** I re-swept them myself after a fresh `git fetch`. The commands and refs are in §3.
- **DB grant.** I checked it on the `wms2-wineco-dev` MCP, which is DB dev_wh01_om1.
- **lsp_diagnostics was not run.** Compilation of these classes is covered by the implementer's targeted 144/0/0/0 run at f91548a3, and the brief forbids mvn here.

## 1. Was each prior finding actually fixed?

| Prior | Fixed? | Evidence |
|---|---|---|
| Code F1 (Medium) | **Yes** | `SdrMustStayOpenRailUnitTest` javadoc now says "Since SBDEV-3183 r15 `Printer` IS ruled … a deployment whose OMS env sets that variable to the v3 SDR path is denied once its tenant enforces … check the PRD OMS env before any PRD tenant leaves OFF/SHADOW". This matches `SdrFunctionRules.productionOverrides()`. |
| Code F2 | **Yes, with a new false clause (R1)** | All four stale counts are gone: FunctionGuardInterceptor "five rules remain", RequiresFunction "27 as of SBDEV-3471", SdrGuardMode (now marked as dated history), and SdrRuleStartupCheckUnitTest "30 of 35". |
| Code F3 / Sec L5 | **Yes, with a gap (R2)** | `ReviewedOverride(parameters, genericReturnType, queryArms)` adds three pins: the generic return type, JPQL rather than native, and the entity followed directly by WHERE. M1–M7 kill each of them. |
| Code F4 | **Yes** | Each fallback row must now resolve to exactly one exported search on `OVERRIDE_REPOSITORIES`, and it does so before the fallback assertion runs. M8 (misspelled row) and M9 (`exported = false`) kill it. I checked all 4 rows by hand against the repositories: `findByTypeAndProcessdefaultTrue`, `findAllTypeAndProcessdefaultTrue`, `findByAdvicenumber` and `findByAdvicepositionid` each resolve exactly once. |
| Code F5 (Nam: rule it) | **Yes** | `rules.put(Pickingorder.class, PICKING_ORDER_VIEW)` is pinned in `sbdev3183NeedsGatingRules`, which also feeds the full-set test, and M11 kills it. The Row-5 comment and the boot line agree that 8 types are unruled and that they are exactly the 8 rail types. |
| Code F6 | **Yes, with a gap (R3)** | The report now records the commits and the IT result. The new `verify(...save(argThat(...)))` is attributable (M10 kills it), but it proves less than its comment claims. |
| Code F7 / Sec L1 (Nam: accept) | **Yes** | The acceptance is recorded in both homes: the rule comment and the `REVIEWED_OVERRIDE_PARAMETERS` javadoc. The override is unchanged, as decided. |
| Sec L4 | **Yes** | There is a note on the UnitloadType rule and in the sweep doc §14 (line 308). I re-checked that it is dead: `git grep` on web-ui origin/develop `add0628` finds no `dispatch`/`mapActions` of `receiving/createPo/getUnitLoadTypes`. The only dispatch is `masterData/unitLoadType/getUnitLoadTypes` (`unitLoadType.vue:243`). |

## 2. Are the new assertions non-vacuous, and is the @Query fragment matching too brittle or too weak?

**They are non-vacuous and fail attributably.** I reasoned through each mutant M1–M11 in the report against the code:
- Each one fails a named `.as(...)` that names the override or row.
- The messages send the editor back to the recorded review.
- The fallback anchor also changes M8/M9 from a silent green into a named red.

**Brittle or weak?** Both, a little. The stated threat is a JOIN, a native query or a wider projection. The load-bearing pins against it are these three:
- the return type `Page<ReceivingDtoView>`
- `nativeQuery == false`
- the prefix `SELECT p FROM ReceivingDtoView p  WHERE `

With the return type pinned, a JPQL query that selects `p` from that one entity can only ever return ReceivingDtoView rows. A WHERE clause can only filter them.

- **Too weak in one place.** The derived-query check for Printer cannot see `@NativeQuery` or a named query. See **R2**. This is the one real gap.
- **Slightly brittle.**
  - The prefix depends on a double space that comes from string concatenation (`"... p " + " WHERE"`). The report already discloses this as a false-red.
  - The `:keyword IS NULL` and `:clientNumber IS NULL` arms pin predicates whose removal can only narrow the result or leave it the same. For example, `COALESCE(:keyword,'')` already makes a null keyword match every row. So these two pins can only ever false-red. They record the review's reasoning rather than guard data reach.
  - See **R4**. Acceptable as is.

## 3. Pickingorder: independent caller re-sweep and grant

I ran `git fetch` first. The SDR path is `@RepositoryRestResource(path = "pickingorder")`, and its exported searches are `findByNumber` and `findByStateAndSectionId`. I ran two greps:
- **Token grep, case-sensitive:** `git grep -nIE '(^|[^A-Za-z_])pickingorder([^A-Za-z_]|$)'`.
- **String-built and multi-line grep, case-insensitive:** `['"`/]picking['"`]?\s*\+`, `pickingorders?['"`/?]`, `findByStateAndSectionId`, `search/findByNumber` and `v3/picking`. This catches a path split across lines or built by concatenation.

| Repo @ ref | Result |
|---|---|
| wms2-web-ui origin/develop `add0628` | Only Cypress: `cypress/e2e/wms/smoke/phase2-pick.cy.js:97` `const p = '/pickingorder/search/findByNumber?number=' + encodeURIComponent(pickingNumber);`. Every other hit is the MVC `/picking/pickingOrders/{zone}` (Cypress `pick-pack-order.cy.js`, `wmsHelpers.js:320`). |
| wms2-mobile-ui origin/develop `f51dc6c` | No SDR hit. The only hit is the MVC path `store/picking.js:453` `` `/picking/pickingOrders/${data.value}` `` and its Playwright mocks. |
| oms-laravel-api origin/develop `26a301ac` | No app or config hit (`config/wms.php` included). Only `docs/releases/owl-v2.0.144/*` (release notes) and `docs/plans`/`docs/analysis` prose. |
| siteboss-frontend origin/main `5ae96922` | No hit. |

This agrees with the implementer's sweep: **only the Cypress smoke suite reads it.**

**Grant on dev.** I ran `mywms_function ⋈ mywms_role_mywms_function ⋈ mywms_role` on `wms2-wineco-dev`. `WEB_UI_VIEW_PICKING_ORDER` (id 51743) is granted to **CS-REP, outbound-manager and super-admin**, so the rule names a function that real users can hold. I did not check whether the Cypress test user's role holds it. The rule comment already flags that as a pre-enforce step.

## 4. Stale literals
I ran `grep -rnE "26 ruled|9 unruled|plus Pickingorder|Cypress-only|five rules remain|30 of 35|26 rules|other 9|27 as of" src/`. Every hit is legitimate:
- `SdrFunctionGuard.java:284` "35 - 26 = 9 unruled (measured 2026-10-20 …). Pickingorder ruled (Nam 2026-10-21): 35 - 27 = 8 unruled". This is dated arithmetic history, correctly continued.
- `SdrFunctionRulesUnitTest.java:106` "plus Pickingorder (Cypress-only reader, ruled by Nam's decision 2026-10-21 …)". This is accurate: it describes the reader, and says the type is ruled.
- Three unrelated "the other 9" hits in `ReplenishmentStaleVersionAtLockReadIntegrationTest`, `Sbdev3017TrancheGateContextTest` and `MethodSecurityEnablementContractTest`, which belong to other subjects.

**Other prose that mentions Pickingorder** is still true after it was ruled:
- `ReportPaginationSearchWithdrawalContextTest:69-76` says no app code calls it.
- `SdrUncalledSurfaceNotExportedContextTest:73-76` says it is deliberately not withdrawn.

## 5. Findings (all Low)

### [Low] R1. New false claim: "SdrRuleInventoryContextTest pins it"
Confidence: HIGH. Introduced by the F2 fix in 5d4ebac5. This is a textbook case of a fix to a false claim producing a new one.

The new text, in two places:
- `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:94-95`: "`SdrRuleStartupCheck` logs the live ruled/unruled split at boot and {@code SdrRuleInventoryContextTest} **pins it**."
- `src/main/java/net/aim_ai/wms/security/RequiresFunction.java:60-61`: "… at boot and {@code SdrRuleInventoryContextTest} **pins it**; every other exported type is untouched …"

The test says the opposite. `SdrRuleInventoryContextTest.enumeratesUnruledExportedTypes` has the display name "enumerates the exported types with NO rule — the Slice 4 backlog, **logged not asserted**", and its body says "Deliberately NOT a ratchet on the count". It asserts only `ruled` non-empty and `unruled` non-empty. `SdrFunctionGuard.java:286` already uses the correct verb: "SdrRuleInventoryContextTest **logs** all three figures".

A reader who trusts "pins it" will expect a red on drift that never comes.

**Fix:** in both places, replace "pins it" with "logs it at test time (deliberately not a count ratchet)". The exact ruled set is what is actually pinned, by `SdrFunctionRulesUnitTest.ruledDomainTypesMatchesTheFullRuleSet`, so that test is the better pointer if one is wanted.

### [Low] R2. The derived-query pin for Printer/findByType cannot see `@NativeQuery` or a named query
Confidence: HIGH for `@NativeQuery`, MEDIUM for the named-query route.

`src/test/java/net/aim_ai/wms/unit/security/SdrFunctionRulesUnitTest.java` (`assertReviewedShape`):
```java
org.springframework.data.jpa.repository.Query query =
        method.getAnnotation(org.springframework.data.jpa.repository.Query.class);
if (reviewed.queryArms() == null) {
    assertThat(query) ... .isNull();
```

`Method.getAnnotation` sees only a directly present `@Query`. spring-data-jpa 3.5.7 ships `@NativeQuery`, which is meta-annotated `@Query(nativeQuery = true)` with `@AliasFor`; I verified this in the jar's constant pool. So this edit leaves the test green:
```java
@NativeQuery("select p.* from printer p join ... ")
List<Printer> findByType(String type)
```
That edit is exactly the native and joined shape that Sec L5 asked to pin. The return type stays `List<Printer>`, but a native query can alias any column into a Printer field.

The same file's `isExported` helper already uses `AnnotatedElementUtils.findMergedAnnotation` ("Merged-annotation lookup so a …"), so the two helpers are inconsistent. Mutant M6 used a plain `@Query`, so this route was never exercised.

There is a second, less likely route. A named query `Printer.findByType` would take precedence over derivation with no annotation on the method at all. It could come from `@NamedQuery`/`@NamedNativeQuery` on the entity, or from `META-INF/jpa-named-queries.properties`. Neither exists in `src/main` today.

On ReceivingDtoView, a swap to `@NativeQuery` *does* go red, but with the misleading message "lost the @Query".

**Fix:**
```java
var query = org.springframework.core.annotation.AnnotatedElementUtils
        .findMergedAnnotation(method, org.springframework.data.jpa.repository.Query.class);
```
The `nativeQuery()` check then also catches `@NativeQuery` on ReceivingDtoView, with the right message. Optionally, for derived entries, also assert two things:
- the entity carries no `@NamedQuery`/`@NamedNativeQuery` named `<Entity>.<method>`
- no `META-INF/jpa-named-queries.properties` resource exists on the classpath

Add a mutant M6' (`@NativeQuery` on findByType) to the report.

### [Low] R3. The IT's spy verify cannot tell the stubbed save from a real save, so its comment overclaims
Confidence: HIGH.

`src/test/java/net/aim_ai/wms/integration/CustomerorderForceCancelOutboxIntegrationTest.java:180-182`:
```java
// Control for the spy: the parcel went through the STUBBED findById/save, so the real H2-backed
// UnitloadRepository was not what this test exercised.
verify(unitloadRepository).save(argThat((Unitload u) -> u != null && Long.valueOf(PARCEL_ID).equals(u.getId())));
```

A spy records every invocation, stubbed or real. Two cases show the gap:
- **The findById stub is proven, indirectly.** Delete the `doReturn(...).findById(anyLong())` stub at `:138` and the real findById returns empty, so save is never called and the verify goes red. Good.
- **The save stub is not proven.** Delete the `doAnswer(...).save(any(Unitload.class))` stub at `:139` and the real `SimpleJpaRepository.save` runs a merge against H2. The verify still passes, because save was called with id 900.

So the verify proves the parcel reached save. It does not prove that "the real H2-backed repository was not exercised". M10 (fixture id + 1) is killed through the argument matcher, not through stub-versus-real.

**Fix (either):**
- **Make it prove the stub ran.** Use `AtomicBoolean stubbedSave = new AtomicBoolean(); doAnswer(inv -> { stubbedSave.set(true); return inv.getArgument(0); })...` and then `assertThat(stubbedSave).as("save went through the stub, not H2").isTrue()`.
- **Or narrow the comment** to "the parcel reached save via the stubbed findById".

### [Low] R4. The @Query fragment pins are whitespace-coupled and include two that can only false-red
Confidence: MEDIUM.

`SdrFunctionRulesUnitTest.java`, the `REVIEWED_OVERRIDE_PARAMETERS` ReceivingDtoView entry:
```java
List.of("SELECT p FROM ReceivingDtoView p  WHERE ", ":keyword IS NULL", ":clientNumber IS NULL")
```

There are three problems:
- **Whitespace coupling.** The double space before `WHERE` is an artifact of `"SELECT p FROM ReceivingDtoView p " + " WHERE ..."` (`ReceivingDtoViewRepository.java:24-25`). Joining the strings or reformatting the query turns it red with "no longer contains", and nothing changed semantically. The report discloses this.
- **Arms that only false-red.** Dropping either arm can only narrow the result or leave it the same. For example, `COALESCE(:keyword,'')` already makes a null keyword match every row. Neither drop can widen what a holder reaches, so these two pins can never catch the widening the review is about.
- **`contains`, not `startsWith`.** The prefix is matched anywhere in the string, not anchored at the start. The pinned return type limits the practical risk.

**Fix (optional):**
- Normalise before matching: `String q = query.value().replaceAll("\\s+", " ").trim();`.
- Then assert `startsWith("SELECT p FROM ReceivingDtoView p WHERE ")`.
- Keep the arm fragments only if the intent is "re-read the review on any semantic edit", and say so in the `ReviewedOverride` javadoc.

## Observations (not findings)
- **Row-5 counts in `SdrFunctionGuard`.** The Row-5 comment still states counts: 27 rules, other 8. F2's approach elsewhere is to keep no count. Here it is the designated arithmetic line, dated and carrying a "re-derive" warning, and the boot line agrees (27 ruled, 8 unruled, the 8 rail types). Acceptable.
- **No full-suite run yet for the fix round.** The implementation report says so ("The review fix round commits … have NOT had a full-suite run yet"). That run is in progress in the worktree now. This review does not substitute for it.

## Positive observations
- `exportedSearches()` is extracted and shared, so the override check and the fallback anchor cannot diverge in what counts as a search.
- The failure messages name the override and the action, e.g. "re-review what a holder can reach before updating the entry". The anchor message lists the three ways a row goes stale.
- The Pickingorder rule was preceded by a recorded multi-repo sweep at pinned SHAs. My independent re-sweep reproduced it exactly.
- The rail note now carries the PRD OMS env check as an explicit pre-enforce gate, instead of a stale "ninth entry" claim.
- The L4 dead caller is recorded in both homes (code and sweep doc) with the exact remedy.

## Recommendation
**COMMENT.** No High or Medium finding, and nothing blocks. Under the repo's fix-every-Low rule, R1 and R2 are each a one-line change. R3 is a three-line change or a comment narrowing. R4 is optional.
