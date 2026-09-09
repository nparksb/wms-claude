---
title: SBDEV-3241 review — SequenceTransactionServiceUnitTest repair (16 tests)
ticket: SBDEV-3241
reviewer: review-3241-seq (independent lane)
date: 2026-09-07
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3241-seq
branch: bugfix/SBDEV-3241-sequence-tx-tests (base origin/develop @ 7d59e1da)
scope: uncommitted working-tree change, 1 file
verdict: APPROVE — repair is the correct call and is proven by git history. 0 High. 5 Medium, 7 Low.
---

# SBDEV-3241 — review of the `SequenceTransactionServiceUnitTest` repair

Read-only review. No git state touched, no Maven invoked. Everything below is derived from
`git diff`, `git show`, `git log`, file reads and greps in the worktree above.

---

## 0. Verdict

**Approve the change as written.** The two headline questions both resolve cleanly in favour of
repair:

- **Q1 — repair or superseded? REPAIR.** Proven, not inferred: the method body is byte-identical
  to its February 2025 form apart from one line. Nothing these tests assert was ever superseded.
- **Q2 — did retargeting invert any test's purpose? NO.** All 17 sites were `when(...)` stubs.
  No test in the class ever verified *which* finder was called, so nothing could invert.

The findings below are all improvements to tests that are now green and correct — none of them
block the change. Two tests I recommend **deleting** (§F1, §F2), one family of five I recommend
**collapsing to one parameterized test** (§F3). That takes the file from 16 tests to ~10 without
losing a single distinct property.

---

## 1. Q1 — is "repair" right, or are some of these superseded?

**Repair is right, and the evidence is decisive.**

`git show c43e6e61:src/main/java/net/aim_ai/wms/service/SequenceTransactionService.java`
(11 Feb 2025, the commit that created the class) against HEAD: the two bodies are identical except
for line 28. Every value-producing statement — `Long returnSeq = 0L`, `curSeq + 1` twice, the
`isPresent()` branch, `setClassname(key)`, `setSequencenumber(returnSeq)`, `save(seq)`,
`return returnSeq` — is unchanged. The only delta ever applied is commit `7316ddb5`:

```
-        Optional<LosSequencenumber> seqOpt = losSequencenumberRepository.findByClassname(key);
+        // Pessimistic lock eliminates optimistic retry storms under concurrent load
+        Optional<LosSequencenumber> seqOpt = losSequencenumberRepository.findByClassnameForUpdate(key);
```

A change that touches only the finder cannot have changed the value contract. So **no test in this
class can be encoding a pre-SBDEV-2217 contract** — the contract they assert (present → `curSeq+1`;
absent → create a row at `0` and return `0`) is the contract on `origin/develop` today, at
`SequenceTransactionService.java:24-41`. Retargeting the stubs is the whole and correct fix.

### 1.1 The `@Disabled` markers were factually wrong — deleting them is correct

Both deleted markers claimed *"closed SBDEV-2217 is about `getNextSequenceNumber()` returning -1."*
It is not about **this** class. `7316ddb5`'s own commit message, Phase 1, bullet 2:

> Fix silent -1 return in **BasicService**.getNextSequenceNumber (now throws)

The `-1` is the retry-loop sentinel in `BasicService.java` (`long nextSeq = -1;` … `while (nextSeq < 0
&& tries < maxTries)` … `throw new BusinessException("BusinessException.SequenceExhausted", …)`).
`SequenceTransactionService` has never contained a `-1` in any revision. That contract is already
pinned, in the right place, by `BasicServiceUnitTest` — nested `SadPath`,
`shouldThrowWhenSequenceServiceExceedsMaxRetries` (asserts `BusinessException` +
`verify(…, times(5))`) and nested `GetNextSequenceNumber`, `shouldRetryOnOptimisticLockingFailure`.

So the "these may be superseded" warning was a false alarm built on a class mix-up. Removing the
markers rather than acting on them is the right outcome.

### 1.2 The four tests called out for scrutiny

