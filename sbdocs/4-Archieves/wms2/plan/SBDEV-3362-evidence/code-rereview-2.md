head: 2b706a3c02ce5c88f757a23a6e89853c7f656163

# SBDEV-3362 — scoped re-review #2 of 2b706a3c (code-reviewer lane, not the author)

Scope: `git show 2b706a3c` (3 files, comment/test-only) + the sbdocs integration-map row. Answers N1–N5 of `code-rereview.md`.
Tree: worktree `.claude/worktrees/wms2-api/SBDEV-3362` at HEAD 2b706a3c, read-only, no mvn run. Worktree clean.
Author's evidence taken as stated, not re-run: 234 unit + 6 IT pass, including the typed assertion.
DB evidence I gathered myself (hydra nywh PRD + shipitez c1wh PRD, read-only): `customerorder.orderbatch_id` has `is_nullable = NO` and **0 null rows**, and `uk_outbox_message_idempotency_key` exists, on both.

## Verdict: APPROVE — High 0 · Medium 0 · Low 1 (residual, optional)

## N1–N5 disposition

| # | Status | Evidence |
|---|---|---|
| **N1** rollback IT asserts nothing about why it threw | **ADDRESSED** | `CustomerorderForceCancelOutboxIntegrationTest:196-199` now ends `.isInstanceOf(DataIntegrityViolationException.class)`. The optional `rootCause().hasMessageContaining("idempotency_key")` was not added; see R1. |
| **N2** `forceCancelOrder` null guard is contradicted by the helper's hard fail | **ADDRESSED** | `CustomerorderService:538-540` adds a 3-line comment: the guard is pre-existing, it never skips in production, and it must not be copied onto the signal because that would silently drop it. It names SBDEV-3362. This is the "comment" option from the prior review. |
| **N3** 162-char comment line in `PickingorderBusinessService` | **ADDRESSED** | The line is split at `:756-757`. The block's longest line is now 102 chars, which matches its neighbours. The wording is unchanged, so the meaning is preserved exactly: the sentence ends at "not its own." and the `uk_… in V2.2.00 … then makes a duplicate a constraint violation` clause starts the next line. The file's other >120-char lines (`:157`, `:161`, …) pre-date this ticket. |
| **N4** integration-map `:351` still asserts `WEBSERVICE_STOCK_COUNT_URL_KEY` | **ADDRESSED** (sbdocs, not in git) | `wms2-oms-integration-map.md:351` now reads: Cause "`WEBSERVICE_ORDER_BATCH_CANCELLED` URL not set; or (before SBDEV-3362) the order was force-cancelled, which sent nothing". Fix "Check sysprop `WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` — the one `enqueueCancellationSignal` reads", with a dated correction note. It agrees with `:113` and with the code (`CustomerorderService` has no `WEBSERVICE_STOCK_COUNT_URL` reference). The remaining `WEBSERVICE_STOCK_COUNT` mentions at `:141/:175/:312` are the stock-export rows and the refutation note, so they are correct. |
| **N5** IT javadoc says "real database" | **ADDRESSED** | `:42` says "in-memory H2 database with real commits". The new `:56-59` paragraph says the index is Hibernate's from `@Column(unique = true)`, NOT the Flyway `uk_outbox_message_idempotency_key`, and that the test "does not prove the production constraint exists". This is exactly the scope the prior review asked for. |

## Fresh checks on 2b706a3c

**A. "orderbatch_id is NOT NULL, so it never skips in production": TRUE.**
- Schema: `V2.2.00__base_v2_schema.sql:767` `orderbatch_id bigint NOT NULL`, plus FK `:5610`. No later `db/migration` file alters the column.
- Entity: `Customerorder:28-29` has `@NotNull @Column(name = "orderbatch_id")`.
- Live data: both PRD tenants I queried return `is_nullable = NO` with 0 nulls. That includes shipitez, a v1-migrated tenant, so the onboarding path did not relax it.
- The only way to reach the guard with null is an in-memory `setOrderbatchId(null)` on a managed entity before the `save` at `:536` flushes. No production caller does that. "Never" is acceptable for a comment. It is a completeness word, but it now has two instruments behind it: the DDL and the live data.
- The second sentence, "a guard there would silently drop the signal", is accurate. `enqueueCancellationSignal` has `requireNonNull` with the Supplier message, pinned by `cancelOrder_nullOrderbatchId_failsWithNamedMessage` (reviewed in 350192f6).

