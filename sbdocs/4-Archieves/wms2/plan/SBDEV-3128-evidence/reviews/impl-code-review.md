---
ticket: SBDEV-3128
lane: implementation code review (read-only, independent)
head: 7fb22890
base: origin/develop 8171c80a
date: 2026-11-02
verdict: APPROVE
---

# SBDEV-3128 Phase 1: implementation code review

**head: 7fb22890** (2 commits: `31263d28`, `7fb22890`). Base `8171c80a`. 27 files, +2725 / -39.
Method: `git diff 8171c80a...7fb22890` plus `git show 7fb22890:<path>` for context. The review was read-only: no mvn, no checkout, and the stale main checkout was not read.
Read against plan r4 §3.1–3.8 and §10.1 D1–D9, the post-plan D-1 decision, `CLAUDE.md`, and the r1–r3 reviews. Settled points were not re-raised. The r3 L-2 early-flush point in particular is settled.

## Verdict: APPROVE

No High or Medium findings. Six Low findings follow, plus two low-confidence open questions. None disputes the design, so no finding carries a `DESIGN` label. §3 behaviour is implemented as written.

| Sev | Count |
|---|---|
| High | 0 |
| Medium | 0 |
| Low | 6 |
| Open questions (low confidence) | 2 |

## Findings

### L-1 Low: no magnitude check, so an over-range default reaches the DB as a raw SQL error
`FixLocationAssignmentService.validateDefaultBounds`:
```java
if (lower.scale() > 4 || middle.scale() > 4 || upper.scale() > 4) { ... }
```
- **What happens.** `numeric(17,4)` allows 13 integer digits. A value of 1e13 or more (for example `maxAmount: 99999999999999`) passes every check. `updateDefaultBounds` then raises `22003 numeric field overflow`. `LocationController.updateBoundDefaults` catches it in `catch (Exception e)` and returns 200 `{errors}` carrying the raw JDBC or Hibernate text.
- **Why it matters.** L-7 added the scale check to avoid exactly this outcome (a raw SQL error instead of a house message). The same reasoning covers precision.
- **Confidence:** HIGH. The impact is low because an operator would have to type a 14-digit number.
- **Fix:** add a precision check:
  ```java
  if (lower.precision() - lower.scale() > 13 || ...)
      throw new BusinessException("Min, Hysteresis and Max must be below 10,000,000,000,000");
  ```
  Add one row to `invalidTriples()` and one accepted edge row at `9999999999999.9999`.

### L-2 Low: two AC-18 test names and one DisplayName still describe the superseded fallback
`ViewDtoServiceUnitTest$Sbdev3128DefaultBoundsViews`:
```java
@DisplayName("AC-18 (D-1): UPPER sysprop absent → no NPE")
void replenishOrderViewByKeyword_absentUpperSysprop_fallsBackTo84() {
...
@DisplayName("AC-18 (L-5): ' 84 ' and '84.5' both parse")
void replenishOrderViewByKeyword_paddedAndDecimal_parse() {
```
- **What is wrong.** After D-1, nothing reads this sysprop, so nothing "falls back to 84" and nothing "parses".
- **The second test is redundant.** It stubs a value that is never read (it has to be `lenient()` for that reason). It also asserts the same `never().getSysvalue(UP)` as the first test, so it can only fail when the first one does.
- **Effect:** a reader would conclude the L-5 parsing behaviour is still pinned.
- **Confidence:** HIGH.
- **Fix:**
  - Rename the first test to `replenishOrderViewByKeyword_neverReadsUpperSysprop` and update its DisplayName.
  - Delete the second test, or fold it into the first as one more `assertThatCode` with a non-null stub.
  - Update the nested-class javadoc, which still says AC-18 "fails at an assertion on the unfixed build" about a parse behaviour.

### L-3 Low: the frozen migration header says "Both ALTERs" where it means both tables
`V2.2.45__location_default_fla_bounds.sql:16`:
```sql
-- lock_timeout: same pattern and value as V2.2.40. Both ALTERs take ACCESS EXCLUSIVE ...
```
- **What is wrong.** The script runs three `ALTER TABLE` statements. Two are on `location`: ADD COLUMN, and ADD CONSTRAINT inside the `DO` block. The ADD CONSTRAINT also scans the table under that lock. The third is on `fix_location_assignment`, which is then held for the backfill UPDATE.
- **Effect:** the conclusion is unaffected, but the header becomes checksum-frozen at first apply.
- **Confidence:** HIGH.
- **Fix (before any tenant applies it):** "The ALTERs on both tables take ACCESS EXCLUSIVE (the CHECK add also scans `location`), held until commit".

