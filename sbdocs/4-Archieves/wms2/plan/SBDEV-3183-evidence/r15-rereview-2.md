---
title: SBDEV-3183 r15 — scoped re-review #2 (commit 758fb8a9, fixes R1–R4)
date: 2026-10-21
ticket: SBDEV-3183
kind: evidence (review lane, read-only)
worktree: .claude/worktrees/wms2-api/SBDEV-3183-r15
range: 758fb8a9 only
verdict: COMMENT (no blocking finding; 6 Low)
---

# SBDEV-3183 r15: re-review of 758fb8a9

**Verdict: COMMENT.** R1, R2, R3 and R4 are all fixed in substance. There are 6 new findings, all Low, and none of them blocks. I did not run Maven and did not edit the worktree. I took the author's results (55/0, 2/0, and three red mutants plus a whitespace control) as given.

## How I checked it
- `git show 758fb8a9` (4 files, +32/−21), read in full.
- I read `ReceivingDtoViewRepository.java` at 758fb8a9 in full.
- I ran `javap -v` on `org.springframework.data.jpa.repository.NativeQuery` from spring-data-jpa 3.5.7.
- I ran `git grep SdrRuleInventoryContextTest` over `src/` to find any remaining "pins it" claims.
- I measured javadoc line lengths with awk.
- I checked `pom.xml` for a checkstyle plugin. Checkstyle is only a dependency, so no line-length rule is enforced.
- I did not run lsp_diagnostics because the brief says no build. Compilation is covered by the author's targeted runs.

## 1. Is each of R1–R4 fixed?

| Prior | Fixed? | Evidence |
|---|---|---|
| R1 "pins it" false claim | **Yes** | `FunctionGuardInterceptor.java:95` and `RequiresFunction.java:61` now say "`SdrRuleInventoryContextTest` logs it (not asserted)". A grep finds no other "pins" claim about that test. The remaining mentions are still true: `SdrFunctionGuard:286` says "logs", `SdrRuleStartupAssertion:36` says "enumerates … on every CI run", and `SdrRuleStartupCheck:112` says "the CI-visible check" (it is visible, not a ratchet). |
| R2 `@NativeQuery` blind spot | **Yes for `@NativeQuery`; the named-query part is left open (N3)** | The test now uses `AnnotatedElementUtils.findMergedAnnotation(method, Query.class)`, the same lookup Spring Data's `JpaQueryMethod` uses. |
| R3 spy verify cannot tell stub from real | **Yes** | `stubbedParcelSaves` is incremented inside the `doAnswer` and asserted `isPositive()`. The author's mutant (increment removed) goes red with the named message. |
| R4 whitespace-coupled fragments | **Yes** | The check is now `query.value().trim().replaceAll("\\s+", " ")` with `startsWith("SELECT p FROM ReceivingDtoView p WHERE ")`. The `IS NULL` pins are gone. |

## 2. The specific questions

**Is the regex `"\\s+"` correct?** Yes. The Java literal `"\\s+"` is the regex `\s+`, so every run of ASCII whitespace becomes one space. That covers the double space at `ReceivingDtoViewRepository.java:24-25` (`"... p " + " WHERE"`) and the tab at the start of line 26.
- `trim()` runs before collapsing, so leading whitespace from a text block is handled too.
- The prefix keeps its trailing space, and the collapsed query continues `WHERE (CONCAT...`, so the match is exact.
- `\s` does not match NBSP or ` `. That is irrelevant for Java source queries.

**Does `startsWith` reject what it should?**
- `... ReceivingDtoView p JOIN x ...`: red.
- `... ReceivingDtoView p, Other o WHERE`: red.
- `FROM (SELECT ...) p WHERE` (a subselect in FROM, which HQL 6 supports): red, because the text after `FROM ` differs.
- `LEFT JOIN FETCH`: red.
- A whitespace-only reformat: green. The author's control confirms this.
- A reformat that is not whitespace-only goes red: lower-case keywords, `AS p`, or a renamed alias. These are false reds and they fail loudly. See N5.
- The prefix does **not** see subqueries or `EXISTS` over other entities placed after `WHERE`. See N4.