| Test | Deliberate or coincidental? | Verdict |
|---|---|---|
| `shouldReturnZeroWhenSequenceDoesNotExist` | Deliberate as to intent, but its **assertion** is satisfied by the mock's default answer — see §F4 | Keep, strengthen |
| `shouldCreateNewSequenceWhenNotFound` | Deliberate and real — the captor pins `classname == "NEW_KEY"` and `sequencenumber == 0L`, which no default answer produces | Keep as-is |
| `shouldHandleNegativeSequenceNumbers` | Deliberate. `-10 → -9` is genuinely current behaviour: this service does not validate. The guard is one layer up (`BasicService`: `if (n < 0) throw BusinessException("BusinessException.SequenceInvalid", key, n)` at four call sites) | Keep; §F11 suggests a one-line comment |
| `shouldHandleConcurrentAccessSimulation` | Simulates **nothing**. One thread, a mock, no lock, no transaction — and it is a verbatim duplicate of another test | **Delete** — §F2 |

---

## 2. Q2 — did retargeting change what any test means?

**No.** Two independent checks:

1. `grep -n "findByClassname(" <test file>` after the change returns **zero** hits, and there was
   never a `verify(losSequencenumberRepository).findByClassname(...)` anywhere in the class — all 17
   sites in the pre-change file were `when(...)` stubs (visible in the diff: every `-` line is a
   `when(`). A stub is a precondition, not an assertion of intent. Nothing was asserting "the
   non-locking read is used", so nothing inverted.
2. The non-locking `findByClassname` is **not** orphaned by this change and did not need a pin here.
   It remains a live production method with a real caller — `LabelPrintingService.java:968` — plus a
   test-fixture use in `SequenceTransactionServiceConcurrencyIT.java:107` (seed block). Its
   declaration stands at `LosSequencenumberRepository.java:22-23`.

---

## 3. Q3 — PIT says 7/7 killed. What does that actually establish?

**It is real but narrow, and it does not cover either of the two things SBDEV-2217 changed.**

`pom.xml:534-557` configures the pitest plugin with **no `<mutators>` element**, so PIT 1.19.1 runs
the `DEFAULTS` group. Against a 17-line method the mutable surface is small and enumerable:

| # | Mutator | Site |
|---|---|---|
| 1-2 | `MATH` | `curSeq + 1` at lines 32 and 33 |
| 3 | `NEGATE_CONDITIONALS` | `seqOpt.isPresent()` at line 29 |
| 4-6 | `VOID_METHOD_CALLS` | `seq.setSequencenumber(curSeq+1)` (32), `seq.setClassname(key)` (36), `seq.setSequencenumber(returnSeq)` (37) |
| 7 | return-value mutator | `return returnSeq` (40) — boxed `Long`, so `NULL_RETURNS`/`EMPTY_RETURNS` apply |

That accounts for the reported 7, and the shape of it is the point:

**What 7/7 KILLED does establish.** The `+1` arithmetic in both places, the present/absent branch
selection, and the in-place mutation of the entity are each pinned by an assertion that fails when
broken. For those three behaviours the tests are genuinely load-bearing.

**What it does not establish — and this is the larger half:**

- **It does not pin the repository-method choice.** `DEFAULTS`' `VOID_METHOD_CALLS` removes calls to
  **void** methods only. Both repository calls return values —
  `findByClassnameForUpdate(key)` returns `Optional<…>` and `save(seq)` returns `S` — so **PIT
  generated no mutant for either line**. Removing or swapping the finder is not in the mutant set at
  all. Answering the question directly: **no, PIT would not catch a revert from
  `findByClassnameForUpdate` back to `findByClassname`.** Something else catches it — see §F5.
- **It does not touch the pessimistic lock.** `@Lock(LockModeType.PESSIMISTIC_WRITE)` lives on a
  different type (`LosSequencenumberRepository.java:25`), outside the `targetClasses` scope, and is
  an annotation on an interface method — unmutatable in any scope.