### L-4 Low: the backfill regex and `Long.parseLong` disagree on 19-digit values
`V2.2.45:31-41`:
```sql
CASE WHEN sysvalue ~ '^[+-]?[0-9]{1,18}$' THEN sysvalue::numeric END
```
- **What differs.** `Long.parseLong` accepts 19-digit values up to 9223372036854775807. It also accepts non-ASCII Unicode digits, because it uses `Character.digit`.
- **Effect:** for such a sysprop, the backfill uses 36/60/84 while `parseSyspropLong` uses the parsed value. FLAs at that value would classify OVERRIDDEN, which is the fail-safe direction. The header nonetheless claims the backfill mirrors `Long.parseLong` exactly.
- **Confidence:** HIGH that they diverge. The divergence is practically unreachable.
- **Fix:** either change the header claim to "mirrors `Long.parseLong` for ASCII values of up to 18 digits", or widen to `{1,19}` and add a range guard. The header edit is cheaper and is enough.

### L-5 Low: the sysprop-triple parse is duplicated in two services
- **Where:** `ViewDtoService.systemFixLocationAssignmentDefaultOrNull` / `syspropLongAsDecimal` and `FixLocationAssignmentService.systemDefaultBounds` / `parseSyspropLong`. The javadoc says "exactly as FixLocationAssignmentService parses it", but nothing enforces that.
- **Effect:** if one side changes (for example, `parseSyspropLong` starts trimming or accepts decimals), `boundsOutOfDate` silently disagrees with what create, reset and clear write.
- **Confidence:** MEDIUM. This is a maintainability risk, not a current bug.
- **Fix:** move one helper into `SyspropService`. That service is already injected in both places. A sketch:
  ```java
  long getFlaDefaultLong(String key, String fallback)
  ```
  Then have the view wrap it in its `NumberFormatException` catch. If that is out of scope, add one unit test that feeds the same inputs to both paths and asserts they agree.

### L-6 Low: reset's two non-BusinessException failures leave the `{errors}` shape
`FixLocationAssignmentController.resetBoundsToDefault`:
```java
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
}
```
- **What happens.** The service throws `ObjectOptimisticLockingFailureException` on a concurrent move, delete or stale state (L-1 by design). `RestExceptionHandler:384` maps it to a 409 `ProblemDetail`. A deleted FLA produces `EntityNotFoundException`, which is mapped at `:200`.
- **Comparison.** Plan §3.4 lists only 200 and 200 `{errors}`. The sibling `move` handler behaves the same way, so the code is consistent with its controller.
- **Effect:** the P2 UI action must treat a non-2xx response as `false` and surface the `ProblemDetail` (memory: apiError ProblemDetail). Otherwise a concurrent move shows a generic failure.
- **Confidence:** HIGH that this is the behaviour. It is Low because it matches the sibling.
- **Fix:** none in this commit. Add a line to §3.4's response column ("409 ProblemDetail on a concurrent move or delete"), and give a P2 UI test the 409 case.

## Open questions (low confidence, not blocking)

### OQ-1: the committed fixtures in `CreateEditRace` and `AdjustCommitted` vs post-commit maintenance
- **The concern.** `createFixedLocationAssignment` and `adjustUpperBound` call `replenishmentMaintenanceTrigger.requestForItem`. On these committed (`NOT_SUPPORTED`) tests, that runs synchronously after commit in a `REQUIRES_NEW` (`ReplenishmentMaintenanceTrigger:88-110`). If maintenance ever writes a row that references the fixture item or location (a replenish order), `deleteCommitted` would fail on an FK. Its delete list covers only FLA, unitload_record, unitload, itemdata and location. The failure would leave committed residue in the shared IT database.
- **Why it is probably fine today:** the fixture item has no stock anywhere, so maintenance most likely creates nothing.
- **Probe:** after one run of each nested class, query `replenishorder` for the `S3128-SKU-%` items. Or add `DELETE FROM replenishorder WHERE itemdata_id IN (...)` to `deleteCommitted` defensively.

