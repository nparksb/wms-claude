---
name: wms-tdd-gate
description: Create the per-ticket git worktree off freshly-fetched origin/develop, then write failing tests from a reviewed WMS plan's acceptance criteria, confirm they fail for the right reason, and pause for human approval before implementation starts. Normally invoked automatically as the final phase of wms-bugfix-plan / wms-feature-plan; can also be run standalone against an approved plan from an earlier session. BEFORE this skill: run `wms-triage` for the tier verdict — it decides how much of this skill runs, and often ends the task instead.
version: 1.1.0
---

# WMS TDD Gate

## Tier gate — is this skill even the right tool?

**This skill is for T2/T3 work** (tier assigned by the `wms-triage` skill, which owns the router). It creates a git worktree, writes tests from a plan document, and pauses for approval — worth it when the fix spans files or is irreversible, and pure overhead for a one-file change.

- **T0/T1: do not invoke this skill.** Write the failing test inline in the existing test class, confirm it fails for the right reason, mutation-check it, then implement. The floor is satisfied; a worktree and a gate session are not.
- **T2/T3: invoke it.** Everything below applies.

**The floor applies either way** — a failing test that fails for the *right* reason, and mutation-checked. What this skill adds beyond the floor is the worktree, the plan-to-test mapping, and the human checkpoint.

⚠ **A new method's contract cannot be expressed in compiling Java before the method exists.** On SBDEV-3011 the behavioural tests could not compile until `deleteRole` had a signature, and adding them would have broken compilation for the whole module — destroying the one gate that did work. The resolution: write a **reflection-based contract test** first (it compiles today and fails correctly), and defer the behavioural tests to the executor's first commit, once the signatures land. Precedents: `unit/repo/OnHandQueryContractUnitTest`, `unit/repo/AdviceRepositoryRestExportUnitTest`.

⚠ **A reflection test that `for`-eaches over `getDeclaredMethods()` is vacuous when the list is empty.** Measured: gutting the interface under test left 13/13 green. Assert the declared SET first, keyed on **name + parameter count** — a name-only key collapses overloads and still misses partial removal. Then mutation-check it.


Bridges plan review and implementation. Given a critic-approved plan, writes the minimum failing tests that encode the plan's acceptance criteria, validates they fail correctly, and presents a baseline report for human approval. Implementation does not start until the user explicitly signs off.

## Trigger

```
/wms-tdd-gate <path-to-plan-file>
```

Two entry paths, both valid:

- **Chained (the normal path).** `wms-bugfix-plan` / `wms-feature-plan` invoke this skill automatically as their final phase, once the plan is saved and `verify-<plan-id>.sh` exists. The plan is already in context — still re-read §0 / §3 / §8 from the file rather than working from memory of the drafting conversation, so the tests encode what was actually written to disk.
- **Standalone.** A human runs `/wms-tdd-gate <path>` against an already-approved plan from an earlier session.

Either way the plan must have passed ralplan Critic sign-off and its Layer 2 completeness checklist before this skill runs. If it hasn't, stop and say so — do not gate a draft.

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

## Step 2 — Branch precondition, then map to test classes

### 2a. Create the worktree BEFORE writing any file

Plans live in `sbdocs/` (not git), but this skill writes Java into `v1/wms-api` or `v2/wms2-api` — real repositories. On the chained path nothing has touched git yet, and this skill is the first thing that does.

Tests go into a **dedicated per-ticket worktree**, never the main checkout — the same worktree `wms-plan-executor` will implement in, so the gate tests and the production code share one branch and one tree.

1. Read the branch name from the plan (§5 Implementation Steps / §5 Phased Implementation Plan / §8 Rollout — for phased plans use the **Phase 1** branch). If the plan names none, derive one matching the repo's own prefixes (`feature/`, `bugfix/`, `fix/`, `task/`), defaulting to `feature/<plan-id>`.
2. Create or reuse the worktree at `.claude/worktrees/<repo-dir-name>/<TICKET>` (bare ticket id, e.g. `SBDEV-2778`; for an untracked plan use the plan-id date-slug):
   ```bash
   MONO=/home/nampark/dev/wms-claude
   REPO=v2/wms2-api; TICKET=SBDEV-####; BRANCH=<from the plan>
   WT="$MONO/.claude/worktrees/$(basename "$REPO")/$TICKET"
   git -C "$MONO/$REPO" fetch origin
   git -C "$MONO/$REPO" worktree list                                    # reuse if it already exists
   git -C "$MONO/$REPO" worktree add -b "$BRANCH" "$WT" origin/develop   # else create
   cd "$WT" && git status --short && git branch --show-current
   ```
3. Base is **freshly-fetched `origin/develop`** unless the plan says otherwise. The worktree must be clean at creation.
4. **Never write tests onto `develop` or `main`, and never into the main checkout** — leave `v{1,2}/wms-api` on whatever branch the user left it on, dirty or not. If an existing worktree for this ticket is dirty, or the base looks wrong, stop and ask.
5. Every path from here on — test files, `mvn`, `grep` for existing test classes — resolves under `$WT`, not `v{1|2}/wms-api`. `sbdocs/` paths stay at the monorepo root. State the absolute worktree path in the baseline report so the executor picks up the same tree.

### 2b. Map criteria to test classes

For each service in §0:

1. Grep for an existing test class:
   ```bash
   grep -rln "class <ServiceName>.*Test" "$WT/src/test/"
   ```
