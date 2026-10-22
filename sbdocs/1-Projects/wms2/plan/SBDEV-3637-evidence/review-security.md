# SBDEV-3637 — Security Review

**Lane:** lane-security · **Date:** 2026-10-05
**Subject:** worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637`, commit `29e43eb1`, base `origin/develop` `ec42f43a` (merge-base confirmed `ec42f43a`).
**Diff:** `git -C <WT> diff origin/develop...HEAD` — 11 files, +1844/-47. 2 files under `src/main`, 9 under `src/test`.
**Constraint honoured:** read-only; no Maven invoked; no `git stash`/`checkout --`/`restore`; the stale `/home/nampark/dev/wms-claude/v2/wms2-api` checkout was never read.

**Risk Level: LOW**

## Summary

- Critical: 0
- High: 0
- Medium: 0
- Low: 2
- Informational: 3

The change is net **security-positive**. It adds one non-waiting `PESSIMISTIC_WRITE` finder, correctly un-exported from the HTTP surface, and converts a transient row-lock contention from a **destructive cancel** into a **defer**. No authorization annotation, tenant-routing construct, secret, dependency or SQL-building code is touched.

---

## Scope of the two `src/main` changes

- `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` — adds `findByIdForUpdateSkipLocked`.
- `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` — adds the `RedirectOutcome` enum, the `targetIsBelowHeldSource` predicate, the finder selection at the target acquisition, an `existsById` disambiguation, and two WARN lines.

Everything else is `src/test`.

---

## 1. Spring Data REST exposure — **CLOSED**

`StockunitRepository` is exported: `@RepositoryRestResource(collectionResourceRel = "stockunit", path = "stockunit")`, with no `exported = false` at class level. It is also listed under `MUST_REMAIN_EXPORTED` in `src/test/java/net/aim_ai/wms/security/SdrUncalledSurfaceNotExportedContextTest.java` (`net.aim_ai.wms.model.Stockunit.class`, in the "Live SDR READ caller" block), so `/v3/stockunit/**` is a **live** surface. The method-level annotation is therefore load-bearing, not decoration.

The new finder carries it:

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "-2"))
@Query("SELECT s FROM Stockunit s WHERE s.id = :id")
// SBDEV-3169, same reason as findByIdForUpdate above: exported, this would let any authenticated
// caller take a PESSIMISTIC_WRITE row lock over HTTP GET.
@RestResource(exported = false)
Optional<Stockunit> findByIdForUpdateSkipLocked(@Param("id") Long id);
```

**Effect, not annotation presence.** Two independent grounds, both in-repo:

1. `src/test/java/net/aim_ai/wms/security/ReportPaginationSearchWithdrawalContextTest.java` states the measured HTTP behaviour of this exact mechanism: *"A method-level withdrawal answers **404** (the rel is never registered)"*, and separately *"`exported = false` removes only the HTTP route"*. The rel is never registered — route removal, not HAL-index hiding.
2. `src/test/java/net/aim_ai/wms/security/SdrLockingSearchNotExportedContextTest.java` (SBDEV-3169) asserts the **invariant** over the live `ResourceMappings` bean — *"an exported SDR search must not resolve to a repository method carrying `@Lock`"* — iterating `mappings.getSearchResourceMappings(...)` and skipping `!m.isExported()`. Because `Stockunit` is an exported type, its searches are populated, so this rail **does** see the new method: delete the annotation and the rail reds. It carries its own anti-vacuity guard (`exportedSearches > 100`) and a mutation rail (`detectorRecognisesPessimisticWrite`).

The new `src/test/java/net/aim_ai/wms/unit/repo/StockunitSkipLockedContractTest.java` adds a third, weaker reflection pin (`v2-only #7 — the skip-locked finder is NOT exported over HAL`) that resolves the method by name and fails loudly on a rename.

**The trap named in the brief does not apply here.** The recorded "`exported = false` matches at METHOD level and still leaves other mechanisms open" case concerns *write*-verb withdrawal, where `ExposureConfiguration` and `@ReadOnlyProperty` are alternative mechanisms and the symptom is 200/405 rather than 404. This is a **search**, and `ResourceType` has only `COLLECTION` and `ITEM` — `RepositorySearchController` never calls `verifySupportedMethod`, so exposure filters cannot reach a search at all (quoted at `SdrUncalledSurfaceNotExportedContextTest`: *"exposure filters cannot reach a search"*). Method-level `exported = false` is the only mechanism that applies, and it is the one used.

**Blind spot, stated:** no test in this diff probes `/v3/stockunit/search/findByIdForUpdateSkipLocked` over HTTP for a 404. See finding **S-2**.

**Why this matters at all:** `/v3/**` requires only `hasAnyAuthority("wms_user")` — `src/main/java/net/aim_ai/wms/landlord/config/IdempotencyFilter.java` comments *"it executes before the `hasAnyAuthority("wms_user")` check on `/v3/**`"*. Every authenticated user holds `wms_user`. An exported locking search is reachable by all of them; this one is not reachable by any of them.

## 2. Denial-of-service surface — **NET REDUCED; one pre-existing residual carried, unchanged**

**Lock hold is not lengthened on the hot path.** The new branch is:

```java
boolean skipLocked = !recalcPath || targetIsBelowHeldSource(currentSource, candidate.stockUnitId);
```

On the success path nothing is added. On the **miss** path only, one extra non-locking PK lookup (`existsById`) runs before returning `CONTENDED` — see **S-4**.

**No unbounded or multi-row lock added.** The JPQL locks exactly one row by primary key.

**No bound was removed.**
- The ascending/null branches keep the waiting `findByIdForUpdate`, which stays under SBDEV-3250's bound: `LockTimeoutHibernateJpaDialect` issues `SET LOCAL lock_timeout` per acquisition (`statement.execute("SET LOCAL lock_timeout = " + lockTimeoutMillis)`) and `src/main/resources/application.properties` sets `wms.tenant.lock-timeout-ms=3000`.
- On the skip-locked branch, `SET LOCAL lock_timeout` **cannot fire** — correct, and it **does not matter**: `lock_timeout` bounds a *wait*, and `SKIP LOCKED` never waits. The bound it would have provided is strictly weaker than the behaviour that replaces it (3000 ms worst case → 0 ms). No availability guarantee is lost.
- `NOWAIT` (`value = "0"`) would have been the dangerous alternative: PostgreSQL `55P03` is a statement error that aborts the transaction (`25P02` thereafter), poisoning `recalculateForItem`'s whole item sweep. The code and `StockunitSkipLockedContractTest` both pin `-2` and both state why `0` is unacceptable.

**Residual carried forward (accepted in-code, not introduced here):** `StockunitBusinessService.transferStockToUnitLoad` takes two stock-unit locks with no id comparison between them — `stockunitRepository.findByIdForUpdate(sourceStockunitId)` at `StockunitBusinessService.java:202` and `stockunitRepository.findByIdForUpdate(dstSuId)` at `:277`. Against the retained *waiting* ascending branch here, that is a live SU↔SU ABBA. The in-code comment names it honestly — *"THIS EDGE CARRIES A LIVE SU<->SU ABBA"* — and declines to close it on a measured cost basis (253 of 329 second-lock acquisitions ascending, wsl-wineco-uat 2026-10-04). Blast radius is bounded: PostgreSQL's deadlock detector aborts one side with `40P01`, or the 3000 ms `lock_timeout` fires first; one transaction dies, nothing hangs. This is **not a regression** — it existed before the change and the change narrows the set of edges that can enter it. Recorded as **S-1**.

## 3. Multi-tenancy — **CLEAN**

- **No `@Transactional` added, removed or altered in `src/main`.** Scan: `git diff origin/develop...HEAD | grep -E "^[+-].*@Transactional"` returns two additions, both `@Transactional(propagation = Propagation.NOT_SUPPORTED)`, both in **test** classes — `StockunitSkipLockedIT.java:77` and `ReplenishRedirectLockOrderIT.java:108`. Attribution verified with `git grep -n "Propagation.NOT_SUPPORTED" -- src/main src/test/.../StockunitSkipLockedIT.java src/test/.../ReplenishRedirectLockOrderIT.java`, which returns **zero** `src/main` hits. Both test entries are added to the `TestClassTransactionManagerArchTest` allowlist with a written justification, which is the governed path.
- Every `@Transactional` in `ReplenishmentOrderMaintenanceService` names the tenant manager — `@Transactional(value = "tenantTransactionManager", ...)` at lines 144, 250, 305, 884. None is bare, so none can silently route to the landlord DB.
- **No cross-tenant cache or shared mutable state.** Scan of added lines for `landlord|TenantContext|setTenant|X-Tenant|Cache|@Cacheable|static .*(Map|Set|List)` returns two hits, both `private static` **method return types** in test helpers (`static List<String> sqlStates(...)`, `static Set<String> declaredSignatures()`) — no static field. Positive control: the regex did fire on those two lines, so it is not blind.
- `@QueryHints` is applied onto the `Query` object at execution time (as the javadoc states), so it is per-query and cannot leak across tenants or sessions. This is also why the hint is used rather than `spring.jpa.properties.*` — the tenant persistence unit receives no vendor property map.

## 4. Log injection / information disclosure — **CLEAN**

Both production log lines are SLF4J-parameterized (`{}`), no concatenation:

```java
LOG.warn("SBDEV-3637 REDIRECT_CONTENDED replenishOrder={} target={} path={} state={}",
         order.getNumber(), candidate.stockUnitId, recalcPath ? "recalc" : "move", order.getState());
```
```java
LOG.warn("SBDEV-3637 REDIRECT_NO_HEAL replenishOrder={} state={} — no recalc sweep selects"
         + " this state; this order will not self-heal", order.getNumber(), order.getState());
```

- **Values are server-generated, not caller-supplied.** `Replenishorder.number` is written only at `ReplenishGeneratorService.java:290` (`basicService.generateReplenishNumber()`) and `:341` (`template.getNumber() + "-" + (sequenceIndex + 1)`). No request body reaches it, so CRLF forging of the plain-text console pattern (`logging.pattern.console=...%msg%n`) is not reachable from an attacker-controlled value here.
- **No new data class.** Order number, stock-unit id and state are already logged by this class at lines 364, 703, 830, 837, 853, 901, 911, 955. No credential, token, PII or request payload.
- Volume is bounded, not unbounded: a `PROCESSABLE` deferral self-heals on the next sweep; a non-`PROCESSABLE` one is never re-visited (which is precisely what `REDIRECT_NO_HEAL` reports), so it cannot log in a loop.
- The test-only probe logging (`log.info("SBDEV-3637 probe: held={} blockedStmt={} ...")` in `ReplenishRedirectLockOrderIT`) echoes `pg_stat_activity` text from an ephemeral Testcontainers database. Not shipped.

## 5. SQL — **CLEAN**

`@Query("SELECT s FROM Stockunit s WHERE s.id = :id")` — JPQL, single named parameter bound via `@Param("id")`, no concatenation, no `nativeQuery`, no dynamic predicate. No injectable surface.

The diff's only string-built SQL is in a test and interpolates a `long` compile-time constant: `st.execute("SELECT id FROM stockunit WHERE id = " + STOCKUNIT + " FOR UPDATE")` in `StockunitSkipLockedIT`. Not injectable; see **S-5**.

## 6. Authorization — **UNCHANGED (zero, with a positive control)**

Scan over the diff for `@PreAuthorize|@RequiresFunction|FunctionEnum|@Secured|hasRole|hasAuthority|GUARDED|SecurityConfig` on added or removed lines returns **no gate change**. The only matching tokens are `@RestResource(exported = false)` (added — a tightening) and javadoc prose.

**Positive control for the same regex, same session:** `git grep -cE "@PreAuthorize|@RequiresFunction|FunctionEnum" -- src/main/java/net/aim_ai/wms/controller` returns non-zero counts across the controller package (`AdminActionController` 10, `ClientController` 23, `ItemDataController` 17, `CustomerOrderController` 15, …). The instrument finds the gates that exist, so the zero over the diff is a true zero and not a broken scan.

Independently: no `src/main` file in this diff is a controller or security component. Changed `src/main` files are one repository interface and one service.

**Blind spot:** the scan is token-based over the diff. A gate removed by deleting a whole annotated **file** would not match this regex — not applicable here, since `git diff --stat` shows no deletions and both `src/main` files are modifications.

## 7. Secrets — **CLEAN (with a positive control)**

`git diff origin/develop...HEAD | grep -aEin "(password|passwd|secret|api[_-]?key|token|bearer|private[_-]?key|BEGIN RSA)[\"'[:space:]]*[:=]"` → **no match** (exit 1).

**Positive control, same regex, same session:** run against `src/main/resources/application.properties` it returns `spring.data.redis.password=${REDIS_PASSWORD:}` and `landlord.datasource.password=${LANDLORD_DATASOURCE_PASSWORD}`. The instrument works; the zero over the diff is real. (`-a` was passed because `grep` here is ugrep, which silently skips binary input and exits 1 exactly like a genuine no-match.)

Database credentials in the new ITs come from the Testcontainers container object and are passed as **separate arguments**, never concatenated into a URL:

```java
DriverManager.getConnection(c.getJdbcUrl(), c.getUsername(), c.getPassword())
```

(`StockunitSkipLockedIT:180`, `ReplenishRedirectLockOrderIT:688`). This is the correct form — a URL-concatenated credential splits at the first `@`.

## 8. Dependencies — **NO CHANGE**

`git diff --stat origin/develop...HEAD -- pom.xml` is empty; `pom.xml` is absent from the diff's file list. No dependency added, removed or upgraded, so no new CVE surface is introduced by this change.

**NOT ESTABLISHED:** a CVE audit of the *existing* dependency tree. Maven was explicitly forbidden this round (a sibling lane owns the JVM). **Settling probe:** `mvn -o dependency-check:check` or `mvn versions:display-dependency-updates` from `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637`, once the JVM is free — and that is a repo-level audit, not a gate on this diff.

---

## Findings

### S-1 — LOW — SU↔SU ABBA remains live on the retained waiting edge
**Category:** A04 Insecure Design (availability) · **Location:** `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java`, the `boolean skipLocked = !recalcPath || targetIsBelowHeldSource(...)` branch; counterparty at `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:202` and `:277`.
**Exploitability:** Not attacker-triggerable. Requires concurrent ordinary warehouse operations (a recalc sweep and a stock transfer) on two stock units of the same itemdata, in opposing order.
**Blast radius:** One aborted transaction per occurrence. Bounded by PostgreSQL `40P01` deadlock detection and by the 3000 ms `lock_timeout`; no hang, no data loss, no cross-tenant effect.
**Issue:** The recalc **ascending** edge deliberately keeps the waiting finder. `transferStockToUnitLoad` takes its two stock-unit locks with no id comparison, so it can hold the higher id and wait on the lower while recalc holds the lower and waits on the higher. The in-code comment states this explicitly and declines to close it here on a measured cost basis. **Pre-existing; not introduced by this change** — the change strictly shrinks the set of edges that can enter a cycle.
**Remediation** (belongs on its own ticket, as the comment says — not a blocker for this one): order the two acquisitions by id at the `transferStockToUnitLoad` site, where both ids *are* known before either lock is taken, which this site structurally cannot do.
```java
// BAD — StockunitBusinessService:202/:277, no relative ordering between the two stock-unit locks
sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId).orElseThrow(...);
// ... later ...
destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId).orElseThrow(...);

// GOOD — both ids are in hand before either lock; acquire in ascending id order, then use by role
List<Long> ordered = Stream.of(sourceStockunitId, dstSuId)
        .filter(Objects::nonNull).distinct().sorted().toList();
Map<Long, Stockunit> locked = new LinkedHashMap<>();
for (Long id : ordered) {
    stockunitRepository.findByIdForUpdate(id).ifPresent(su -> locked.put(id, su));
}
sourceStockunit = locked.get(sourceStockunitId);
destinationStockUnit = dstSuId == null ? null : locked.get(dstSuId);
```
Add a two-leg concurrency IT in the shape of `ReplenishRedirectLockOrderIT`, and keep the existing `orElseThrow` semantics for the source (ascending acquisition must not change which miss throws).

### S-2 — LOW — no HTTP-level pin that `/v3/stockunit/search/findByIdForUpdateSkipLocked` 404s
**Category:** A01 Broken Access Control (test coverage of the control, not the control itself) · **Location:** `src/test/java/net/aim_ai/wms/unit/repo/StockunitSkipLockedContractTest.java`, test `skipLockedFinderIsNotExportedOverHal`.
**Exploitability:** None today. The control is in place and is covered by the SBDEV-3169 invariant rail over the real `ResourceMappings`.
**Blast radius:** If the invariant rail is ever narrowed or the type is re-shaped, the remaining pin is a reflection assertion on annotation presence — which is exactly the "annotation present, route still live" failure this repo has recorded before.
**Issue:** Coverage for the new finder is (a) the SBDEV-3169 invariant (strong, but it is a *shared* rail that a future edit could scope down) and (b) a reflection assertion (weak — it asserts the annotation, not the route). Neither issues an HTTP request for this path. `ReportPaginationSearchWithdrawalContextTest` already measured that a method-level withdrawal answers 404, so the pattern to copy exists.
**Remediation:** add one route row to a context test, with an exported control on the same resource so a blanket-404 context cannot pass it vacuously:
```java
// in a *ContextTest extending BaseControllerIntegrationTest
@Test
@DisplayName("SBDEV-3637 — the skip-locked finder is not routable; a sibling stockunit search still is")
void skipLockedSearchIsNotRoutable() throws Exception {
    // control: this resource IS exported, so a blanket 404 cannot make the assertion below vacuous
    mockMvc.perform(get("/v3/stockunit/search/findByUnitloadId").param("unitloadId", "1"))
           .andExpect(status().isOk());
    mockMvc.perform(get("/v3/stockunit/search/findByIdForUpdateSkipLocked").param("id", "1"))
           .andExpect(status().isNotFound());
    mockMvc.perform(get("/v3/stockunit/search/findByIdForUpdate").param("id", "1"))
           .andExpect(status().isNotFound());
}
```

### S-3 — INFORMATIONAL — deferred orders at a non-`PROCESSABLE` state rely on a log line nobody is known to watch
**Category:** A09 Security Logging and Monitoring Failures · **Location:** the `REDIRECT_NO_HEAL` WARN in `ReplenishmentOrderMaintenanceService.redirectSource`.
**Issue:** The code correctly identifies that a `CONTENDED` defer at a state other than `PROCESSABLE` is selected by no recalc sweep and so never self-heals, and it emits a dedicated WARN. That WARN is the only instrument. Whether anything alerts on application logs in this estate is **NOT ESTABLISHED** by this review; what *is* recorded is that nothing scrapes the Prometheus endpoint (as of 2026-09-02), so a metric would not have helped either.
**Remediation:** either (a) register an alert on the literal token `SBDEV-3637 REDIRECT_NO_HEAL` in whatever log sink the estate uses, or (b) prefer a reconciliation sweep that re-queues deferred non-`PROCESSABLE` orders, so the control is code rather than an alert. **Settling probe for the alerting question:** ask the infra owner whether the log sink has alert rules, or grep the deployment repo for a log-alert definition — neither is reachable from this worktree.

### S-4 — INFORMATIONAL — one extra round trip under the held locks on the contended path
**Location:** `ReplenishmentOrderMaintenanceService.redirectSource`, `if (candidate.stockUnitId == null || !stockunitRepository.existsById(candidate.stockUnitId))`.
**Issue:** On the skip-locked **miss** only, one additional non-locking PK lookup runs while the order row lock and (usually) the source stock-unit lock are held. It is a single indexed `SELECT`, it does not run on the success path, and it buys a real correctness property (distinguishing "locked" from "gone", so a vanished row is not deferred forever). Noted for completeness; no change recommended. The `candidate.stockUnitId == null` short-circuit is correct and necessary — `SimpleJpaRepository.existsById(null)` throws `IllegalArgumentException`.

### S-5 — INFORMATIONAL — test-only SQL string concatenation
**Location:** `src/test/java/net/aim_ai/wms/integration/repository/StockunitSkipLockedIT.java` — `st.execute("SELECT id FROM stockunit WHERE id = " + STOCKUNIT + " FOR UPDATE")`.
**Issue:** `STOCKUNIT` is a `long` compile-time constant in the test class; there is no external input and no production reachability. Flagged only so a future reader does not copy the shape into `src/main`. If it is ever parameterized, use `PreparedStatement` with `setLong`.

---

## Anti-drift rails: all movements are tightenings

Checked explicitly, because a security review that only reads `src/main` misses a loosened rail:

- `ReplenishmentFirstTouchInvariantUnitTest` — **adds** `verify(stockunitRepository, never()).findByIdForUpdateSkipLocked(candidateId)`, with a written note that `ignoreStubs()` weakens the surrounding guard. Tightening.
- `ReplenishmentOrderMaintenanceServiceReassignTest` — **adds** `verify(stockunitRepository, never()).findByIdForUpdate(99L)` alongside the retargeted `InOrder` row, and documents why the ids are deliberately left ascending. Tightening.
- `NeverMatcherNullBlindnessArchTest` — count raised 7 → 10 with each new `anyBoolean()` position named and the declared parameter type read at the declaration (`StockunitBusinessService.java:508`, `boolean zeroIfNegative`), not inferred from the matcher name. Correct per the recorded `never()`/primitive-unboxing trap.
- `TestClassTransactionManagerArchTest` — two **additive** allowlist entries, each with a stated reason and a stated cleanup contract (`wipe()` in both `@BeforeEach` and `@AfterEach`, FK order, id bands 9860–9865 and 9880–9896 swept against `src/test`). Governed path; no rule weakened.
- `ReplenReassignOnNonReplenishableMoveIT` — javadoc only: splits the now-ambiguous "make `redirectSource` never succeed" mutant into the two outcomes the enum created. No assertion changed.

Residual, non-security: both new ITs **commit** their fixtures (`NOT_SUPPORTED`). A JVM killed mid-run leaves rows at client 9860/9880 in the shared reusable Postgres container. Documented in the allowlist entries; the risk is a poisoned sibling lane, not production.

---

## Security Checklist

- [x] No hardcoded secrets (scan clean, positive control fires)
- [x] All inputs validated — the only new input is a `Long` id bound as a JPQL named parameter
- [x] Injection prevention verified — JPQL + `@Param`, no concatenation, no native query
- [x] Authentication/authorization verified — zero gate changes, positive control fires; the one access-control-relevant construct (`@RestResource(exported = false)`) is added, not removed
- [x] Multi-tenancy verified — no bare `@Transactional`, no cross-tenant cache, no static mutable state
- [x] Logging reviewed — parameterized, server-generated values, no new data class
- [x] Dependencies — `pom.xml` unchanged; full-tree CVE audit NOT ESTABLISHED (Maven forbidden this round)
- [x] DoS surface reviewed — no lock lengthened, no bound removed, one pre-existing residual carried and named

---

## VERDICT: APPROVE

No finding blocks the merge. **S-1** is pre-existing and already proposed as its own ticket by the code under review; **S-2** is a coverage hardening worth doing in this pass, since this repo fixes Lows in the same pass. Everything else is informational.