**Is it sound to drop the `IS NULL` pins?** Yes, but the javadoc gives the wrong reason (N2).
- `:keyword IS NULL`, `:keyword = ''`, `:clientNumber IS NULL` and `:clientNumber = ''` are filter-*bypass* disjuncts. Removing one makes the row set the same or smaller.
- The stronger reason it is safe: a caller who passes null or empty for both parameters already reaches every `ReceivingDtoView` row. So no WHERE edit to a `SELECT p FROM ReceivingDtoView p` query can widen reach past what the review already accepted.
- Removing a whole *conjunct*, such as the clientid filter, does widen the result for a caller who passes a non-null value. It still stays inside that already-reachable set.

**What does `findMergedAnnotation` return for `@NativeQuery`?** I checked with `javap -v` on 3.5.7:
- `NativeQuery` carries the class-level meta-annotation `@Query(nativeQuery=true)`.
- `value`, `countQuery`, `name` and the others are `@AliasFor(annotation=Query.class)`.
- `nativeQuery` is not aliased. It is fixed to `true` by the meta-annotation.

The merged `Query` therefore has `nativeQuery() == true` and the aliased `value()`. The consequences:
- **Printer/findByType (derived):** `@NativeQuery` gives a non-null merged `Query`, which goes red with "…now carries an @Query/@NativeQuery". This matches the author's mutant.
- **ReceivingDtoView/findByKeyword:** swapping in `@NativeQuery` gives a non-null merged `Query` that fails the `.nativeQuery()…isFalse()` assertion, with the correct message "became native". The `nativeQuery` check runs before the prefix check, so the misleading "lost the @Query" message R2 described is gone.

**Is the IT counter reset per test?** Yes, twice over:
- `stubbedParcelSaves.set(0)` runs in `@BeforeEach`.
- The class has no `@TestInstance(PER_CLASS)`, so JUnit creates a new instance, with a new field, for each test anyway. The reset is redundant but harmless.
- `@MockitoSpyBean` resets after each test, and `setUp` reinstalls the stub.

**Javadoc and comment accuracy:** the text is accurate, with the exceptions noted in N1, N2, N4 and N6.

## 3. Findings (all Low)

### [Low] N1. The R1 edit over-runs the javadoc wrap: 140 and 124 columns
Confidence: HIGH.
- `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:95` is 140 characters:
  ` * ruled/unruled split at boot and {@code SdrRuleInventoryContextTest} logs it (not asserted). The other exported types are <em>allowed</em>`
- `src/main/java/net/aim_ai/wms/security/RequiresFunction.java:61` is 124 characters, and it is followed by an orphan line, ` * when the tenant's`.

The surrounding lines wrap at about 110 to 115. No checkstyle plugin enforces this, so nothing goes red.
**Fix:** reflow both paragraphs to the file's existing width.

### [Low] N2. The javadoc calls the `IS NULL` arms "narrowing arms" and gives a weaker reason than the real one
Confidence: MEDIUM.

`SdrFunctionRulesUnitTest.java`, `ReviewedOverride` javadoc:
> "The narrowing arms are not pinned: removing one can only narrow what a holder reads, never widen it."

The `:x IS NULL` and `:x = ''` arms are *bypass* disjuncts. They switch a filter off, so calling them "narrowing" inverts what they do. The statement is true of those disjuncts, but not of removing a whole conjunct such as `AND (p.clientid = :clientNumber OR …)`, which widens the result for a non-null caller. The pin is sound for a reason the javadoc does not state: with null parameters the reviewed query already returns every `ReceivingDtoView` row, so any WHERE edit stays within the accepted reach.

**Fix:** replace that sentence with: "The WHERE clause is not pinned: with null/empty parameters the reviewed query already returns every ReceivingDtoView row, so with the entity and return type pinned, no WHERE edit can widen reach past what was reviewed."

### [Low] N3. R2's named-query route is neither closed nor disclosed
Confidence: MEDIUM.

R2 had a second route: a JPA named query `Printer.findByType`, from `@NamedQuery`/`@NamedNativeQuery` on the entity or from `META-INF/jpa-named-queries.properties`. It takes precedence over derivation with no annotation on the method. The commit closes only the annotation route. The javadoc now says a derived entry "must carry no `@Query` (nor `@NativeQuery` …)", which is true but implies the derived-query shape is fully pinned. Today neither source exists in `src/main`, so this is latent.

