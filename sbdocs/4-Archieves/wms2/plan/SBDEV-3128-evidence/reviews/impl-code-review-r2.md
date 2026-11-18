---
ticket: SBDEV-3128
lane: implementation code review r2 (scoped to the round-1 fix commit; read-only, independent)
head: ff4cff9b
base: 7fb22890
date: 2026-11-02
verdict: APPROVE
---

# SBDEV-3128: code review r2 (round-1 fix commit)

**head: ff4cff9b** (`git rev-parse HEAD` = `ff4cff9bbdbf4a7e619bea76dd730a7ac9081e4a`, clean worktree). Scope: `git diff 7fb22890..ff4cff9b`, 12 files, +227 / -60.
Method: read-only. Used `git diff` and `git show ff4cff9b:<path>` in `.claude/worktrees/wms2-api/SBDEV-3128`. I did not run mvn, checkout, restore or stash, and did not read the stale main checkout. Compile and suite results come from the author's report and the parallel test lane, not from this lane.
Inputs: impl-security-review (SEC L1–L4), impl-code-review (CR L-1..L-6, OQ-1), impl-verifier (VER L1, L5), and the implementation report section "Review round 1 fixes".

## Verdict: APPROVE

No High or Medium findings. Every round-1 finding is fixed as claimed, and the commit introduces no regression. There are two new Low findings. Neither blocks the push. Both are cheap, and the house rule is to fix Lows too, so I recommend folding them in. If they are fixed, a re-review of that delta only is enough.

| Sev | Count |
|---|---|
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Open questions | 0 |

## Findings

### L-1 Low (pre-existing since 31263d28, not introduced here): a legitimate 4-decimal value below 0.001 is rejected as "at most 4 decimal places"
`LocationController.decimalOrNull`:
```java
String text = value.toString();
...
return new BigDecimal(text);
```
- **The mechanism.** Jackson is not configured with `USE_BIG_DECIMAL_FOR_FLOATS`. I grepped `src/main` and the properties: the only mapper customisation is `WebConfigurer.objectMapper()`, which sets `FAIL_ON_UNKNOWN_PROPERTIES` and `WRITE_DATES_AS_TIMESTAMPS`. So a JSON fraction arrives as a `Double`. `Double.toString` switches to scientific notation below 10^-3. The UI's JS number `0.0005` therefore becomes `"5.0E-4"`, and `new BigDecimal("5.0E-4")` is unscaled 50 at **scale 5**. `validateDefaultBounds` then throws "Min, Hysteresis and Max allow at most 4 decimal places".
- **The failure scenario.** An operator enters Min 0.0005 (also 0.0001 through 0.0009, and their negatives). AC-8 allows 4 decimals, so the value is valid, but it is refused with a message that is wrong for it. Values at or above 0.001 are unaffected: `0.001` prints plain, and Doubles at or above 10^7 such as `1.23456781234E7` keep scale ≤ 4. Integers arrive as `Integer`/`Long` and are unaffected.
- **Impact.** Very low. Fractional replenishment minimums under 0.001 are implausible. The UI (P2) does not exist yet. The 32-character cap and the Infinity mapping are not involved.
- **Fix.** In `decimalOrNull`, after parsing, strip the trailing zeros only when the scale exceeds 4, so that a genuine 5-decimal value is still refused:
  ```java
  BigDecimal parsed = new BigDecimal(text);
  return parsed.scale() > 4 ? parsed.stripTrailingZeros() : parsed;
  ```
  `5.0E-4` becomes `5E-4` (scale 4, accepted), and `24.00001` stays at scale 5 (refused). Add a controller row that posts the raw JSON `{"id":5,"minAmount":0.0005,"hysteresis":36,"maxAmount":48}` and captures `0.0005` passed to the service.

### L-2 Low (test strength): AC-14 "values" assertions for minAmount, hysteresis and maxAmount cannot tell the row's bounds from the effective default
`ViewDtoServiceUnitTest.fixedAssignmentView_shouldCarryInheritanceAndDefaultKeys_whenRowRendered`:
```java
FixLocationAssignmentDetailView view = flaRow();   // getMin/Hyst/MaxAmount = 36.0000 / 60.0000 / 84.0000
...
sysprops("36", "60", "84");                        // effective default (defaultMin/Hyst/MaxAmount) = 36 / 60 / 84
...
assertThat(new BigDecimal(dto.get("minAmount").toString())).isEqualByComparingTo("36");
```
- **The failure scenario.** The mutant `dto.put("minAmount", effective[0])` (and the same for hysteresis and maxAmount) survives, because the row's triple equals the sysprop triple by `compareTo`. The new test comment says "their VALUES too, each from its own getter", which is true for the six non-bound keys but not for the three bounds. VER L5 is fixed for 6 of 9 keys and only partly for the other 3.
- **Fix.** In this test only, call `sysprops("10", "20", "30")`, or stub the row as 24/36/48. Nothing else in the test depends on the sysprop values; it uses only `containsKeys` for the new keys. Then confirm the hand mutant above turns red.

