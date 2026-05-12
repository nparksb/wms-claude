---
name: wms-tdd-gate
description: Write failing tests from a reviewed WMS plan's acceptance criteria, confirm they fail for the right reason, and pause for human approval before implementation starts.
version: 1.0.0
---

# WMS TDD Gate

Bridges plan review and implementation. Given a critic-approved plan, writes the minimum failing tests that encode the plan's acceptance criteria, validates they fail correctly, and presents a baseline report for human approval. Implementation does not start until the user explicitly signs off.

## Trigger

```
/wms-tdd-gate <path-to-plan-file>
```

Invoke after critic sign-off on a `wms-bugfix-plan` or `wms-feature-plan` output. The plan must have passed its Layer 2 completeness checklist before this skill runs.

---

## Step 1 — Parse the plan

Read the plan file. Extract:

- **`target_version`** from frontmatter (`v1` or `v2`)
- **§0 Affected Sites** — which service/repository/controller files are in scope
- **§3 Fix Design** (bugfix) or **§3 Design** (feature) — the Before/After behavior for each fix
- **§8 Acceptance** or the companion verify script — the named acceptance criteria
- **`db_verified`** from frontmatter — note if `false`; those criteria may need integration tests

If the plan has no §0 table, §3 Fix Design, or §8 Acceptance section, stop and ask the user to complete the plan before running this gate.

---

## Step 2 — Map to test classes

For each service in §0:

1. Grep for an existing test class:
   ```bash
   grep -rln "class <ServiceName>.*Test" v{1|2}/wms-api/src/test/
   ```
2. If found: read the class header + existing `@Test` method names (targeted `offset+limit` read) to understand mocks, setup, and naming conventions in use.
3. If not found: create a new test class at the path below.

**Test class paths:**

| Type | Path |
|---|---|
| v1 unit | `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/<ServiceName>UnitTest.java` |
| v1 integration | `v1/wms-api/src/test/java/net/aim_ai/wms/service/<ServiceName>IT.java` |
| v2 unit | `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/<ServiceName>UnitTest.java` |
| v2 integration | `v2/wms2-api/src/test/java/net/aim_ai/wms/service/<ServiceName>IT.java` |

**Default to unit tests.** Only escalate to integration (Testcontainers) when the acceptance criterion requires real DB state — e.g., testing a native query's result set, testing `@Transactional` rollback, or testing a pessimistic lock race condition.

---

## Step 3 — Write failing tests

Write the minimum tests that encode the acceptance criteria. Rules:

### One test per criterion
Each `@Test` method maps to exactly one acceptance criterion from §8. If a criterion has multiple sub-cases, write one test per sub-case. Do not bundle criteria — if a bundled test fails, you cannot tell which criterion broke.

### Method naming
```
<methodUnderTest>_should<ExpectedOutcome>_when<Condition>
```
Examples:
- `assignStagingLane_shouldThrow_whenBatchIsFinished`
- `runClubLine_shouldNotReassignLane_whenBatchAlreadyAtOrderBatchClubRunFinished`
- `cleanupStaleBatches_shouldSkipBatch_whenConcurrentOptimisticLockException`

### The test must compile and fail at the assertion
- Setup (Arrange) must be valid — no NPEs in the setup block.
- The test fails because the production code does not yet implement the behavior, not because the test scaffolding is broken.

### v1 patterns (Java 8, Spring Boot 2.3.7, Mockito 3.3.3)

```java
@ExtendWith(MockitoExtension.class)
class CustomerorderBatchServiceUnitTest {

    @InjectMocks
    private CustomerorderBatchService service;

    @Mock
    private CustomerorderBatchRepository customerorderBatchRepository;

    // ... other mocks matching the service's @Autowired fields

    @Test
    void assignStagingLane_shouldThrow_whenBatchIsFinished() {
        // Arrange — reproduce the exact state from the plan's "Before" scenario
        CustomerorderBatch batch = new CustomerorderBatch();
        batch.setId(1L);
        // set state to finished — use WmsConstants, never magic numbers
        batch.setState(WmsConstants.State.FINISHED);
        when(customerorderBatchRepository.findById(1L)).thenReturn(Optional.of(batch));

        // Act + Assert
        BusinessException ex = assertThrows(BusinessException.class,
            () -> service.assignStagingLaneToOrderBatch(99L, 1L));
        assertThat(ex.getMessage()).contains("finished or cancelled");
    }
}
```

**v1 constraints:**
- No `mockStatic()` — Mockito 3.3.3 does not support it; restructure if needed
- No JPA association annotations — mock repositories directly
- Entity comparison by ID (`entity.getId()`), not `.equals()` (most v1 entities use reference equality)
- Use `WmsConstants.State.*` and `WmsConstants.SYSTEM_PROPERTY_*` — never magic numbers
- No `@Transactional` on test methods unless testing rollback behavior explicitly

### v2 patterns (Java 21, Spring Boot 3.5.x, Mockito 5.x)

