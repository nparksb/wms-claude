---
title: SBDEV-3183 AC-2 - post-merge review of fd43e407 (re-review 2 F1, F2)
date: 2026-10-18
lane: code-reviewer (read-only; no Maven run, per brief; all reads via git show at fd43e407 / c9cd078d)
commit: fd43e407 (merged to develop via PR #529, merge c9cd078d; is-ancestor of origin/develop confirmed)
verdict: APPROVE (both findings fixed; three Low notes, none blocking)
---

# Post-merge review of fd43e407

Scope: `src/test/java/net/aim_ai/wms/unit/security/SdrFunctionRulesUnitTest.java`
`everyOverriddenSearchTakesNoParameters` (:211-249 at c9cd078d) plus new helper `isExported` (:251-255).
Context read: `LocationRepository` (c9cd078d), `SdrRuleStartupAssertion.findUnresolvableOverrides` (:73-96),
`SdrRuleStartupCheck.afterSingletonsInstantiated` (:82-105), `SdrFunctionRules.productionOverrides` (:378-392),
`RestConfiguration` (no `disableDefaultExposure` / `exposeRepositoryMethodsByDefault` override anywhere in src/main).
Nothing compiled or executed; red/green statements are by reading.

## 1. Disposition

| ID | Disposition | Evidence |
|---|---|---|
| F1 (match could pair a key with a non-exported / CRUD method) | FIXED for the non-exported case; CRUD-base residual remains (N1 below) | :231 now filters `!isBridge && !isSynthetic && !isDefault && isExported(m)`. An `exported=false` overload sharing the path (pattern exists: `getAvailableStagingLanes` :110, `getAvailableTransferLanes` :132) is now dropped, so it can no longer inflate the match count or be the matched method. Both production targets survive the filter: `findByGateTrue` (:98-99) and `getAllCrossDockingLanes` (:176-178) carry `@RestResource(path=<own name>, rel=...)` with default `exported=true`, zero parameters. |
| F2 (stale `OVERRIDE_REPOSITORIES` entry never flagged) | FIXED | :245-248 asserts `OVERRIDE_REPOSITORIES.keySet()` `containsExactlyInAnyOrderElementsOf` distinct `domainType`s of `overrideKeys()`. A type mapped to a repository but carrying zero keys is in the left set and absent from the right, so AssertJ reports it as "unexpected" under the description "names a type that no longer carries an override; remove the entry" - attributable. The reverse direction (override type missing from the map) is unreachable here because the loop's `isNotNull` (:226-229) fails first with its own named message. The commit-message kill claim (adding an Advice entry reds it) holds by reading: keySet {Location, Advice} vs [Location]. |

## 2. Can the test now pass for the wrong reason?

**Does `isExported` mirror SDR 4.5.x?** For the method-level case, yes in direction. SDR's
`RepositoryMethodResourceMapping` sets exported = `annotation != null ? annotation.exported() : exposeMethodsByDefault`,
where the annotation is resolved with merged-annotation semantics. This repo never disables default method
exposure (no `disableDefaultExposure`/`setExposeRepositoryMethodsByDefault` in src/main), so "no annotation => exported"
is correct here. Differences: (a) `getAnnotation` is direct-only vs SDR's merged lookup (meta-annotations /
inherited declarations) - not hit by any current method; (b) the helper hard-codes the default rather than reading
the config - would silently diverge only if someone later calls `disableDefaultExposure()` (N2).
**Interface/repository-level `exported=false`**: not modelled by the test, but not needed - a repository-level
`@RepositoryRestResource(exported=false)` makes the type unexported, and `findUnresolvableOverrides` (:76-80)
adds "(domain type not exported)", which `SdrRuleStartupCheck` (:99-105) turns into an unconditional
`IllegalStateException` at boot (not mode-gated). The test would still find the method and pass; the boot check is
the instrument for that axis, which is the correct split.