- **It does not touch the transaction boundary.** `@Transactional(value = "tenantTransactionManager",
  propagation = Propagation.REQUIRES_NEW)` at line 23 is an annotation; PIT does not mutate
  annotations. Independently, this class is *structurally* blind to it: `@InjectMocks` constructs the
  bean directly, so no Spring proxy exists and neither the propagation nor the transaction-manager
  qualifier is exercised. Flipping `REQUIRES_NEW` to `NOT_SUPPORTED` or dropping the
  `tenantTransactionManager` qualifier would leave all 16 green.
- **It does not establish that anything reaches a database.** Every persistence claim in the file is
  a claim about a mock.

**Is 100% weak evidence because the class is small?** It is *narrow* rather than weak. The honest
one-liner: *"the 17 lines of arithmetic and branching in `getNextSequenceNumber` are covered by
assertions, not by execution alone."* It is not evidence that the SBDEV-2217 fix — the lock and the
`REQUIRES_NEW` boundary — is protected. That protection lives in
`SequenceTransactionServiceConcurrencyIT` (50 threads × 100 calls, distinctness + monotonicity +
`MAX == seed + 5000` + a contention proof), and nowhere in this unit class.

---

## 4. Findings

Severity-rated, highest first. No High findings — the change is correct.

### F1 — MEDIUM — `shouldPersistChangesToDatabase` is near-vacuous on two counts; recommend DELETE

Lines 205-221. Three defects compounding:

1. **`isEqualTo` is not identity here.** `LosSequencenumber.equals()`
   (`model/LosSequencenumber.java:48-53`) compares **classname only**:
   `return getClassname() != null && getClassname().equals(other.getClassname());`
   So `assertThat(captor.getValue()).isEqualTo(testSequence)` passes for *any*
   `LosSequencenumber` whose classname is `"TEST_KEY"`. The assertion reads as "the exact object was
   saved" and is not that.
2. **The fixture is incoherent.** It stubs the key `"PERSIST_KEY"` but the entity handed back is the
   `@BeforeEach` `testSequence`, whose classname is `"TEST_KEY"`. The test therefore asserts that a
   row named `TEST_KEY` was saved in response to a lookup of `PERSIST_KEY`, and passes.
3. **It does not assert the change its name promises.** "should persist **changes** to database" —
   it never checks the captured entity's `sequencenumber` is `101L`. The mutation it is named for is
   asserted by a *different* test (`shouldUpdateSequenceNumberInDatabase`, line 77).

It is a strictly weaker duplicate of `shouldReturnIncrementedSequenceWhenSequenceExists` +
`shouldUpdateSequenceNumberInDatabase`. **Delete it**, or if kept, replace the assertion with
`assertThat(captor.getValue().getSequencenumber()).isEqualTo(101L);`.

*Related, Low:* the same `equals()`-by-classname caveat applies to
`verify(losSequencenumberRepository).save(testSequence)` at line 61 — Mockito argument matching goes
through `equals()`, so that verify is also "a row named TEST_KEY", not "this object".

### F2 — MEDIUM — `shouldHandleConcurrentAccessSimulation` simulates nothing, duplicates another test, and ends in two tautologies; recommend DELETE

Lines 331-351 against lines 116-134 (`shouldHandleMultipleIncrementsCorrectly`): same three
sequential calls, same shared mutable `testSequence`, same `101/102/103` expectations. The **only**
difference is the key string (`"CONCURRENT_KEY"` vs `"TEST_KEY"`) and two extra assertions:

```java
assertThat(result1).isNotEqualTo(result2);
assertThat(result2).isNotEqualTo(result3);
```

These **cannot fail**. AssertJ assertions are hard, not soft, so control reaches line 349 only if
lines 346-348 have already pinned the three values to 101, 102 and 103 — at which point
`101 != 102` is a tautology. They add no discriminating power.

And the name is the real cost. There is one thread, a Mockito mock, no lock and no transaction; the
service's own comment at line 27 and the `@Lock`/`REQUIRES_NEW` pair are entirely bypassed. The
genuine concurrency proof exists and is properly named —
`integration/service/SequenceTransactionServiceConcurrencyIT` ("SBDEV-2217 AC-4"). Leaving a test
called "concurrent access simulation" in the unit class invites the belief that concurrency is
unit-covered. **Delete it.**