**Fix (either):**
- Add a line to the javadoc: "A named query `<Entity>.<method>` would also replace derivation and is not checked."
- Or, for `queryPrefix == null` entries, assert two things:
  - the domain class has no `@NamedQuery`/`@NamedNativeQuery` with that name, for example via `AnnotatedElementUtils.findMergedRepeatableAnnotations(Printer.class, NamedQuery.class)` and the native equivalent;
  - `getClass().getClassLoader().getResource("META-INF/jpa-named-queries.properties")` is null.

### [Low] N4. "a JOIN or a second entity is red" holds only in FROM
Confidence: LOW.

The prefix fixes the FROM clause. It does not fix the rest. `... p WHERE EXISTS (SELECT u FROM OtherEntity u WHERE u.secret LIKE :keyword)` stays green. That still returns only `ReceivingDtoView` rows, but the row count and existence become a boolean oracle over `OtherEntity`, driven by the caller-controlled `:keyword`. A developer would have to write it, and the threat is narrow.
- **Javadoc fix:** say "a JOIN or a second entity *in FROM* is red; subqueries in WHERE are not checked".
- **Optional assertion:** after the prefix, the collapsed query contains no second `FROM`: `assertThat(q.substring(prefix.length())).doesNotContainIgnoringCase(" FROM ")`. Today the remainder has no `FROM`; I checked the literal.

### [Low] N5. Reformats that are not whitespace-only go red even though they change nothing
Confidence: MEDIUM.

Lower-casing keywords (`select p from … where`), adding `AS` (`ReceivingDtoView AS p`), or renaming the alias all fail `startsWith`, although they change nothing. The failure is loud and the message names the prefix, so the cost is one re-pin. The javadoc says only that whitespace is tolerated, so it does not claim otherwise.
**Fix (optional):** compare case-insensitively with `.as(...).startsWithIgnoringCase(...)`, and/or add one sentence to the javadoc: "Keyword case, `AS`, or a renamed alias also go red; re-pin after checking."

### [Low] N6. The IT counter wording, and style, in CustomerorderForceCancelOutboxIntegrationTest
Confidence: MEDIUM.
1. **The message describes a failure that never reaches it.** `:190` `.as("control: … (spy stub missing => real save on H2)")`. By the author's own finding, a *missing* stub makes the real `save` throw `DataIntegrityViolationException` on the detached id-900 Unitload before this assertion runs. So this message never fires for that case. What the counter actually catches is the stub being present but not matching or not running: for example `any(OtherType.class)`, a `doCallRealMethod()`, or the answer body changed. The `:186-187` comment ("verify() alone records real calls too, so the counter is what proves the stub ran") is accurate.
   **Fix:** change the message to "…(stub not matched or not run => real save)".
2. **Fully-qualified names instead of imports.** `:113` declares `private final java.util.concurrent.atomic.AtomicInteger stubbedParcelSaves = new java.util.concurrent.atomic.AtomicInteger();` (129 columns), while the file already has an import block (`:3-45`). The same pattern appears in `SdrFunctionRulesUnitTest` for `org.springframework.core.annotation.AnnotatedElementUtils` and `org.springframework.data.jpa.repository.Query`, although that file already used FQNs nearby.
   **Fix:** add `import java.util.concurrent.atomic.AtomicInteger;`.
3. **A redundant reset (nit).** The `set(0)` in `@BeforeEach` is redundant under JUnit's default per-method lifecycle. Keep it, since it is harmless and robust to a future `PER_CLASS`, or drop it. No action needed.

## Open questions
None.

## Positive observations
- The R2 fix uses the same merged lookup as Spring Data's `JpaQueryMethod` and as the file's own `isExported`, so the helpers now agree. One change also fixes the misleading message on a native swap of `findByKeyword`.
- The prefix check is both looser, because whitespace no longer matters, and stricter, because it anchors at the start instead of using `contains`. It also covers subselect-in-FROM, which the old fragment-anywhere check did not.
- The R3 counter is a direct proof. The author also ran the experiment R3 assumed and recorded that its premise was wrong (a missing stub already reds). That is good discipline.
- R1 was fixed in both homes with the same wording, and no new count was introduced.

## Recommendation
**COMMENT.** Nothing blocks. Under the fix-every-Low rule:
- **One-line changes:** N1 (reflow), N2 (one sentence), N6.1 (message) and N6.2 (import).
- **One line or about 5 lines:** N3, either a javadoc line or two assertions.
- **Optional:** N4 and N5.