**B. The H2/Hibernate unique-index claim in the IT javadoc: TRUE.**
- `OutboxMessage:75` is `@Column(name = "idempotency_key", nullable = false, unique = true, length = 64)`.
- `BaseRollbackIntegrationTest:34-36` is `ddl-auto=create-drop` on `jdbc:h2:mem:rollback_tenant;…;MODE=PostgreSQL`, so no Flyway runs. The only uniqueness is Hibernate's generated constraint (`CONSTRAINT_INDEX_9` in the prior failsafe log).
- The contrast with production is also correct. `uk_outbox_message_idempotency_key` exists in `V2.2.00:3748` and in `v1-to-v2-onboarding/schema/V2.1.11__add_outbox_message.sql:22`, and live on both PRD tenants.

**C. Is the typed assertion correct, and would it hold on Postgres? Yes.**
- `OutboxMessage.id` is `GenerationType.IDENTITY` (`:54`), so `OutboxService.enqueue`'s `repo.save(msg)` (`:56`) issues the INSERT immediately, inside the Spring Data repository proxy.
- Persistence-exception translation turns Hibernate's `ConstraintViolationException` into `DataIntegrityViolationException` there. It then propagates as a RuntimeException through `enqueue` (MANDATORY), `forceCancelOrder` and `cancelOrder`'s `@Transactional(tenantTransactionManager)` at `:840`, which rolls back and rethrows the same exception.
- It is not a commit-time failure, so it cannot be converted to `TransactionSystemException` / `UnexpectedRollbackException`. The IT method itself is not `@Transactional`; only `setUp` at `:100` is. So `cancelOrder`'s transaction is the outermost one.
- On Postgres, SQLState 23505 maps to `DuplicateKeyException`, a subclass of `DataIntegrityViolationException`, so the assertion would still hold.
- CI question: this class extends `BaseRollbackIntegrationTest`, which pins H2 through `@TestPropertySource`. Every lane, local or CI, runs it on H2. There is no Postgres variant of this test to diverge.

**D. Does the rewrap preserve the comment's meaning? Yes.** It is a pure line split with the text byte-identical (see N3).

## Residual finding

### R1 [Low] — the typed assertion is class-level, so a different integrity violation would also pass it
**File:** `src/test/java/net/aim_ai/wms/integration/CustomerorderForceCancelOutboxIntegrationTest.java:196-199`
**Confidence:** MEDIUM

```java
.as("the duplicate key must fail the force-cancel, not be swallowed — and as a key "
        + "collision, not some unrelated failure")
.isInstanceOf(DataIntegrityViolationException.class);
```

- **Issue:** `DataIntegrityViolationException` also covers NOT NULL, length and FK violations. The obvious regressions are an NPE in the payload build or a changed batch precondition, and those are now excluded. But a future change that writes a null or over-long column on the order or the outbox row would still pass while the description says "as a key collision". That is narrow, and the sibling positive-control test would go red in most such cases, since it runs the same shape with the key free.
- **Fix (optional):** append `.rootCause().hasMessageContaining("idempotency_key")`. H2's message names the column, and Postgres would name `uk_outbox_message_idempotency_key`, which also contains it. Per the memory rule, that is a column fragment, not a Flyway filename. Mutation-check it by pre-seeding a *different* key and confirming the test goes red. The author's evidence does not mention a mutation check of the new type assertion itself. Removing the pre-seeded row only proves the pre-existing "throws at all" part.

## Positive observations
- Every fix took the cheaper option the prior review offered and stated it precisely: a comment rather than removing the guard, and a scoped javadoc rather than a Postgres IT.
- The N5 paragraph carries the negative claim ("does not prove the production constraint exists"). That is the sentence a future reader needs, and it is the one most often omitted.
- The N2 comment explains the asymmetry (guard here, fail-loud there) instead of only annotating it, so a well-meaning "consistency" edit is fenced off.
- The sbdocs row fix carries its own dated correction note, which is consistent with `:113`.

## Recommendation
**APPROVE.** N1–N5 are all addressed. R1 is optional hardening; under the house rule on Lows it is cheap enough to fold into the PR if the branch is touched again. The L9 PR-body requirements from `code-rereview.md` still stand.
