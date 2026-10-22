---
title: SBDEV-3183 AC-2 rules — independent re-review of the fix commit (3eae73ce) and the #527 merge (795a3930)
date: 2026-10-18
lane: code-reviewer (read-only; no Maven run, per brief)
worktree: rv-3183-ac2 (detached at 795a3930)
verdict: APPROVE (no High/Medium; two Low and two Info prose/test-hygiene findings)
---

# SBDEV-3183 AC-2: re-review of 3eae73ce and 795a3930

Method: `git show 3eae73ce`, `git diff 3eae73ce 795a3930`, targeted reads of `SdrFunctionGuard`,
`SdrGuardMode`, `SdrFunctionRules`, `LocationRepository`, `RestConfiguration`, `WmsConstants`, and the
three test classes. Nothing was compiled or executed; "would go red" statements are by reading.

## 1. Disposition of the original findings

| ID | Original | Disposition | Evidence |
|---|---|---|---|
| M1 | No test drives an override through `SdrFunctionGuard.evaluate` | **FIXED** | `SdrFunctionGuardUnitTest.searchOverrideReachesAccessService` (≈:271-297). Guard is built with production `new SdrFunctionRules()` (setUp :84), Location is added to `fakeMappings()` so `"location"` resolves, mode ENFORCE_RULED, `checkAnyAccess` captured as `String[]` and asserted `containsExactly(expected)`. Mutant `requiredFunctions(domainType, null)` at `SdrFunctionGuard.java:268`: `findByGateTrue` would yield `WEB_UI_VIEW_STORAGE_LOCATION` ≠ `WEB_UI_VIEW_BILL_OF_LADING`, and `getAllCrossDockingLanes` likewise ≠ `INBOUND_BOL` → both rows red; the commit's "killed" claim is consistent with the code. The `findByName` and `item` rows are non-vacuity rails (type rule still applied). Constants are `String` with value == name (`WmsConstants.java:408`), so the CSV literal comparison is sound; `@CsvSource` trims whitespace by default. Cannot pass for the wrong reason: a guard that never consulted AccessService fails `verify(...)`; a guard that used the type rule fails the content assertion. |
| L1 | Cypress note omits `findByGateTrue` / BILL_OF_LADING | **FIXED** | `SdrFunctionRules.java:348-350` now names `GET /location/search/findByGateTrue (support/helpers/wmsHelpers.js)` and all four functions. |
| L2 | "Only SDR caller found" is literally false (dead DELETE) | **FIXED** | `SdrFunctionRules.java:359-361`: "Only live SDR caller … A DELETE in inboundNotices.js is unreachable … RestConfiguration already withdraws item DELETE, so it answers 405 regardless." Verified `RestConfiguration.java:682-685` disables `PUT, DELETE` on Advice item exposure. |
| L3 | Three comments still say production ships no overrides | **FIXED, with one new inaccuracy (N1)** | `SdrFunctionRules.forTesting` javadoc (:85), `SdrRuleInventoryContextTest.java:78-79`, `SdrFunctionRulesUnitTest.java:268-269` all rewritten. The third rewrite says the Location overrides are "pinned by their own tests below" — they are above (N1). |
| S3 | Override validated by path only; a parameter added later would widen it silently | **FIXED** | `SdrFunctionRulesUnitTest.overriddenLocationSearchesTakeNoParameters` (≈:204-223) asserts exactly one `LocationRepository` method of each name and `getParameterCount() == 0`. Current signatures `LocationRepository.java:99 findByGateTrue()` and `:178 getAllCrossDockingLanes()` take none, so it is green now and goes red on a new parameter or an overload. Residual limits recorded as I1. |
| S4 | Same as L2 (accuracy) | **FIXED** | As L2. |
| S5 | Cypress user needs BILL_OF_LADING before AC-5 | **FIXED (prose)** | As L1. Whether the Cypress user actually holds the four functions is an AC-5 prerequisite, not checked here. |
| S1 | Advice/Cyclecount PATCH binds every non-read-only field | **Deferred by design** (register row P3) | Not in this commit's scope; pre-existing. Not re-reviewed. |

## 2. The #527 merge (795a3930) against the enlarged fixture

The merge brings `wouldDeny(label, counterFunctionTag, decision, request)` plus its log line, the
`SdrGuardMode` SHADOW javadoc, and seven new/extended tests. Textual merge is clean: the Location line
sits in `fakeMappings()` at :131, and the #527 additions are the only delta between 3eae73ce and 795a3930.

Dependency of each #527 test on the shared fixture:

| #527 test | Fixture used | Depends on fixture contents? |
|---|---|---|
| `shadowWouldDenyLogsAttributableLine` | shared; `userGroup/search/findByName` | Only that `userGroup` resolves. No override on UserGroup, so the Location change is irrelevant. |
| `shadowRootIndexWouldDenyIsLogged` | shared; ROOT_INDEX | No — index row never consults the mappings by path. |
| `shadowLogsEachReasonAtItsLevel` | shared; `userGroup` | No. |
| `shadowLogsNothingWhenNothingWouldBeDenied` | shared; `userGroup`, `itemdata` (unruled) | Only that Itemdata stays unruled — still true (Location, not Itemdata, gained a rule). |
| `enforcingDenialIsNotLoggedAsWouldDeny` | shared; `userGroup` | No. |
| unresolvable-row counter-tag pin (≈:689-697) | shared; `somethingSpringRenamedInAnUpgrade` | No — the path is absent with or without Location. |
| `duplicateExportedPathIsDetected` count pin | **own** `FakeMappings` (`clash` ×2) | No — independent fixture. |
| `unexportedMetadataIsNotIndexed` | **own** `FakeMappings` | No. |