### F3 — MEDIUM — the five key-shape tests are five copies of one property; two of them assert a contract that is false in production

`shouldHandleNullKeyGracefully` (230), `shouldHandleEmptyStringKey` (246),
`shouldHandleVeryLongKeyNames` (262), `shouldHandleSpecialCharactersInKey` (279),
`shouldHandleUnicodeCharactersInKey` (296) are identical modulo the key literal.

**Do they test the service or Mockito?** They test *one* real property, and it is thinner than it
looks: the service passes `key` through to the finder **unmodified** — no trim, no upcase, no
normalisation. If it normalised, the exact-value stub would miss and STRICT_STUBS would fail the
test. That property is real. But it is **one** property needing **one** `@ParameterizedTest` with a
`@ValueSource`, not five methods; and note carefully (per §F4) it is enforced by the *stubbing
strictness*, never by the `isEqualTo(0L)` assertion each test actually writes.

Two of the five additionally assert something that would not hold against a real database:

- **null key.** `los_sequencenumber.classname` is
  `character varying(255) NOT NULL` and is the primary key
  (`V2.2.00__base_v2_schema.sql:1358-1362` and `:3396`
  `ADD CONSTRAINT los_sequencenumber_pkey PRIMARY KEY (classname)`). With `key = null` the service
  takes the else branch, does `seq.setClassname(null)` and `save(seq)` — a null-PK insert, not a
  graceful `0`. The test passes only because `save` is stubbed to echo its argument. The DisplayName
  *"should handle null key gracefully"* reads as a safety guarantee that does not exist.
- **1004-character key.** `"KEY_" + "A".repeat(1000)` into `varchar(255)` → `value too long for type
  character varying(255)`. Same false-contract shape.

**Action:** collapse empty / special-chars / unicode into one parameterized test asserting
pass-through; delete the null and long-key cases, or rename them to state what they actually record
("passes a null key through unchanged", "does not truncate long keys") so nobody reads them as
evidence that null or 1004 chars are safe.

### F4 — MEDIUM — six of sixteen tests have an explicit assertion that the mock's default answer already satisfies

Mockito's default answer for an `Optional`-returning method is `Optional.empty()`, not `null`. So
for every test whose stub returns `Optional.empty()`, the service would take the else branch and
return `0L` **even if it never called the finder at all**. Their written assertion
(`assertThat(result).isEqualTo(0L)`) therefore cannot distinguish "called the locking finder, got
empty" from "called nothing".

Affected: `shouldReturnZeroWhenSequenceDoesNotExist` (line 93) and all five key-shape tests
(241, 257, 274, 291, 308).

What keeps them honest is a **side effect, not an assertion**: the unused stub would trip
`UnnecessaryStubbingException` under STRICT_STUBS. That is exactly the mechanism that broke them in
the first place, and it fails with a stubbing error rather than a named expectation.

`shouldCreateNewSequenceWhenNotFound` (line 98) is the counter-example and the model to follow — its
captor pins `classname == "NEW_KEY"` and `sequencenumber == 0L`, which no default answer produces.
Adding `verify(losSequencenumberRepository).findByClassnameForUpdate(<key>)` to the survivors of
§F3 would close this at one line each.

### F5 — MEDIUM — the lock choice is protected only incidentally, by an error type rather than an assertion

Combining §3 and §F4: if someone reverts `SequenceTransactionService.java:28` to `findByClassname`,
all 16 tests do go red — but via `UnnecessaryStubbingException` plus wrong-value failures, i.e.
*precisely* the failure signature that got this class written off. Four archived plan docs record
the consequence: these were logged as "pre-existing failures … unrelated" for roughly five months
(`docs/plan/260331-…:265`, `docs/plan/260401-…:278`, `docs/plan/260407-…:362`,
`docs/plan/Run_Club_Availability_Exception_Analysis_2026-04-05.md:420`) before being `@Disabled`
outright. An obscure failure mode is how a real regression gets reclassified as noise.