2. If found: read the class header + existing `@Test` method names (targeted `offset+limit` read) to understand mocks, setup, and naming conventions in use.
3. If not found: create a new test class at the path below.

**Test class paths** — all relative to `$WT` (the worktree), *not* to `v{1,2}/wms-api`:

| Type | Path under `$WT` |
|---|---|
| v1 unit | `src/test/java/net/aim_ai/wms/unit/service/<ServiceName>UnitTest.java` |
| v1 integration | `src/test/java/net/aim_ai/wms/service/<ServiceName>IT.java` |
| v2 unit | `src/test/java/net/aim_ai/wms/unit/service/<ServiceName>UnitTest.java` |
| v2 integration | `src/test/java/net/aim_ai/wms/service/<ServiceName>IT.java` |

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
cd "$WT" && mvn test -Dtest=<ClassName>#<method1>+<method2> 2>&1 | tail -60
```

Classify each result:

| Result | Verdict | Action |
|---|---|---|
| Fails with `AssertionError` / `expected: X but was: Y` | **Correct failure** — gate ready | Record and present |
| Fails with `NullPointerException` in Arrange block | **Setup problem** | Fix the mock setup; re-run |
| Fails with compile error | **Broken scaffolding** | Fix compilation; re-run |
| Unexpectedly passes | **Test too weak or behavior already exists** | Investigate — check if the plan's fix is already partially in place; tighten the assertion or report the discrepancy |

Do not proceed to Step 5 until every new test is in the "Correct failure" column.

### Also capture the verify-script baseline (chained path)

The plan ships with `sbdocs/9-System/scripts/verify-<plan-id>.sh`. Run it once here, against the unfixed build:

```bash
bash sbdocs/9-System/scripts/verify-<plan-id>.sh 2>&1 | tail -20
```

**Only if the plan has a verify script** — T2 and below no longer produce one; their assertions live in JUnit/Jest, which is the preferred home (see *Row hygiene* in `wms-triage`). If there is no script, skip this step and say so.

Expect failures — that is the point. **If it reports `Result: N pass, 0 fail` before any production code changed, the script is asserting nothing** (usually filename-level checks instead of call-site regexes). Flag it in the Step 5 report and tighten it now; a verify script that cannot fail cannot later prove the work was done. This is the same trap that let a plan score 57 pass / 0 fail on a build that still contained the defect it was written to catch.

---

## Step 5 — Checkpoint (pause OR auto-proceed)

**On the chained path this is the only human checkpoint between plan approval and production code being written.** The plan→gate boundary was deliberately removed (a separate "shall I run the gate?" prompt re-approved a decision already made at ralplan Critic sign-off), so the pause below carries the whole weight. Bias toward pausing: the auto-proceed criteria are a narrow exemption for genuinely small changes, not the default.

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

Branch:   <repo>@<branch> (off freshly-fetched origin/develop)
Worktree: <absolute path — the executor must implement in this same tree>

### Tests written
| Test class | Method | Criterion |
|---|---|---|
| <ClassName> | <methodName> | <one-line criterion from §8> |

### Failure output (excerpt)
<paste the key assertion failure lines — not the full Maven log>

### Verify-script baseline
<paste the `Result: N pass, M fail` line from `bash sbdocs/9-System/scripts/verify-<plan-id>.sh`>
<!-- Chained path only. M must be > 0 — a verify script that already passes on the
     unfixed build is asserting nothing. If M == 0, say so loudly: the script needs
     tighter call-site regexes before implementation starts. -->

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

When the user approves, hand off to **`wms-plan-executor`** — it owns the implementation loop, code review, commit, PR, and ClickUp update. Do not implement here.

1. State the run command that defines completion:
   ```bash
   cd "$WT" && mvn test -Dtest=<ClassName>
   ```
   Target the **class**, not `<Class>#<method>` — the method form silently runs zero tests on `@Nested` classes and reports success.
2. Pass this as the completion criterion:
   > "Implementation is complete when this command exits 0 with all N tests passing, and `verify-<plan-id>.sh` reports `Result: N pass, 0 fail`."
3. Invoke `Skill("wms-plan-executor", "<path-to-plan-file>")`, **passing the absolute worktree path** so it reuses this tree instead of creating a second one — the gate tests live here and nowhere else. If the user stops and resumes in a fresh session, the executor re-discovers it via `git worktree list`. The tests and the verify script are the two contracts the executor must satisfy — it may not weaken either.
4. Remind: the **full** suite (`mvn test`) runs only after the targeted tests pass, and its failures get compared against the pre-existing baseline, not read as new regressions.

---

## Non-negotiable rules

1. **Tests must compile before Step 4.** A test that fails to compile is not a failing test — it is broken scaffolding. Fix it before running.
2. **Never write tests that always pass.** A test that passes before the fix is not a gate — it is false confidence.
3. **Do not implement the fix in this step.** If you find yourself editing a service class, stop immediately.
4. **Do not run the full test suite.** Only run the tests you wrote. Pre-existing failures are outside scope.
5. **Do not proceed past Step 5 without explicit user approval — unless auto-proceed criteria are met.** See Step 5 for the four conditions. When in doubt, pause.
6. **If the plan has no acceptance criteria**, stop at Step 1 and ask for them. A TDD gate without criteria is just test theater.
7. **Never write a test file before Step 2a passes.** Not on `develop`, not on `main`, and never in the main checkout — tests belong in the per-ticket worktree. On the chained path this skill is the first thing that touches a real git repo, so it owns creating that worktree.

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
