head: 92b22a8cb972ad817a84dd8fad93a597d48c57cb

## Code Review Summary: SBDEV-3381 review-fix commit `92b22a8c` (on top of `723e1ba0`)

**Verdict: APPROVE.** Every finding in scope is fixed except L7, which is only partly fixed (it was optional). The fix introduces no High or Medium defects. There are five new Low findings, all about test precision or sibling consistency.

**Scope:** `git show 92b22a8c`: 6 files, +315/−41. I read the fixtures behind every new test. I did not run mvn, PIT or LSP, as instructed. Compilation is being covered by the suite currently running in the worktree. So every "kills mutant X" below comes from reading the fixtures, not from running PIT.

**By severity (new findings):** CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 5

### Original findings

| # | Status | Evidence |
|---|---|---|
| **M1** | FIXED | **Waive:** `waiveReversal_shouldApplyOwnershipRule_ignoreCompletedSibling` puts completed A(2, `reversalWaived=false`) and B(1) on SU 3 at `UL_ON`. `ownsAllStock` runs before stamping, so the mutant `isReversalWaived`→`completedAt != null` sums A+B = 3 ≤ 3 and releases. The original sums 1 and keeps the lock. The mutant is killed.<br>**Complete:** `…whenACompletedSiblingSharesTheStockUnit` (T22e) has A(2) completed and B(2) on SU 4, leaving residue 2. The original share is 0, so it re-locks. The mutant's share is 2, and `2 > 2` fails, so it does not re-lock. Killed. B is still pending when the share is read, so B does not contaminate it.<br>Release is reachable with this fixture family: T22a and the new duplicate-id test both reach `NOT_LOCKED`. So neither test is vacuous. |
| **M2** | FIXED | The T22b comment now says "counting a PENDING sibling as waived flips it … 1 + 3 = 4 >= 2" and points to T22e for the completed case. That matches the fixture. |
| **L1** | FIXED | `validateWaiveInput` does `reason.trim()` and then `trimmedReason.isBlank()`, and a `"\u0001"` row was added to the parameterised test. If the check reverts to the raw `isBlank()`, `"\u0001"` gets past it and the row goes red.<br>Java vs the DB CHECK: `btrim(x)` with no argument strips only `' '`. An accepted value has had every char ≤ U+0020 trimmed off and is non-blank, so btrim can never reduce it to `''`. **No input passes Java and then fails the CHECK.** The reverse exists but is harmless: `"\u2003"` is refused by Java (`isWhitespace`) and would be accepted by the DB, so Java is stricter. The javadoc's claim is accurate. |
| **L2** | FIXED | Javadoc added on the `waiveLockRetained` field and at the `toDetailDto` site ("Recomputed LIVE … false for an EMPTY stock unit … Accepted: 0 such rows measured on PRD"). |
| **L3** | FIXED | The evict key is `TenantKeyBuilder.cacheKey(TenantContext.getCurrentTenant()) + ":" + KEY`, and cache name `"sysprops"`. Both match the `@Cacheable` on `SyspropService.getSysvalue:333` exactly.<br>The evict is also genuinely needed. `BaseRollbackIntegrationTest`'s `spring.cache.type=none` has no effect, because `CacheConfig:31-33` declares its own `@Profile("!redis") CacheManager`, and that makes the auto-configuration back off. Neither IT sets a `TenantContext`, so the service call and the teardown both resolve to `"no-tenant:…"`, which is consistent. See N4 for the missing positive control. |
| **L4** | FIXED | The contract test now filters on `@PostMapping` `value`/`path` containing `"/{customerOrderId}/waive"`, and asserts the arity separately. |
| **L5** | FIXED | `…whenOneOfTwoTargetsOnTheStockUnitIsNotProvablyOnTheTote` has A on the tote (ON) and B labelled `"T-EARLIER"`. B therefore hits `toteState`'s label-mismatch branch and reads UNKNOWN. The shares are Σ 1+1 = SU 2, so ownership holds. The `logicalOr` mutant releases, so it is killed. See N1 for one ordering blind spot. |
| **L6** | FIXED | Only `MAPPER.writeValueAsString` is inside `catch (JsonProcessingException e)`, and `enqueue` is outside the try. `OutboxService.enqueue` declares no checked exceptions (`public OutboxMessage enqueue(OutboxMessage msg)`), so the method signature is unchanged.<br>What escapes now is unchecked (NPE from `requireNonNull`, `IllegalArgumentException` for key > 64, `IllegalTransactionStateException` from MANDATORY propagation). Spring's default RuntimeException rule still applies alongside `rollbackFor`, so these still roll back. The log label `enqueueReversalCompletedIfClosed:` matches the enclosing method. The new test uses `isSameAs(persistenceFailure)`, which is a real distinguisher.<br>This also changes the exception type for `completeReversal`, which shares the helper. It is benign: both paths roll back and reach a 5xx handler. |
| **L7** | PARTIAL | `validateWaiveInput` was extracted, keeping the order and messages: ids required → **cap (new)** → reason required → too long → stockReturned required. The only observable change is intended: 201 ids with a null reason now reports "too many" first. `prevalidateTargets` and `decideReleases` were not extracted, so `waiveReversal` is still about 110 lines. That part of the finding was optional. |
| **F3** | FIXED | The cap is 200 in both methods. In `completeReversal` the "positionIds required" check still comes first, the cap is checked before any read (the test verifies `never().findPendingReversalsForUpdate…`), and the no-op log now prints `ids`.<br>Switching from `List` to `LinkedHashSet` changes nothing for existing callers: both loops iterate over `logs`/`pending`, never over the ids, so order is unaffected, and `null` elements behave the same.<br>Real client need: mobile `completeSelectedPositions` sends `positionIds: [positionId]`, one per request (`store/cancellation.js:245-246`, origin/develop `5e99732`). No web-ui or mobile client calls `/waive` yet. PRD maximum positions per order: Hydra 8 (248 orders), ShipItEZ nywh 26 (1,407 orders), c1wh 43 (108,219 orders). Zero orders exceed 200, so the "far fewer" javadoc holds. |
| **F4** | FIXED | `authorizedOperator()` returns `SecurityContextHolder…getAuthentication().getName()`, the same expression as `FunctionGuardInterceptor.currentUsername():375`. It is read once per call, outside the loop, and nothing expects a different principal in between. Both tests build a `JwtAuthenticationToken(jwt, [], "service-account")` with a `sub`, and include a control that asserts the two names really differ, so reverting to `getUserName()` goes red.<br>Edge cases:<br>• Null auth falls back to `"anonymous"`, same as before.<br>• `AnonymousAuthenticationToken` gives `"anonymousUser"`, same as before (a String principal), and the gate makes it unreachable anyway.<br>• The `"service-account"` fallback is discussed in N2. |