### OQ-2: whether the H2 `current_schema()` probe and the `TestDatabaseConfig` bean order hold on CI
- **The concern.** Plan §3.2 measured H2 2.3.232 locally. The bean is `@DependsOn("tenantEntityManagerFactory")` and runs `ALTER TABLE location ...`. If a context creates `tenantEntityManagerFactory` lazily, or recreates it under `@DirtiesContext`, create-drop would rebuild the tables without the columns.
- **What would happen:** the H2 lane silently takes the legacy path. AC-20c (`MobilePutawayServiceIntegrationTest`) is the guard and would go red, so this is surfaced rather than masked.
- **Confidence:** LOW. The plan's §3.8 gate check already covers it. Listed only so the test lane confirms AC-20c is green on CI rather than skipped.

## Ruled out (checked, found fine)

**Transactions**
- Every new or changed `@Transactional` is `value = "tenantTransactionManager", rollbackFor = {BusinessException, FacadeException}`: `adjust*` ×3, `resetBoundsToLocationDefault`, `updateLocationBoundDefaults`, and `move` (unchanged).
- No new repository method carries `@Transactional` (L-3), and `LocationDefaultBoundsRepositoryContractUnitTest` pins that.
- No self-invocation of a transactional method inside `FixLocationAssignmentService`.
- `createFixedLocationAssignment` stays non-transactional. All five callers are transactional (§3.6), and `lockById` fails closed (`TransactionRequiredException`) for any future caller without a transaction.

**`@Modifying` and the `== 1` guards**
- `markInherited` and `markOverridden` have `flushAutomatically = true`. `resetBounds`, `writeThroughInherited` and `updateDefaultBounds` are plain `@Modifying`, and this is safe: none of their callers holds a dirty FLA when they run.
- `markInherited != 1` throws `IllegalStateException`. `markOverridden != 1` and `resetBounds != 1` throw OOLFE.
- `updateDefaultBounds` is unguarded. That is fine because `lockById` proved the row exists and holds it.
- The `writeThroughInherited` result is used as `== 1`. That is correct because of `uk_qakwvmdhdymic54v3dgie46wa UNIQUE (assignedlocation_id)` (`V2.2.00:3764`).

**Predicates**
- `markOverridden` is predicated `and version = :version`, using the version of the entity loaded in the same transaction. It does not bump `version`, but the entity save that follows does, so a concurrent adjust is serialized: the FLA row lock is held, the WHERE is re-evaluated after the wait, and the second adjust gets 0 rows and a loud failure.
- `resetBounds` is predicated on `assignedlocation_id = :locationId`, using the location read before `lockById`, as L-1 specifies. `writeThroughInherited` is predicated on `bounds_inherited`.
- The PG IT has positive and negative controls for each (`markOverridden_staleVersion_noRow`, `resetBounds_afterMove_noRow`, `edit_writesThroughInheritedOnly`).

**Reset never dirties the FLA.** `resetBoundsToLocationDefault` calls no setter and no `save`. The managed copy is stale on purpose, and the commit-time dirty check finds nothing to flush. The unit test asserts `never().save`.

**Lock order**
- In create, `lockById` comes before `findDefaultBoundsById` (inside `lockAndResolveDefaultBounds`) and before `createUnitload`. The unit test `create_probeTrue_locksBeforeCreateUnitload` pins it with `InOrder`.
- In the edit, `lockById` comes before `findById` and before any write.
- In move, the re-lock is re-entrant, as §3.6 says.
- Under probe false, create does no `lockById`, no native read and no `markInherited` (unit `create_probeFalse_legacyPath`).

**Order of operations (D6, D7, D9)**
- In `updateLocationBoundDefaults`, validation comes before the probe, the probe before the lock, and the lock before the flowbin check (setting only), then the write and the write-through.
- Clear on a non-flowbin is allowed (AC-16b), and clear writes inherited FLAs back to the sysprop triple.
- The D9 message matches the plan verbatim.

**Native SQL**
- The new native queries take no `String` filter parameters, so CLAUDE.md's optional-String-filter rule does not apply.
- The information_schema probe uses `current_schema()`, which works on PG 14 and on H2 with `DATABASE_TO_LOWER` (plan §3.2 measurement).
- Hand-checked: the `exists(...)` → `boolean` return, `Optional<Boolean>` for a scalar, and `Integer :version` against an int column.