**Filter hiding the target.** If someone marks `findByGateTrue` `exported=false`: the filter removes it, `matches`
is empty, and `hasSize(1)` (:234-237) fails - red, not vacuous. The message "Location/search/findByGateTrue must
resolve to exactly one repository method" plus AssertJ's "Expected size: 1 but was: 0" does not say *why*
(un-exported vs renamed vs path changed) - mildly unattributable (N3). Independently, boot refuses:
`searches.getExportedMethodMappingForPath("findByGateTrue")` returns null for a non-exported mapping, so
`findUnresolvableOverrides` (:90-93) reports "(no exported search at that path)" and `SdrRuleStartupCheck` throws.
Confirmed: two independent reds, no vacuous pass.

**Vacuity.** Unchanged and adequate: `overrideKeys()` non-empty (:223), named repository lookup, `hasSize(1)` per key.

**Residual wrong-reason shape (from re-review 2, still open).** The filter does not exclude methods declared on
`CrudRepository`/`Repository` (`findAll()`, `count()` are public, non-default, unannotated => `isExported` true).
An override key literally named `findAll` or `count` would match a zero-parameter base method and pass here. SDR
does not export base CRUD methods as searches, so boot refuses such a key (:90-93). Pair of checks remains sound;
this test alone does not - same as before, and the commit message's "matching what SDR can serve" overstates it (N1).
Also `getMethods()` returns public static interface methods, which the filter does not exclude; none exist on
`LocationRepository`.

## 3. False claims

- Commit message F1 bullet: "ignores bridge, synthetic, default and non-exported methods, matching what SDR can
  serve". The first half is true; "matching what SDR can serve" is an overclaim - SDR serves only
  `RepositoryInformation.getQueryMethods()` (excludes base-class CRUD and static methods) with merged-annotation
  resolution. Low; commit messages are not code, but it is the kind of sentence later reviewers quote (N1).
- Test comment :219-222 ("@RestResource(path), else the method name, which is SDR's default") - true; it does not
  mention the new export filter, but states nothing false.
- F2 assertion description - true and specific.

## 4. New findings

| ID | Severity | Confidence | File | Evidence | Fix |
|---|---|---|---|---|---|
| N1 | Low | HIGH | `SdrFunctionRulesUnitTest.java:231`; commit msg fd43e407 | Filter keeps `CrudRepository` base methods and static methods; a key named `findAll`/`count` would pass here for the wrong reason (boot check still refuses). Commit message says "matching what SDR can serve". | Add `m.getDeclaringClass() == repository` (or `!Modifier.isStatic(m.getModifiers()) && !m.getDeclaringClass().getPackageName().startsWith("org.springframework.data")`); or soften the claim in the comment. |
| N2 | Low | MEDIUM | `SdrFunctionRulesUnitTest.java:251-255` | `isExported` hard-codes "unannotated => exported" and uses direct `getAnnotation`; SDR reads `exposeMethodsByDefault` and uses merged lookup. Correct for today's config and methods only. | Use `AnnotatedElementUtils.findMergedAnnotation`, and a one-line comment that it assumes default method exposure (RestConfiguration does not disable it). |
| N3 | Low | HIGH | `SdrFunctionRulesUnitTest.java:234-237` | When the target is filtered out (e.g. marked `exported=false`), the failure reads "must resolve to exactly one repository method / size 0" with no hint the method exists but is un-exported. | Include candidate names in the description, e.g. list unfiltered `getMethods()` whose `searchPathOf` equals the key, or add "(non-exported methods are ignored)". |

No CRITICAL/HIGH/MEDIUM finding. No production code touched by the commit.

## 5. Positive observations
- F2 closes the map in both directions with one assertion plus the existing `isNotNull`, each with its own message.
- Filtering un-exported overloads makes `hasSize(1)` mean "SDR has exactly one candidate", which is what the pin needs.
- Defence in depth is real: every wrong-reason shape left in this test is independently caught by
  `SdrRuleStartupCheck`, which throws unconditionally.

## 6. Verdict
**APPROVE.** F1 and F2 are fixed. The test cannot pass vacuously; the remaining wrong-reason shape (key named after a
CRUD base method) is fenced by the boot check. N1-N3 are optional Low hardening; per house rule (fix Low findings too)
they would go on SBDEV-3183 unless it is already `on dev` or later, in which case propose rather than add scope.