### New findings

**[LOW] N1: the L5 fixture cannot kill a last-writer-wins merge mutant**
- File: `CancellationReversalServiceUnitTest.java`, `…OneOfTwoTargets…`
- Snippet: `a = waiveLog(7L, …)` (ON) and then `b` with `setToteLabelId("T-EARLIER")` (UNKNOWN); `targets` iterates a then b.
- Scenario: `merge(suId, v, (x, y) -> y)` (or `put`) produces AND-false with this order, keeps the lock and passes. Only `logicalOr` and first-wins are killed.
- Fix: use three targets (ON, UNKNOWN, ON), or add a mirrored case with UNKNOWN first.
- Confidence: HIGH.

**[LOW] N2: F4 fallback collapses distinct identities into `"service-account"`, and the sibling stamp was not swept**
- File: `CancellationReversalService.java:220-225`
- Snippet: `String operator = SecurityContextUtils.getUserName(); … log.setReversalInitiatedBy(operator);`
- Scenario:
  - A token without `preferred_username` now stamps `reversal_completed_by = "service-account"`, while `reversal_initiated_by` on the same row, and `createdBy` (`CancellationLogService:82`), still record the `sub` UUID. `toDetailDto` shows both fields.
  - Every such caller also collapses to one name, where `sub` was unique. This matches what the gate authorized, but it is worse for forensic attribution.
- Fix: in `authorizedOperator()`, when the name equals `"service-account"`, stamp `"service-account:" + sub` (or refuse, the review's alternative). Then either route `initiateReversal` through the same helper or document the split.
- Confidence: HIGH that it happens; LOW that it is reachable. Keycloak normally emits `preferred_username`, including for service accounts.

**[LOW] N3: the duplicate-id tests would pass on the parent commit**
- File: `…UnitTest.java`, `waiveReversal_shouldCloseADuplicatedPositionOnce` and `…AcceptIdsAtTheCapAndMoveDuplicatesOnce`
- Snippet: `List.of(POSITION_ID, POSITION_ID)` … `verify(logRepository, times(1)).save(log)`
- Scenario: before the fix, both loops iterated over the log rows and only used `positionIds.contains`, so duplicates never closed a row twice or double-counted. Deleting the `LinkedHashSet` stays green. These tests pin behaviour, not the dedup. The at-cap `>`→`>=` kill is real.
- Fix: rename or comment them as behaviour pins. The dedup's only observable effect is the logged `ids`, which is not worth asserting.
- Confidence: HIGH.

**[LOW] N4: the L3 evict has no positive control**
- Files: both ITs' `removeTheReversalUrlSysprop`
- Snippet: `sysprops.evict(...cacheKey(TenantContext.getCurrentTenant()) + ":" + KEY)`
- Scenario: if the key shape drifts (tenant set in the test but not in teardown, or the SpEL changes), `evict` misses silently and the order-dependence L3 described comes back unseen.
- Fix: use `assertThat(sysprops.evictIfPresent(key))` guarded on the test having read the key, or assert `sysprops.get(key) != null` before evicting in the tests that enqueue.
- Confidence: MEDIUM.

**[LOW] N5: a comment now sits above the wrong line**
- File: `CancellationReversalService.java:~318-322`
- Snippet: the "NOT inside the loop: findByCustomerorderId is a query, and FlushMode.AUTO would flush…" block is now directly followed by `final String operator = authorizedOperator();` instead of the waived-share loop it describes.
- Fix: move the `operator` line above the comment block.
- Minor style point in both ITs: inline fully qualified names instead of imports.
- Confidence: HIGH.

### Test hygiene checked
- **Counts in test names:** `TestIdentifierCountArchTest` flags `(the|exactly|all) N word` and `(Exactly|All)(Two…)`. None of the new names match. "OneOfTwoTargets" describes the fixture shape, not a set size. The cap only appears inside the asserted message.
- **Log labels:** all match their enclosing method.
- **Security context:** the F4 tests clear it in `finally`.

### Positive observations
- Both M1 fixtures were designed so the mutant flips the verdict and the original holds it, with release demonstrably reachable in the same fixture family.
- The F4 tests include a control proving that the two identity sources really diverge.
- The L6 narrowing fixes the mislabelled exception without changing the method's checked signature.
- The cap is checked before any FOR UPDATE read in both methods, and the tests verify that no read happens.

### Recommendation
**APPROVE.** N1–N5 are Lows. Under the repo's "fix Lows too" rule, the cheap ones are N1 (one more fixture), N5 (move one line) and N3 (rename two tests). N2 needs a decision from Nam on the service-account stamp format.
