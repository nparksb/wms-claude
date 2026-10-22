---
title: SBDEV-3183 AC-2 rules - scoped re-review 2 of commit 8a06f2f1 (N1, N2, I1, I2)
date: 2026-10-18
lane: code-reviewer (read-only; no Maven/javap run, per brief)
worktree: rv-3183-ac2 (detached at 8a06f2f1)
verdict: APPROVE (no High/Medium; three Low/Info test-hardening notes, none blocking)
---

# Re-review 2 of 8a06f2f1

Method: `git show 8a06f2f1`, reads of `LocationRepository`, `SdrFunctionRules`, `SdrRuleStartupAssertion`,
the Advice/Cyclecount/Location entities, `AbstractBaseEntity`, and a grep of every `model/` class for JPA
association annotations. Nothing compiled or executed; red/green statements are by reading.

## 1. Disposition

| ID | Disposition | Evidence |
|---|---|---|
| N1 ("below" -> "above") | FIXED | `SdrFunctionRulesUnitTest` comment now says "tests above"; the pair (`locationGateSearchRequiresViewBillOfLading` ~:197, `locationCrossDockSearchRequiresViewInboundBol` ~:227 before the commit) are earlier in the file than the `searchOverrideWinsOverTheTypeRule` comment, and the new test sits between them and it, so "above" is true. The comment still also names SdrRuleStartupAssertionUnitTest, whose `productionOverridesAreExactlyTheLocationPair` exists (:204). |
| N2 (fixture says three, is four) | FIXED | `SdrFunctionGuardUnitTest.fakeMappings()` javadoc now says four: two Slice 1 types, `itemdata` unruled, `location`. Accurate against the fixture (UserGroup, UserRole, Itemdata, Location). Prose is slightly looser than my suggested wording (does not say Location is ruled) but states nothing false. |
| I1 (no-param pin keyed on names) | FIXED, with residual notes F1-F3 | See section 2. |
| I2 (Slice 1 phrasing) | FIXED, one claim verified, one qualified | See section 3. |

## 2. I1: does `searchPathOf` resolve like SDR 4.5.x?

Resolution rule: `@RestResource(path)` if non-empty, else the method name. This matches SDR's
`MethodResourceMapping` (annotation path, else `method.getName()`); I could not decompile the 4.5.7 jar here
(no javap), so confidence is MEDIUM-HIGH from knowledge of the SDR source, not from reading it. Every method
the two overrides touch declares an explicit `path` equal to its name (`LocationRepository.java:98-99`, `:176-178`),
so the rule resolves correctly for the production keys regardless.

Wrong-reason matches, checked:
- Supertype/bridge/default methods: `getMethods()` on `LocationRepository` also returns the `CrudRepository`/
  `Repository` methods (`save`, `findById`, `findAll`, `delete`...), whose "search path" would be their method
  name. They can only match an override key literally named like a CRUD method. Neither production key is.
  Were one added, the match would be a 1-parameter CRUD method, i.e. a red, not a silent green. A zero-parameter
  CRUD method (`findAll()`, `count()`) with an override key of that name would pass for the wrong reason, but SDR
  does not export base-class methods as searches, and `SdrRuleStartupAssertion.findUnresolvableOverrides`
  (`getExportedMethodMappingForPath`) refuses boot for such a key. So the pair of checks is sound; this test
  alone is not.
- Non-exported overload: the filter ignores `exported=false`. An unexported method sharing the path (existing
  pattern: `getAvailableStagingLanes` has `path` plus `exported=false`) would be counted. Direction is safe
  (two matches -> `hasSize(1)` reds), but the failure message would blame the wrong thing.
- Overloads under one name produce two matches -> red. Same-path/different-name re-pointing is resolved correctly
  because matching is by path, not name. This is the I1 defect and it is closed.
- `getAnnotation` is direct-only while SDR uses merged/find semantics. For methods declared on
  `LocationRepository` itself these agree. Only matters if a future override targets an inherited or
  meta-annotated method.

Vacuity guard: adequate. `overrideKeys()` non-empty, repository present in `OVERRIDE_REPOSITORIES` (named
failure), and `hasSize(1)` per key (zero matches cannot pass). All three asserts are inside/ahead of the loop, so
an empty iteration is the only silent-pass shape and the first assert excludes it. Loop uses AssertJ (no
soft-assertion), so the first failing key stops the run; fine for a two-key set.

## 3. I2: comment truth

- "Advice, Cyclecount, Location have no JPA associations": TRUE. `Advice.java`, `Cyclecount.java`,
  `Location.java` declare no `@OneToMany/@ManyToOne/@OneToOne/@ManyToMany/@ElementCollection/@Embedded`; their
  non-id fields are scalars (`Long` FK ids such as `areaId`, `clientId`), and `AbstractBaseEntity` adds only
  id/created/modified/version. The only `model/` classes carrying association annotations are the user-admin
  types (User, UserGroup, UserRole, UserGroupUser, UserUserRole, UserRoleUserFunction, UserGroupUserRole,
  ShippingmethodShipperid and their id classes); none references Advice, Cyclecount or Location (grep clean).
  So "no association path serves their rows" holds.
- "was correct for Slice 1 ... both ends of every association are ruled": left as historical; consistent with
  the first review.
- `SdrFunctionRules` javadoc: "Slice 1 needed none ... AC-2 added the first two production overrides, both on
  Location": TRUE (`productionOverrides()` :378; exactly the Location pair per
  `SdrRuleStartupAssertionUnitTest:204`). The `{@code productionOverrides()}` reference resolves to a private
  static method; javadoc will not link it, but it is not an error for `{@code}`.

## 4. New findings

| ID | Severity | Confidence | File | Evidence | Fix |
|---|---|---|---|---|---|
| F1 | Low | MEDIUM | `SdrFunctionRulesUnitTest.java` ~:230 | `getMethods()` plus a path match does not filter to exported query methods, so the test can pair a key with a non-exported or CRUD method of the same path; the defect is only caught by the boot check, not here. | Filter `getMethods()` to methods where `!isDefault && !isBridge` and `RestResource.exported() != false`, or assert one more fact: that the matched method's declaring class is `repository`. |
| F2 | Low | MEDIUM | `SdrFunctionRulesUnitTest.java` `OVERRIDE_REPOSITORIES` | Hand-maintained map; the "fails naming the type" message is good, but a stale entry for a type that loses its overrides is never flagged. Harmless. | Optional: none needed. |
| F3 | Info | HIGH | `SdrFunctionGuard.java:263-267` | The new comment's last sentence ("its rows are then reachable through the owner's rule, not its own") is a forward-looking rule and true of the guard's owner-type resolution; but nothing enforces it. Not a false claim. | Optional: a startup assertion that no ruled type is an association target. Out of scope. |

No new false claim found in the commit. The Co-Authored-By trailer names "Claude Opus 5.5" while the session
attribution says Sonnet 5.5; cosmetic and not a code claim.

## 5. Positive observations
- The test now iterates the production keys, so the pin survives a third override without edits, and the
  repository lookup fails by name when the map is stale.
- Lookup by search path matches the axis the override is keyed on, closing the re-pointing hole in I1.
- Rewritten guard comment states the exact condition under which the association assumption breaks.

## 6. Verdict
**APPROVE.** N1, N2, I1, I2 are all fixed; the association claim is verified against the entity classes and the
whole model package; the vacuity guard is adequate. F1/F2 are optional hardening.