PIT cannot help here (§3: no mutant is generated for either repository call). **Recommendation** —
two lines in the happy-path test, converting an incidental stubbing error into a named failure:

```java
verify(losSequencenumberRepository).findByClassnameForUpdate("TEST_KEY");
verify(losSequencenumberRepository, never()).findByClassname(any());
```

The `never()` line is worth having specifically because `findByClassname` is still on the interface
and still used elsewhere (`LabelPrintingService:968`), so an accidental revert compiles cleanly.
(The `never()` + `any()` primitive-unboxing trap does not apply — the argument is a `String`.)

### F6 — MEDIUM (propose, do not file, do not fix here) — the not-found branch these tests bless is one the project's own IT documents as broken, and the pessimistic lock does not cover it

Out of scope for SBDEV-3241 — recorded because two tests now assert it as though it works.

`SequenceTransactionServiceConcurrencyIT.java:101-103` says so in as many words:

> Seed a row with version=0 so `SequenceTransactionService` takes the `seqOpt.isPresent()` branch
> (increment+save) and **never hits the new-key insert path (which would fail under @Version
> constraint)**.

The cause is on the entity: `LosSequencenumber.java:11-18` puts
`@GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "losSequenceNumber_gen")` on a
**String** `classname` id — the IT works around it with a native `INSERT` (`:116-119`).

Separately, and independent of that: `SELECT … FOR UPDATE` matching **no row locks nothing**. So the
lock added by SBDEV-2217 does **not** serialise first-ever allocation for a new key — two racing
callers both see empty, both return `0`, and one insert loses. In practice this is masked because
every key is seeded at migration time (`V2.2.00__base_v2_schema.sql:2559` ff:
`('PICKING_ORDER', 0, 0)`, `('REPLENISH_ORDER', 0, 0)`, ~20 rows), which makes the else branch
effectively dead in any migrated tenant.

Six unit tests exercise that branch and all pass solely because the repository is a mock:
`shouldReturnZeroWhenSequenceDoesNotExist`, `shouldCreateNewSequenceWhenNotFound`, and the five
key-shape tests. Per the ticket policy this is T3-shaped (data integrity, service design) and
belongs on **no** ticket until Nam confirms: **propose only.**

### F7 — LOW — `shouldHandleVeryLargeSequenceNumbers` stops one step short of the boundary that matters

Line 166. It uses `Long.MAX_VALUE - 2 → Long.MAX_VALUE - 1`. The interesting boundary is
`Long.MAX_VALUE` itself, where `curSeq + 1` silently overflows to `Long.MIN_VALUE`; the service
returns it unguarded, and `BasicService` then throws
`BusinessException("BusinessException.SequenceInvalid", …)` on `n < 0` at each of its four call
sites. Neither the overflow nor the downstream guard is covered. Practically unreachable —
`bigint` would need ~10^19 allocations — hence Low, but it is two cheap lines while the file is open.

### F8 — LOW — `when(save(...)).thenReturn(...)` is dead weight in six tests

The service discards `save`'s return value (line 39), so `.thenReturn(testSequence)` /
`.thenReturn(largeSeq)` / `.thenReturn(zeroSeq)` / `.thenReturn(negativeSeq)` configure a value
nobody reads. They are *invoked*, so STRICT_STUBS is satisfied, but they imply the return matters.
Dropping the `when(...)` entirely works for these six. The `thenAnswer(inv -> inv.getArgument(0))`
cases are different and must stay — the ArgumentCaptor tests genuinely need the echo.

### F9 — LOW — `shouldHandleMultipleIncrementsCorrectly` accumulates through a shared mutable fixture