## Round-1 findings: fixed as claimed?

| Finding | Status | Evidence |
|---|---|---|
| SEC L1 / CR L-1: no magnitude or length limit | **Fixed** | `decimalOrNull` accepts `instanceof Number` only, caps `toString()` at 32 characters, and maps NFE to "must be a finite number". `validateDefaultBounds` adds `upper.abs().compareTo(1E+13) >= 0`, placed after the ordering checks, so Max ≥ Hysteresis ≥ Min ≥ 0 and bounding Max bounds all three. The scale check comes first, so no value can round up to 10^13 in the DB. |
| SEC L2: `catch (Exception)` echoed SQL/JVM text | **Fixed** | The handler catches only `BusinessException`. A malformed id is refused by `instanceof` before the cast. See the "Regression checks" section for the status and shape. |
| SEC L3: reset's cast outside the try | **Fixed** | `FixLocationAssignmentController.resetBoundsToDefault` checks `instanceof Number idNumber` before the cast. A new unit test posts `"abc"` and verifies `never()` on the service. |
| SEC L4: raw id logged before the type check | **Fixed** | `LOG.debug("updateBoundDefaults id={}", id)` now runs after the check, on the `Long`. |
| CR L-2 / VER L1: stale AC-18 names | **Fixed** | Merged. See the "Test edits" section. The SBDEV-3668 display name is updated. |
| CR L-3 / CR L-4: V2.2.45 header wording | **Fixed and accurate** | See the "Migration" section. |
| CR L-5: duplicated sysprop parse | **Fixed, behaviour identical** | See the "parseLongOrDefault" section. |
| CR L-6: reset's 409/404 are ProblemDetails | **Documented** | Plan §3.4 has a new bullet at line 318 that names 409/404 `ProblemDetail`, 500 for anything else, and the UI treating non-2xx as `false`. The §3.4 table cell for updateBoundDefaults still reads only "200 … · 200 `{errors}`". The bullet sits directly below it, so this is cosmetic and not a finding. |
| CR OQ-1: committed-fixture cleanup vs replenishorder | **Fixed** | See the "IT cleanup" section. |
| VER L5: AC-14 keys by presence only | **Partly fixed** | Values are asserted for 9 keys, but 3 cannot distinguish their source. See L-2. |

## Regression checks

### `LocationController.updateBoundDefaults`: narrowed catch, status and shape
- `RestExceptionHandler` (`@Order(0)`, global) has handlers for `BusinessException` (422; never reached here, because the controller catches it first), `EntityNotFoundException` (404 `ProblemDetail`, `:200-210`), `ObjectOptimisticLockingFailureException` (409, `:384`) and `PessimisticLockingFailureException` (`:393`, which covers a `lockById` lock timeout). By its own javadoc (`:40-46`) it declares **no** `Exception` handler.
- `LocationController` is in `net.aim_ai.wms.controller`. The two scoped catch-alls (`RestEndpointExceptionHandler`, `RestEndpointFallbackExceptionHandler`) are limited to `controller.rest` and `MobileEndpointExceptionHandler` to `controller.mobile`, so none of them applies.
- A `DataAccessException` therefore falls through to Spring Boot's `/error`. `/error` is `permitAll` (`SecurityConfiguration:151`), so the response is 500 with `{timestamp,status,error,path}`. No `server.error.include-message` or `include-stacktrace` override exists in `src/main/resources`, so no SQL text is returned. That is a sane status and shape.
- The new unit test `updateBoundDefaults_dataAccessException_propagates` proves the exception escapes the handler. It runs in a standalone setup without advice, so it does not assert the final 500 body. That is acceptable, because no handler exists for it to reach.

