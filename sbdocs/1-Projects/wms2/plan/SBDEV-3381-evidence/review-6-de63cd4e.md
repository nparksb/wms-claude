Confirmed — no count claim embedded in code comments, only in the commit message. Review complete.

head: de63cd4e3346c12fccfdf5bdac094650aab1efac

## Findings

**[LOW] Timing-fragile (not fully tautological) re-check of the timestamp guard**
File: `src/test/java/net/aim_ai/wms/unit/service/CancellationReversalServiceUnitTest.java:2144-2149`
Confidence: MEDIUM
```java
java.time.OffsetDateTime logInitiatedAt = log.getReversalInitiatedAt();
service.initiateReversal(CO_ID, null);
...
assertThat(log.getReversalInitiatedAt()).as("re-initiating keeps the first timestamp").isEqualTo(logInitiatedAt);
```
Scenario: this assertion is meant to catch the "always stamp `OffsetDateTime.now()`" mutant on a second `initiateReversal` call, but it depends on two `OffsetDateTime.now()` calls (one already captured in `log` from the first invocation, one a mutant would produce on the second invocation) differing by at least the JVM/OS clock's resolution. On a coarse-resolution clock (or an unusually fast re-entry into the same tick), a real regression could produce an identical instant and this specific assertion would pass despite the bug. It is not a bug in the merged sense since the *same* mutant is already reliably killed a few lines earlier by the `earlier` row's fixed `firstInitiatedAt` (2 days in the past, `earlier.getReversalInitiatedAt()).isEqualTo(firstInitiatedAt)` at line 2134-2135) — that check cannot coincide by clock resolution. So this is a redundant/supplementary assertion whose own kill power is theoretically flaky, not a gap in the test's actual mutation coverage.
Fix: none required for correctness; if you want this specific assertion to be self-sufficient, compare `isBefore`/`isAfter` bounds or assert reference/value inequality against a captured "before second call" wall-clock lower bound, or simply drop it since the guard is already proven by the `earlier` row.

**[LOW] Minor asymmetry vs. the sibling IT's lazy-seed teardown**
File: `src/test/java/net/aim_ai/wms/integration/service/CancellationReversalParcelSourceIntegrationTest.java:172-184` vs. `CancellationReversalLockClearIntegrationTest.java:881-899`
Confidence: HIGH (as an observation), not a defect
Issue: the referenced "same lazy shape" sibling (`CancellationReversalLockClearIntegrationTest`) sets `reversalUrlSysprop = null;` after `deleteById` in its `@AfterEach`; the new `removeTheReversalUrlSysprop()` here does not. Harmless because the class has no `@TestInstance(PER_CLASS)` anywhere in its hierarchy (confirmed — `BaseRollbackIntegrationTest` carries no such annotation), so JUnit5's default `PER_METHOD` lifecycle gives every test method a fresh instance and the field is `null` again regardless. Purely a style inconsistency with the sibling it claims to mirror.
Fix: none required; optionally add the reset line for literal parity with the sibling's pattern.

None found at CRITICAL/HIGH/MEDIUM.

### Verified positively
- `initiateReversal` (`CancellationReversalService.java:216-231`): each of the six PIT-relevant mutants (null-guard removed, null-guard negated, notes-guard removed, notes-guard negated, `save` call dropped, wrong/null return) has a corresponding, non-tautological assertion — confirmed by reading the method body against every new assertion.
- `givenOrder`'s `logRepository.findByCustomerorderId(CO_ID)` stub returns `List.copyOf(all)` (`CancellationReversalServiceUnitTest.java:1254`) — a shallow copy; `log`/`earlier` in the test remain the exact same object references the service mutates, so all post-call assertions on those local variables observe real mutations, not stale copies.
- `CancellationReversalParcelSourceIntegrationTest.aReversalOutOfAParcelIsRefusedAndLeavesTheLockAt100`: traced the service's `completeReversal` pre-validate loop (`CancellationReversalService.java:254-311`) — `SourceContainerGuard.assertStockNotInParcel` throws before the sysprop URL is ever read or the outbox enqueued (both live only in the later movement/notify section), so this test genuinely never needs the sysprop row. The lazy seed correctly lives only in `aReversalOutOfACaseCompletesAndEnqueuesTheOutboxRow`.
- `@AfterEach removeTheReversalUrlSysprop()`'s `if (reversalUrlSysprop != null)` guard correctly no-ops for the parcel test (field stays null, nothing seeded, nothing to tear down).
- No `@TestInstance` annotation anywhere in the class or `BaseRollbackIntegrationTest` — default `PER_METHOD` lifecycle confirmed, so the field resets between the two tests regardless of execution order.
- Comment accuracy: the new javadoc on `seedReversalUrlSysprop()` claims "the same lazy shape as CancellationReversalLockClearIntegrationTest" — checked that file, the lazy-seed-with-null-check + `@AfterEach` delete pattern does match.
- No mutant/assertion counts embedded in `@DisplayName`s or in-code comments (only in the commit message, which doesn't rot the way a maintained doc comment would).

## Recommendation
APPROVE