**Migration**
- `SET LOCAL lock_timeout = '5s'` (D4) comes first.
- `ADD COLUMN IF NOT EXISTS` ×4 plus the `pg_constraint`-guarded CHECK make the script idempotent.
- The CHECK matches `validateDefaultBounds` exactly: all-or-none, `>= 0`, `<=`, `<`.
- `bounds_inherited NOT NULL DEFAULT false` is the fail-safe.
- The backfill's `workstation = 'DEFAULT' ORDER BY client_id LIMIT 1` mirrors `SyspropRepository.findSysvalueBySyskey:30` exactly, including its untrimmed value: both sides reject `' 84'`. Apart from L-4, the regex makes garbage fall back instead of failing the cast.
- The migration IT covers the tenant sysprop, an absent row, a non-DEFAULT workstation, the lowest client in both scan orders, `abc` and `84.5`, the CHECK reject and accept edges, and probe false then true.

**Error shapes**
- `updateBoundDefaults` copies the `createLocation` / `updateLocation` idiom (BusinessException plus a generic Exception, both mapped to 200 `{errors}`).
- `resetBoundsToDefault` copies `setUpperBound` / `move`: the `id` cast sits outside the `try`, same as its siblings.
- The validation messages follow the existing adjust wording.

**Keys**
- `getLocationView` and `getLocationDetails` use `defaultMinAmount` / `defaultHysteresis` / `defaultMaxAmount`. The FLA view uses `boundsInherited`, `locationDefault*`, `defaultSource`, `default*` (effective) and `boundsOutOfDate`. These match §3.4 exactly.
- `default*` means the location's own triple in one DTO and the effective triple in the other. §3.4 specifies it that way, so it is not raised.
- `getLocationDetails` omits the keys under probe false (D9).

**D-1**
- The `ViewDtoService` UPPER_BOUND read and the `getStockPerLocation` parameter are removed, with no leftover reference. `BigDecimal` is still used.
- 10 tests drop a `getSysvalue(anyString())` stub that strict stubs would now reject. The `InOrder` test drops only the removed read, keeps the scope-first order, and adds `never().getSysvalue(any())`. This narrows nothing: the code no longer reads the value.

**Arch-test edits**
- `FunctionGuardArchTest` goes from `containsExactly("findByAssignedlocationId")` to `containsExactlyInAnyOrder` with the five new methods named explicitly. The pin stays exact, so it is not loosened.
- `TestClassTransactionManagerArchTest` adds two entries to the declared non-transactional-propagation set. They use the existing `Class#method` / `Outer$Inner` key forms (precedent `:195`), and each has a justification comment. That is an addition to a pinned set, not an exemption from the rule.
- `Sbdev3017TrancheGateContextTest` adds two rows, and the size goes from 232 to 234 with a provenance comment.

**Tests**
- `LocationDefaultBoundsEndpointContractUnitTest` is keyed on `@PostMapping` path, not on the handler name (CLAUDE.md rule).
- No `never()` overload or varargs trap: `createUnitload((String) any(), any(), any(), any(), (String) any())` resolves to the 5-arg `(String, Location, Long, Long, String)` overload (`UnitloadService:238`), which is the one create calls. `requestForItem(Long)` is boxed, so `any()` is safe.
- Value assertions use `isEqualByComparingTo`. AC-14 key-set tests are paired with value tests (LOCATION, SYSTEM, SYSTEM_INVALID, out-of-date true/false/overridden).
- AC-5b's `NOT_SUPPORTED` test is meaningful. Without the service's own `@Transactional`, the interface `@Modifying` query has no transaction and throws.

**Logging and comments**
- Every new `LOG` call is SLF4J-parameterised. The labels name their own method (`resetBoundsToDefault`, `updateBoundDefaults`), and no label carries another method's name.
- Comment density matches the surrounding SBDEV-tagged code. The stale D-5 comments are fixed.

**No other FLA bound writers.** `git grep '.set(Lower|Middle|Upper)bound('` in `src/main` hits only `FixLocationAssignmentService`, so nothing else can leave `bounds_inherited` stale.

## Positive observations
- The D9 probe design is executed cleanly. The one-instrument read happens inside each method, with no cache. The legacy path is genuinely untouched, and the unit tests prove it.
- The `== 1` guards plus PG ITs with paired negative and positive controls make every predicate mutant visible, in both the unit lane (SQL-text pins) and the PG lane.
- `CreateEditRace` measures AC-17 serialization in both orders with `HeldRowLockRace`, not by assertion of intent.
- The mirrored-scan-order backfill test (`backfill_lowestClientIdWins_mirrored`) exists because a mutant survived the first version. That is good mutation discipline.