### Number-only input, 32-character cap, Infinity: can a legitimate UI payload be rejected?
- **Integers:** Jackson gives `Integer`, `Long`, or `BigInteger`. `Long.MIN_VALUE` is 20 characters, so the cap only refuses a BigInteger of 33 or more digits, which the 10^13 bound would refuse anyway.
- **Fractions:** Jackson gives a `Double`, whose `toString` is at most about 24 characters (for example `-1.2345678901234567E-308`). The cap never refuses a finite double.
- **`1e400`:** Jackson gives `Double.POSITIVE_INFINITY`, whose text is `"Infinity"`. That raises an NFE, which is mapped to "must be a finite number". `NaN` and `Infinity` literals are refused earlier: `ALLOW_NON_NUMERIC_NUMBERS` is not enabled, so they produce a 400 from the message converter.
- **Strings such as `"24"`:** these are now refused. The UI contract (plan §3.4, UI-1) posts JS numbers, so this is the intended tightening.
- **The one legitimate rejection** is the sub-0.001 case in L-1. It is pre-existing and was not introduced by this commit.

### `abs() >= 10^13` against `numeric(17,4)`
- `numeric(17,4)` has 13 integer digits, so its maximum is `9999999999999.9999`, which is below 10^13. The bound is exclusive at 10^13, so the edge is exact.
- The scale ≤ 4 check runs first, so PostgreSQL never rounds an accepted value up to 10^13. For example, `9999999999999.99995` is refused on scale.
- Negative-scale input such as `1E+20` passes the scale check and is caught by the bound. A unit row covers it.
- The location default columns are `numeric(17,4)` (V2.2.45). The FLA write-through targets `fix_location_assignment.lower/middle/upperbound`, which are also `numeric(17,4) NOT NULL` (`V2.2.00:914-916`), so reset and write-through cannot overflow either.
- The CHECK `ck_location_default_bounds` has no upper bound, and none is needed, since the type enforces it. The CHECK and the service rules agree on all-or-none, Min ≥ 0, Min ≤ Hysteresis, and Hysteresis < Max.
- `abs()` is redundant, because Max is positive at that point, but it is harmless.

### `SyspropService.parseLongOrDefault`: identical behaviour
`Long.parseLong(value == null ? defaultValue : value)`

| Input | Before (FLA service) | Before (ViewDto) | After (both) |
|---|---|---|---|
| null | WARN, then `parseLong(default)` | `parseLong(default)` | Write path: WARN is kept, then `parseLong(default)`. View: `parseLong(default)` |
| `""` | NFE | NFE, mapped to SYSTEM_INVALID | NFE; the view still maps it to SYSTEM_INVALID |
| `" 84 "` | NFE (no trim) | NFE, mapped to SYSTEM_INVALID | NFE; SYSTEM_INVALID |
| `"abc"`, `"84.5"` | NFE | NFE, mapped to SYSTEM_INVALID | NFE; SYSTEM_INVALID |
| `"90"`, `"-3"` | the parsed value | the parsed value | the parsed value |

- The `catch (NumberFormatException)` in `systemFixLocationAssignmentDefaultOrNull` is unchanged and still wraps all three calls.
- Making the helper static keeps each caller's read on its own proxied `getSysvalue`, so the cache is preserved.
- The new `if (value == null)` in `parseSyspropLong` only logs. The author's equivalent-mutant note at PIT line 463 is correct.

### Migration V2.2.45: comments only, header accurate, plan byte-identical
- `git diff -U0 7fb22890..ff4cff9b -- src/main/resources/db/migration/`, filtered to changed lines not starting `--`, is **empty**. The change is 10 additions and 7 deletions, all comment lines. No SQL changed.
- The plan §3.1 fenced block (from plan line 153 to the closing fence) was compared with `git show ff4cff9b:…V2.2.45….sql` using `diff`: **identical across the whole file**. The 32-line headers also match by `cmp`, both with sha1 `0463c622…`.
- Header claims checked against the SQL body:
  - "three ALTERs (two on location, one on fix_location_assignment)": the ADD COLUMN on location, the ADD CONSTRAINT on location inside the DO block, and the ADD COLUMN on fix_location_assignment. That is correct.
  - "adding the CHECK also scans location": the CHECK is added without `NOT VALID`, so it does scan. Correct.
  - "not an optionally signed ASCII integer of at most 18 digits": the regex is `^[+-]?[0-9]{1,18}$`. Correct.
  - "narrower than Long.parseLong, which also accepts 19-digit and non-ASCII digit values": `Long.parseLong` uses `Character.digit`, so it accepts Unicode digits, and 19-digit values up to 2^63-1. Every 18-digit value fits in a long, so no value passes the regex and fails `parseLong`. The relation is strictly narrower, in the safe direction. Correct.