Lines 116-134. It gets `101/102/103` because all three calls receive the same `testSequence`
instance and the service mutates it in place. That is legitimate and it does pin real behaviour, but
it is a property of the mock's object identity as much as of the service; a reader can mistake it
for evidence about persistence. A one-line comment ("the stub returns the same instance each call,
so increments accumulate in memory") would remove the ambiguity. Keep the test.

### F10 — LOW — stale-marker sweep is clean, with one out-of-file residue that should be left alone

`grep -n "2099\|3241\|Disabled\|2217\|findByClassname("` over the changed file returns **nothing**.
Both `@Disabled` blocks are gone, the `Disabled` import is gone (the import list at lines 7-10 is now
exactly the used set — verified against usage), no comment or javadoc mentions the disabled state,
SBDEV-2099, SBDEV-2217, or the old method name. The class javadoc (lines 21-24) was generic and
remains accurate. Nothing else in the repo references these nested classes or gates on their
disabled state (checked across `*.java`, `*.md`, `*.sh`, `*.xml`).

The four archived plan docs named in §F5 still describe these as "pre-existing failures … unrelated".
Those are historical records of past test runs and were true when written — **do not rewrite them.**
Informational only.

### F11 — LOW — `shouldHandleNegativeSequenceNumbers` would benefit from naming where the guard lives

Line 313, asserting `-10 → -9`, correctly records that *this* service performs no validation. The
name "should handle negative sequence numbers" can read as "negatives are acceptable". One comment
pointing at `BasicService` (`if (n < 0) throw new BusinessException("BusinessException.SequenceInvalid",
key, n)`) makes the layering explicit. Keep the test.

### F12 — LOW — no test in the file, and none in the suite outside the IT, pins the transaction boundary

Per §3: `@Transactional(value = "tenantTransactionManager", propagation = REQUIRES_NEW)` at
`SequenceTransactionService.java:23` is invisible to `@InjectMocks`. Both halves matter here — the
`REQUIRES_NEW` is what makes each allocation commit independently of the caller's transaction (the
whole point of the retry loop above it), and the `tenantTransactionManager` qualifier is what routes
it to the tenant datasource rather than the landlord. A silent removal of either would leave this
class 16/16 green. Not a defect in this change, and correctly the IT's job — but worth stating
plainly so the 100% PIT number is not read as covering it.

---

## 5. Delete-vs-repair recommendation

The user chose repair and repair is correct. Within that, a well-evidenced case for trimming:

| Test | Recommendation | Basis |
|---|---|---|
| `shouldHandleConcurrentAccessSimulation` | **DELETE** | Verbatim duplicate of `shouldHandleMultipleIncrementsCorrectly`; two tautological assertions; name claims coverage that lives in `SequenceTransactionServiceConcurrencyIT` (§F2) |
| `shouldPersistChangesToDatabase` | **DELETE** | Passes on classname-only `equals()`, incoherent fixture, never asserts the change it is named for; strictly weaker duplicate (§F1) |
| `shouldHandleNullKeyGracefully` | **DELETE or RENAME** | Asserts graceful handling of a null PK against a `NOT NULL` primary key (§F3) |
| `shouldHandleVeryLongKeyNames` | **DELETE or RENAME** | 1004 chars into `varchar(255)` (§F3) |
| `shouldHandleEmptyStringKey`, `shouldHandleSpecialCharactersInKey`, `shouldHandleUnicodeCharactersInKey` | **COLLAPSE to one `@ParameterizedTest`** | Three copies of one pass-through property (§F3) |
| the other 10 | **KEEP** | Each pins a distinct, current behaviour |

Net: 16 → ~10 tests, no property lost, plus the two `verify` lines from §F5 that actually pin the
SBDEV-2217 lock. All of this is optional follow-up; none of it blocks the change under review.

## 6. What I did not verify

- Did not run Maven or PIT (a full suite is running in this worktree). The pre/post-fix counts and
  the 7/7 PIT result are taken as given; §3 analyses what that number can mean, using the mutator
  set derivable from `pom.xml`, not a re-run.
- Did not execute any test to confirm the six default-answer claims in §F4; they follow from
  Mockito's `ReturnsEmptyValues` behaviour for `Optional` return types plus the service source.
- Did not query a database. The `varchar(255) NOT NULL` / PK claims come from
  `V2.2.00__base_v2_schema.sql`, not from a live schema.