No test asserts the index size, iterates all mappings, or counts meters across all domain types, and
`buildIndex` registers a meter only on a collision (`SdrFunctionGuard.java:492`); `location` collides with
nothing. **No #527 test changes behaviour because of the added Location mapping.**

Counts after the merge: `SdrFunctionRules` has 11 `rules.put` (User, UserFunction, UserGroup,
UserGroupUser, UserRole, Sysprop, Message, StockrecordView, Advice, Cyclecount, Location) and two overrides;
`SdrFunctionGuard.java:270-282` says "11 rules … the other 24" and "35 - 11 = 24" — consistent.
`SdrGuardMode` javadoc carries no rule count; its table now says SHADOW root index "record a would-deny,
allow", which matches `SdrFunctionGuard.java:235`. No count contradicts the merged state.

## 3. New findings

| ID | Severity | Confidence | File | Evidence | Fix |
|---|---|---|---|---|---|
| N1 | Low | HIGH | `src/test/java/net/aim_ai/wms/unit/security/SdrFunctionRulesUnitTest.java:268-269` | Comment written by 3eae73ce for L3: "SBDEV-3183 AC-2's two Location searches are pinned by their own tests **below** and in SdrRuleStartupAssertionUnitTest". The Location override tests are `locationGateSearchRequiresViewBillOfLading` (:197) and `locationCrossDockSearchRequiresViewInboundBol` (:227), both **above** :266. The `SdrRuleStartupAssertionUnitTest:204` half is true. A fix for a false claim produced a new one. | "…pinned by their own tests above (locationGateSearch…, locationCrossDockSearch…) and by SdrRuleStartupAssertionUnitTest.productionOverridesAreExactlyTheLocationPair". |
| N2 | Low | HIGH | `src/test/java/net/aim_ai/wms/unit/security/SdrFunctionGuardUnitTest.java:126` | Fixture javadoc still reads "Three exported resources: two Slice 1 types and one deliberately unruled type." 3eae73ce made it four, and the fourth (Location) is ruled. Readers of the #527 tests rely on "itemdata is the one unruled type" — still true, but the stated shape is wrong. | "Four exported resources: three ruled types (UserGroup, UserRole, Location — Location carries the AC-2 search overrides) and one deliberately unruled type (Itemdata)." |
| I1 | Info | MEDIUM | `SdrFunctionRulesUnitTest.overriddenLocationSearchesTakeNoParameters` | The test is keyed on two hard-coded method **names**; the override is keyed on the search **path**. They coincide today (`@RestResource(path = "findByGateTrue")`, `path = "getAllCrossDockingLanes"`), and `productionOverridesAreExactlyTheLocationPair` forces a visit when the override set changes, so this is not a hole now. It would not, however, automatically cover a third override, and it would check the wrong method if a path were re-pointed at a differently-named method. | Optional: derive the list from the production override keys and resolve each method by its `@RestResource(path)` (falling back to the method name), then assert zero parameters. |
| I2 | Info | HIGH | `src/main/java/net/aim_ai/wms/security/SdrFunctionRules.java:35-37` (class javadoc) and `SdrFunctionGuard.java:263-265` | Class javadoc: "Slice 1 needs none … the mechanism ships with Slice 1 so Slice 3 does not have to introduce it untested." Guard comment: association reads resolve the owning type, "correct for Slice 1: both ends of every association it gates are themselves in the ruled set." Both are historically accurate and not false as such, but neither says production now carries overrides (added in AC-2, not "Slice 3"), and the guard comment's justification is Slice-1 scoped. The first review established that no association targets Advice, Cyclecount or Location, so the behaviour is fine. | Optional one-line updates: "Production carries two, both on Location (SBDEV-3183 AC-2)" and "…still holds after AC-2: no association targets Advice, Cyclecount or Location". |

### Open questions (not blocking)
- The M1 mutation result ("passing null reds both override rows") is consistent with the code but was not re-executed by this lane (no Maven run, per brief).
- Whether the Cypress user holds the four functions (S5) remains an AC-5 prerequisite to check against the DB.

## 4. Positive observations
- The M1 test pins the *argument* the guard sends to AccessService rather than just the verdict, which is the only assertion that separates the override from the type rule when AccessService is mocked to allow.
- The guard test uses the production `SdrFunctionRules`, so it pins the real override wiring rather than a fixture copy.
- The S3 test's lookup by name instead of `getMethod(name)` gives a readable failure instead of `NoSuchMethodException`, and it covers overloads through `hasSize(1)`.
- The #527 merge adds count assertions (`c.count() == 1.0` on path_collision, the counter `function` tag on the unresolvable row) that kill meter-registration-only mutants. Neither depends on the shared fixture.

## 5. Verdict
**APPROVE.** Every claimed fix (M1, L1, L2, L3, S3, S4, S5) is present and does what it says. The M1 test cannot pass for the wrong reason. The #527 tests do not depend on the shared fixture in any way the added Location mapping affects, and the 11-ruled / 24-unruled arithmetic matches the merged rule set. N1 and N2 are one-line comment corrections that can go in the same pass. I1 and I2 are optional.