- The checksum landmine, where reused containers need a one-row repair, is documented in the implementation report. No real environment has applied V2.2.45. The header is accurate, so freezing it is fine.

### Test edits
- **AC-18 merge.** The old `_absentUpperSysprop_fallsBackTo84` asserted no throw when the value is absent, plus `never().getSysvalue(UP)`. The old `_paddedAndDecimal_parse` asserted no throw for `" 84 "`, no throw for `"84.5"`, plus `never()`. The merged `_neverReadsUpperSysprop` asserts all three no-throw cases and one `never()`, which covers every invocation. **No distinct assertion is dropped.** The test count went from 106 to 105, which matches "110 − 1".
- **AC-14 values.** Six of the nine keys are now discriminating. The three bound keys are not discriminating (L-2).
- **New controller tests.** `assertRejectedBeforeService` checks the field, the message, and `never()` on the service, so every rejection is pinned to happen before the service is called. Good.
- **New service rows.** `(1, 2, 10000000000000)` and `(1, 2, 1E+20)` are rejected, and `(0, 1, 9999999999999.9999)` is accepted. Together they pin both sides of the edge.

### IT cleanup: replenishorder delete scope
```java
"DELETE FROM replenishorder WHERE requestedlocation_id = ? OR destination_id = ?"
  + " OR itemdata_id IN (SELECT i.id FROM itemdata i WHERE i.putawaylocation_id = ?)", id, id, id
```
- `id` ranges only over `locationIds`, the locations this test itself saved and committed. They have fresh sequence ids with `S3128-*` names.
- The item predicate (`putawaylocation_id = fixture location`) is the same predicate the existing `DELETE FROM itemdata` line below already used. It therefore matches only the fixture items, which are created with `PgLaneFixtures.itemdata(…, location.getId())`.
- Could another test own a replenishorder row that references a location or item created moments ago by this test? Only if that test wrote one through this test's fixtures, and such a row would be residue of this test anyway.
- FK check in V2.2.00: replenishorder has outgoing FKs `requestedlocation_id`, `destination_id`, `itemdata_id`, `requestedrack_id`, `client_id`, `operator_id` and `stockunit_id`. A grep for `REFERENCES public.replenishorder` finds **no** incoming FK, so the delete cannot cascade or block.
- Deleting first is the correct child-first order. **The scope is tight enough.**

## Ruled out (checked, found fine)
- `decimalOrNull` throws `BusinessException`, but it is only called inside the `try`, so the controller's signature is unaffected and the exception is caught into `{errors}`.
- Reset `{errors}` vs ProblemDetail: the catch was already `BusinessException`-only before this commit. The only change is that a malformed id now gives `{errors}` instead of a 500.
- Both new instanceof-pattern checks require Java 16 or later. The project uses Java 21.
- A missing `id` (null) fails `instanceof`, so it yields "id must be a number". No NPE can occur.
- A negative-zero or negative Max cannot reach the bound check, because the ordering checks reject them first.
- Messages: "Max must be below 10,000,000,000,000" is accurate for the exclusive bound.
- No secrets, no new logging of payloads, no commented-out code, and no `.skip`/`.only` were added. The only new log line logs a `Long`.
- The `@RequiresFunction` gates are unchanged on both handlers.
- `LocationDefaultBoundsEndpointContractUnitTest` and the gate-context tests are untouched by this commit. The author reports them green, and the parallel test lane owns re-running them.
- lsp_diagnostics were not run (read-only lane, no build). The author reports that `mvn -o -q clean compile` exited 0 on this tree. The test lane is the compile authority for head `ff4cff9b`.

## Positive observations
- Each fix maps one-to-one to a finding. The proof column names the red-before test, and several cite hand mutants restored byte-equal.
- `instanceof`-before-cast is a cleaner way to refuse a malformed id than catching `ClassCastException`.
- The magnitude rule is placed after the ordering checks, with a comment explaining why one bound suffices. Using `abs()` also catches negative-scale input without a second rule.
- The plan and the SQL were proven identical by script before the header becomes checksum-frozen, and the reused-container landmine is written down.
- The cleanup comment explains why replenishorder rows can appear and why deleting them first is safe.