Same unit test structure as v1 except:
- Jakarta namespace: `jakarta.persistence`, `jakarta.validation`, `jakarta.transaction`
- `AbstractBaseEntity.equals()` is ID-based and correct — can use `.equals()` in assertions
- `mockStatic()` available if needed
- For integration tests, extend the project's base integration test class and use `@Transactional(value = "tenantTransactionManager")`

---

## Step 4 — Run and validate failures

Run only the new tests:

```bash
cd v{1|2}/wms-api && mvn test -Dtest=<ClassName>#<method1>+<method2> 2>&1 | tail -60
```

Classify each result:

| Result | Verdict | Action |
|---|---|---|
| Fails with `AssertionError` / `expected: X but was: Y` | **Correct failure** — gate ready | Record and present |
| Fails with `NullPointerException` in Arrange block | **Setup problem** | Fix the mock setup; re-run |
| Fails with compile error | **Broken scaffolding** | Fix compilation; re-run |
| Unexpectedly passes | **Test too weak or behavior already exists** | Investigate — check if the plan's fix is already partially in place; tighten the assertion or report the discrepancy |

Do not proceed to Step 5 until every new test is in the "Correct failure" column.

---

## Step 5 — Checkpoint (pause OR auto-proceed)

### Auto-proceed criteria (ALL must be true to skip the pause)

1. **≤2 acceptance criteria** in §8
2. **No concurrency / security / transaction flags** — the plan does not touch `@Transactional`, advisory locks, optimistic/pessimistic locks, `SecurityConfiguration`, auth filters, or race-condition scenarios
3. **No unexpected passes** from Step 4 — every test failed for the right reason
4. **No setup adjustments** were needed in Step 4 (clean first run)

If ALL four are true: **skip the pause**, print the baseline report (see format below), and proceed directly to Step 6 (handoff to implementation).

If ANY is false: **pause**. Print the report and wait for "go" or equivalent. Do not write any production code.

### Baseline report format (print in both cases)

```
## TDD Gate Baseline — <plan-id>

### Tests written
| Test class | Method | Criterion |
|---|---|---|
| <ClassName> | <methodName> | <one-line criterion from §8> |

### Failure output (excerpt)
<paste the key assertion failure lines — not the full Maven log>

### Verdict
✓ <N> tests fail for the right reason (assertion failures)
⚠ <N> tests adjusted (setup fixes applied during gate)
✗ <N> unexpected passes — see notes below

### What these tests encode
<one sentence per test: what production behavior is missing that makes this test fail>

---
These tests are the implementation contract. When all of them pass, the plan's
acceptance criteria are satisfied.
```

If pausing, append: `Reply "go" to start implementation, or describe any adjustments needed.`
If auto-proceeding, append: `Auto-proceeding to implementation (≤2 criteria, no concurrency/security flags, clean failures).`

---

## Step 6 — Handoff on approval

When the user approves:

1. State the run command the executor should use to verify completion:
   ```bash
   cd v{1|2}/wms-api && mvn test -Dtest=<ClassName>#<method1>+<method2>
   ```
2. Pass this as the completion criterion to any implementation agent or executor:
   > "Implementation is complete when this command exits 0 with all N tests passing."
3. Remind: run the **full** test suite (`mvn test`) only after the targeted tests pass, to catch regressions.

---

## Non-negotiable rules

1. **Tests must compile before Step 4.** A test that fails to compile is not a failing test — it is broken scaffolding. Fix it before running.
2. **Never write tests that always pass.** A test that passes before the fix is not a gate — it is false confidence.
3. **Do not implement the fix in this step.** If you find yourself editing a service class, stop immediately.
4. **Do not run the full test suite.** Only run the tests you wrote. Pre-existing failures are outside scope.
5. **Do not proceed past Step 5 without explicit user approval — unless auto-proceed criteria are met.** See Step 5 for the four conditions. When in doubt, pause.
6. **If the plan has no acceptance criteria**, stop at Step 1 and ask for them. A TDD gate without criteria is just test theater.

---

## Quick reference — common WMS test patterns

### Asserting a BusinessException message
```java
BusinessException ex = assertThrows(BusinessException.class, () -> service.method(args));
assertThat(ex.getMessage()).contains("expected fragment");
```

### Verifying a repository save was called with specific state
```java
ArgumentCaptor<CustomerorderBatch> captor = ArgumentCaptor.forClass(CustomerorderBatch.class);
verify(customerorderBatchRepository).save(captor.capture());
assertThat(captor.getValue().getState()).isEqualTo(WmsConstants.State.FINISHED);
```

### Verifying no interaction after a guard
```java
// Guard should have thrown before reaching the repository
assertThrows(BusinessException.class, () -> service.method(args));
verify(customerorderBatchRepository, never()).save(any());
```

### Testing with sysprop values
```java
when(losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_SOME_KEY))
    .thenReturn("true");
```
