---
title: "WMS2 Multi-Replica Hardening — OptimisticLockRetry / JWT Decoder / HTTP-in-Tx Guard"
ticket: ""
ticket_url: ""
type: "refactor"
priority: "medium"
status: "implemented"
pr: "Phase A: PR #40 · Phase B: PR #41 · Phase C: PR #42 (SiteBossInc/wms2-api)"
commit: "A: 8864f5f · B: e04ced2 · C: c4a7579"
project: ["wms2-api"]
version: "v2"
requester: "Nam Park"
assignee: "Nam Park"
created: "2026-06-10"
updated: "2026-06-10"
db_verified: "N/A"
db_verified_note: >
  No SQL, schema, Flyway, sysprop, or state-machine change in any of the three
  phases. Phase A deletes inert in-memory retry wrappers; Phase B swaps an
  in-JVM ConcurrentHashMap for an in-JVM Caffeine cache; Phase C adds a
  test-only ArchUnit guard. db_verified=N/A is intentional and stable.
related:
  - "[[260610-wms2-horizontal-scalability-readiness-audit]]"
  - "[[SBDEV-2238-outbox-phase2-remaining-services]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
  - "[[wms2-tenant-routing-datasource-topology]]"
tags:
  - plan
  - wms2
  - hardening
  - horizontal-scaling
---

# WMS2 Multi-Replica Hardening — OptimisticLockRetry / JWT Decoder / HTTP-in-Tx Guard

**Ticket:** (untracked — `260610-` dated plan)
**Project:** wms2-api | **Version:** v2 | **Type:** refactor / hardening
**Priority:** medium
**Status:** draft
**Date:** 2026-06-10

**Source audit:** `sbdocs/3-Resources/reports/260610-wms2-horizontal-scalability-readiness-audit.md` §8 items 3–5 (item 3 retracted 2026-06-10 → regression guard only).
**Analysis bundle:** `.omc/plans/260610-wms2-multi-replica-hardening-analysis.md` (authoritative evidence + §10 binding decisions).

> **Scope is fixed (bundle §10).** Three independent phases, separate branches/PRs, recommended order A → B → C:
> - **Phase A** (audit item 4): remove inert `OptimisticLockRetry` call sites + dead injections; keep the utility + its working `MobilePalletizingService` consumer.
> - **Phase B** (audit item 5): replace the never-evicted decoder `ConcurrentHashMap` with a Caffeine TTL cache; create the missing decoder unit test; fix README drift. **TTL-only — no rebuild-on-exception.**
> - **Phase C** (audit item 3, **retracted → guard**): ArchUnit rule + test asserting no `@Transactional` method in wms2-api calls `HttpRestService`.

---

## §0 Affected Sites

Every grep-discovered site from bundle §0, with in-scope verdict. Reference/caller rows are covered (audit-only, no change) or excluded with rationale.

### Phase A — OptimisticLockRetry (audit item 4)

| # | File:line | Construct | In scope? | Action |
|---|---|---|---|---|
| A1 | `util/OptimisticLockRetry.java` (whole) | the utility `@Component` | keep | none — still consumed by palletizing |
| A2 | `service/PickingorderBusinessService.java:65,90,111` | field + ctor param + assignment | **yes** | remove injection (ctor arity −1) |
| A3 | `service/PickingorderBusinessService.java:580-589` | inert `executeWithRetry` in `confirmPick` (`@Transactional :495`, pessimistic locks `:528,:531`) | **yes** | replace with plain re-use of in-method mutation (`:570-574`) + single `save` |
| A4 | `service/UnitloadBusinessService.java:54,68,78` | field + ctor param + assignment | **yes** | remove injection (ctor arity −1) |
| A5 | `service/UnitloadBusinessService.java:176-181` | inert `executeWithRetry` in `transferUnitLoadToLocation` (`@Transactional :112`) | **yes** | replace with plain `setCarrierunitloadId(null)` + `save` (already at `:174`) |
| A6 | `service/mobile/MobileReplenishService.java:20,74,97,116` | import + field + ctor + assignment — **dead injection, never called** | **yes** | remove entirely (ctor arity −1) |
| A7 | `service/mobile/MobilePalletizingService.java:50,67,82,217-224` | field + ctor + **working** retry in `scanPallet` (non-tx `:128`) | **KEEP** | none — sole live consumer |
| A8 | `unit/service/PickingorderBusinessServiceUnitTest.java:10,100,108` | `@Mock OptimisticLockRetry` + `@InjectMocks` | **yes** | drop the mock field/import |
| A9 | `unit/service/UnitloadBusinessServiceUnitTest.java:16,65,70` | `@Mock OptimisticLockRetry` + `@InjectMocks` | **yes** | drop the mock field/import |
| A10 | `unit/service/UnitloadBusinessServiceUnitTest.java:712-735` | `shouldHandleOptimisticLockingException` — exercises the retry against a mocked repo (the mock throws synchronously, so the retry DOES fire in this harness, unlike at runtime) | **yes** | **delete — because the wrapped construct is removed**, not because the test is wrong in its own mock context (Architect A4) |
| A11 | `unit/service/mobile/MobilePalletizingServiceUnitTest.java:13,79,84` | `@Mock OptimisticLockRetry` + `@InjectMocks` | **keep** | none |
| A12 | `unit/service/mobile/MobilePalletizingServiceTest.java:84,98` | positional `new MobilePalletizingService(..., new OptimisticLockRetry(), ...)` | **keep** | none — positional arg unaffected |
| A13 | `unit/util/OptimisticLockRetryTest.java` (whole) | tests of the utility | **keep** | none — utility survives |

### Phase B — MultiTenantJwtDecoder (audit item 5)

| # | File:line | Construct | In scope? | Action |
|---|---|---|---|---|
| B1 | `landlord/config/MultiTenantJwtDecoder.java:16-17,30` | `import java.util.concurrent.ConcurrentHashMap` + never-evicted `Map<String,JwtDecoder>` | **yes** | replace with Caffeine `Cache<String,JwtDecoder>` |
| B2 | `landlord/config/MultiTenantJwtDecoder.java:25-29` | GAP-F comment (the spec) | **yes** | rewrite to describe the implemented TTL cache + the deferred rebuild |
| B3 | `landlord/config/MultiTenantJwtDecoder.java:39-51` | `decode()` | **yes (no behavior change)** | leave logic; only the backing store under it changes |
| B4 | `landlord/config/MultiTenantJwtDecoder.java:53-80` | `getJwtDecoder` — fast-path + `computeIfAbsent` | **yes** | port to `cache.get(key, fn)`; keep "resolve config first" structure |
| B5 | `landlord/config/MultiTenantJwtDecoder.java:82-91` | `getDefaultJwtDecoder` — `computeIfAbsent("default", …)` | **yes** | port to `cache.get("default", fn)` |
| B6 | `SecurityConfiguration.java:52,69,74,108` | `multiTenantJwtDecoder` field/ctor + `.decoder(...)` wiring | reference | none — wiring unchanged |
| B7 | `landlord/config/TenantKeyBuilder.java:18-26` | `buildKey` at decode time | reference | none |
| B8 | `service/MultiTenantKeycloakService.getCurrentTenantAuthConfig` | resolves `TenantAuthConfiguration` | reference | none |
| B9 | `unit/config/SecurityConfigurationTest.java:5,28` | `@Mock MultiTenantJwtDecoder` | regression guard | none |
| B10 | `unit/config/README.md:14,53` | claims `MultiTenantJwtDecoderUnitTest.java` (24 tests) — **DRIFT: file does NOT exist** | **yes** | create the test + reconcile README count |
| B11 | `pom.xml:57-58` | `com.github.ben-manes.caffeine:caffeine` already present | enabler | none — no new dependency |

### Phase C — HTTP-in-Tx regression guard (audit item 3, retracted)

| # | File:line | Construct | In scope? | Action |
|---|---|---|---|---|
| C1 | `unit/config/TransactionManagerArchTest.java` (pattern) | existing ArchUnit harness (`ClassFileImporter` + `methods().that().areAnnotatedWith(...)`) | reference | **reuse pattern** for the new rule |
| C2 | `service/HttpRestService.java:32,53,71` | `post` / `postWithIdempotencyKey` / `get` — the methods the guard bans inside tx | reference | none — target of the guard |
| C3 | `service/MessageService.java:114-156` | `resendMessage` — **non-transactional** HTTP-then-DB (the audit's true site) | reference | none — already safe; guard locks it in |
| C4 | `service/BillofladingService.java:1060-1066` | `getFacilities()` — **non-transactional** `httpRestService.get` | reference | none — verified non-tx, guard passes clean |
| C5 | `service/OmsNotificationService.java:103-135`, `service/job/OutboxDispatchService.java:130-167`, `schedulejob/StockSummaryExportJob.java:299-320` | canonical POST-with-no-tx-held | reference | none — guard passes clean |
| C6 | `controller/ItemDataController.java`, `controller/AdminActionController.java`, `controller/MessageDummyController.java` | controller-layer `httpRestService` callers (non-tx) | reference | none — controllers carry no `@Transactional`; guard scoped to `net.aim_ai.wms` confirms |
| C7 | `unit/config/<new>HttpInTransactionArchTest.java` | the new ArchUnit guard | **yes** | create |

**Explicitly excluded:** the audit's original "migrate `MessageService.sendMessage` off HTTP-inside-REQUIRES_NEW" — no such method exists (bundle headline + §10.1); outbox migration of `resendMessage` (SBDEV-2238-4.x owns it).

---

## §1 Problem Statement

Three independent hardening items surfaced by the 2026-06-10 horizontal-scalability readiness audit (§8 items 3–5). `v2/wms2-api` runs as **multiple replicas behind a load balancer**; each defect either grows in-JVM state unboundedly, misleads maintainers, or leaves a safety property unguarded.

1. **Phase B — unbounded, never-refreshed JWT-decoder cache.** `MultiTenantJwtDecoder` caches one `NimbusJwtDecoder` per tenant key in a `ConcurrentHashMap` that is **never evicted** (`MultiTenantJwtDecoder.java:30`, GAP-F comment `:25-29`). The map grows **O(tenants)** for the JVM's lifetime and **never picks up landlord auth-config changes** — if a tenant's `serverUrl`/`realm` changes in the landlord DB, the stale decoder is used until JVM restart. This is the only item with a live runtime defect today. (Audit §5.8, item 5.)
2. **Phase A — inert retry wrappers masking conflict handling.** `OptimisticLockRetry.executeWithRetry` only catches `ObjectOptimisticLockingFailureException`/`StaleObjectStateException`, which Hibernate throws at **flush/commit** — *outside* the retry loop when the loop runs inside an already-open `@Transactional` (`confirmPick:580-589`, `transferUnitLoadToLocation:176-181`). The retry therefore **never fires**: it is misleading dead code that implies conflict handling where none happens, and `MobileReplenishService` injects the utility but **never calls it at all** (dead injection). (Audit §5.7, item 4.)
3. **Phase C — HTTP-in-transaction safety is unguarded.** No `@Transactional` method in `net.aim_ai.wms` currently calls `HttpRestService` (verified: `resendMessage` is non-tx, `BillofladingService.getFacilities` is non-tx, the OMS/outbox/export paths POST after commit). But **no test asserts this** — a future edit could silently add an HTTP round-trip inside a tenant transaction, holding a tenant DB connection across an external call (the exact anti-pattern the audit's original item 3 *thought* it had found). The guard is **annotation-shaped, not connection-shaped**: it prevents the direct/annotation-level reintroduction (a `@Transactional` method calling `HttpRestService`); a transitive variant (a `@Transactional` caller invoking a non-annotated helper that does the HTTP) is out of guard scope — a connection-scoped transitive rule would false-positive on legitimate after-commit registration paths like `OmsNotificationService.sendAfterCommit`. (Audit §8 item 3, retracted → regression guard.)

---

## §2 Current Architecture (file:line + verbatim)

### Phase A — OptimisticLockRetry

- **The utility is inert inside an open tx.** `OptimisticLockRetry.executeWithRetry` catches only `ObjectOptimisticLockingFailureException | StaleObjectStateException`; its own javadoc says *"The supplier MUST re-fetch the entity inside the lambda to get the latest version."* These are thrown by Hibernate **at flush/commit**, not at `save()` while the entity is managed in an open transaction — so inside `@Transactional` the failure surfaces at the **outer** commit, outside the loop. (Bundle §1, audit §5.7.)
- **`confirmPick`** (`PickingorderBusinessService.java:495 @Transactional(value="tenantTransactionManager", …)`) already takes pessimistic locks (`:528 customerorderRepository.findByIdForUpdate(...)`, `:531 pickingorderRepository.findByIdForUpdate(...)`, `:618 …findByIdForUpdate(...)`). The retry lambda at `:580-589` re-fetches `pickingorderPositionRepository.findById(pickingPositionId)` and re-applies the same five setters already applied to the managed entity at `:570-574`. Re-fetch is **redundant**; path is serialized by the CO/PO pessimistic locks.
- **`transferUnitLoadToLocation`** (`UnitloadBusinessService.java:112 @Transactional(value="tenantTransactionManager", …)`) — retry lambda `:176-181` clears `carrierunitloadId` on a re-fetched unitload, duplicating `:174 unitload.setCarrierunitloadId(null)`. Inside the open tx the `save` is a no-op flush; the retry never fires.
- **`scanPallet`** (`MobilePalletizingService.java:128`) has **no** `@Transactional` (verified — no method or class annotation) → auto-commit, each `save` commits immediately, so `ObjectOptimisticLockingFailureException` **can** be thrown synchronously inside the lambda → retry is **functional**. `:230-245` afterCommit/sync branch confirms the deliberate no-enclosing-tx design.
- **`MobileReplenishService`** injects the utility (`:74` field, `:97` ctor, `:116` assignment) but grep finds **zero** `optimisticLockRetry.` call sites → dead injection.

### Phase B — MultiTenantJwtDecoder

- `MultiTenantJwtDecoder.java:30`: `private final Map<String, JwtDecoder> jwtDecoders = new ConcurrentHashMap<>();` — never evicted (GAP-F comment `:25-29`).
- `decode(String token)` (`:39-51`): reads `TenantContext.getCurrentTenant()` (TenantContext **is** available at decode time — `TenantFilter` runs before `BearerTokenAuthenticationFilter`), builds `tenantKey` via `TenantKeyBuilder.buildKey`, resolves a `JwtDecoder`, then `decoder.decode(token)`. `TenantException` → wrapped as `JwtException` (`:48`).
- `getJwtDecoder` (`:53-80`): fast-path `jwtDecoders.get(tenantKey)`; else resolves `multiTenantKeycloakService.getCurrentTenantAuthConfig()` (`:67`) for `serverUrl`+`realm`, builds `jwkSetUri = serverUrl + "/realms/" + realm + "/protocol/openid-connect/certs"` (`:74`), then `jwtDecoders.computeIfAbsent(tenantKey, key -> NimbusJwtDecoder.withJwkSetUri(jwkSetUri).build())` (`:75-79`). Comment `:64-66` notes config is resolved **before** `computeIfAbsent` to avoid `ConcurrentHashMap` recursive-update.
- `getDefaultJwtDecoder` (`:82-91`): `computeIfAbsent("default", …)`.
- Wired at `SecurityConfiguration.java:108` `.decoder(multiTenantJwtDecoder)`.
- **Established Caffeine idiom to mirror** (`KeycloakService.java:61`):
  ```java
  private final Cache<String, UserRepresentation> userCache = Caffeine.newBuilder()
      .expireAfterWrite(15, TimeUnit.MINUTES)
      .maximumSize(500)
      .build();
  ```
- `NimbusJwtDecoder.withJwkSetUri` builds a `RemoteJWKSet` that already auto-refetches the JWKS on an **unknown `kid`** (the normal rotation case), with internal caching + rate limiter. The residual gap is (a) unbounded growth + stale landlord config, and (b) the rare same-`kid` rotation. **TTL is the primary, defensible fix.** (Bundle §1.)

### Phase C — HTTP-in-tx guard

- `HttpRestService.java` exposes `post` (`:32`), `postWithIdempotencyKey` (`:53`), `get` (`:71`) — the external-I/O surface the guard bans inside a transaction.
- Existing ArchUnit harness lives in `unit/config/`: `TransactionManagerArchTest`, `OptionalSafetyArchTest`, `ParallelStreamSafetyArchTest`, all using `ClassFileImporter().withImportOption(DO_NOT_INCLUDE_TESTS).importPackages("net.aim_ai.wms…")` + `methods().that().areAnnotatedWith(...)`. Snapshot store at `src/test/resources/archunit_store/` (config `archunit.properties`).
- **Clean-tree state verified:** the only service-layer `httpRestService` callers (`MessageService.resendMessage`, `BillofladingService.getFacilities`) are **non-transactional**; OMS/outbox/export paths POST after commit; controllers carry no `@Transactional`. The guard passes on a clean tree.

---

## §3 Design

### 3.A — OptimisticLockRetry cleanup (Phase A)

**Rationale.** The two wrapped paths run inside open tenant transactions where the catch can never trigger; the wrappers are misleading. The deletion is **behavior-neutral**: the optimistic-lock failure still surfaces at outer commit and is mapped to HTTP 409 by `RestExceptionHandler` (unchanged).

**`PickingorderBusinessService.confirmPick:580-589`** — delete the `executeWithRetry(() -> { … })` wrapper. The in-method mutation at `:570-574` already sets `state`/`picktounitloadId`/`amountpicked`/`pickfromstockunitId`/`pickedbyoperatorId` on the managed `pickingPosition`; keep them. **Note (Architect A2): there is no pre-existing post-mutation save outside the deleted lambda** — the only `save(pickingPosition)` between `:495` and `:640` is inside the lambda — so the implementer must **add** exactly one `pickingorderPositionRepository.save(pickingPosition)` after `:574` when deleting the wrapper. No re-fetch (entity managed; path serialized by CO/PO `findByIdForUpdate`).

**`UnitloadBusinessService.transferUnitLoadToLocation:176-181`** — replace the wrapper with the plain lines already present at `:174`:
```java
unitload.setCarrierunitloadId(null);
unitload = unitloadRepository.save(unitload);
```

**Injection removal** (constructor arity −1 each):
- `PickingorderBusinessService` — drop field `:65`, ctor param `:90`, assignment `:111`.
- `UnitloadBusinessService` — drop field `:54`, ctor param `:68`, assignment `:78`.
- `MobileReplenishService` — drop import `:20`, field `:74`, ctor param `:97`, assignment `:116` (dead injection).

**Keep:** `OptimisticLockRetry.java` (`@Component`, one consumer remains), `MobilePalletizingService` injection + `scanPallet:217-224` working retry, `OptimisticLockRetryTest`.

**Tx boundaries:** unchanged — no `@Transactional` annotation added or removed. **Config keys / metrics:** none.

**Signatures changed:** constructors of the three trimmed services (one fewer param each). Spring resolves remaining ctor args by type; `@InjectMocks` tests just drop the obsolete `@Mock`.

### 3.B — MultiTenantJwtDecoder Caffeine TTL (Phase B)

**Rationale.** Bound memory and propagate landlord auth-config changes within a fixed window, mirroring the one existing in-repo Caffeine usage (`KeycloakService:61`). **TTL-only** — no rebuild-on-exception (security: rebuild-on-every-`JwtException` is a JWKS-refetch DoS amplification surface; deferred behind §10 open question).

**Field replacement** (`:16-17,30`):
```java
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import java.time.Duration;
// (remove import java.util.Map; import java.util.concurrent.ConcurrentHashMap;)

// Bounded per-tenant JWT decoder cache. 24 h TTL closes GAP F: entries no longer
// grow unboundedly, and a tenant's landlord auth-config change (serverUrl/realm)
// is picked up within the TTL instead of never. NimbusJwtDecoder's RemoteJWKSet
// already auto-refetches the JWKS on an unknown kid, covering normal key rotation.
// Hard-coded TTL/size mirrors the KeycloakService:61 precedent; rebuild-on-JwtException
// is intentionally NOT implemented (DoS-amplification surface — see plan §10).
private final Cache<String, JwtDecoder> jwtDecoders = Caffeine.newBuilder()
        .expireAfterWrite(Duration.ofHours(24))
        .maximumSize(200)
        .build();
```

**`getJwtDecoder` (`:53-80`)** — keep the structure (fast path optional; resolve config before building, preserving default-decoder fallback semantics), swap the terminal `computeIfAbsent` for Caffeine `get(key, mappingFn)`:
```java
return jwtDecoders.get(tenantKey, key -> {
    LOG.info("Creating JWT decoder for tenant: {}-{} with JWK Set URI: {}",
        tenantProfile.getTenantName(), tenantProfile.getFacilityCode(), jwkSetUri);
    return NimbusJwtDecoder.withJwkSetUri(jwkSetUri).build();
});
```
The `:64-66` "resolve config before computeIfAbsent to avoid recursive update" guard is no longer strictly required (Caffeine permits re-entrant `get` for a different key), but **keep the structure** to preserve default-decoder fallback and avoid behavior drift. The fast-path `jwtDecoders.get(tenantKey)` can be dropped (Caffeine `get(key, fn)` is itself the fast path) — implementer's choice; keeping it is harmless.

**`getDefaultJwtDecoder` (`:82-91`)** — port to `jwtDecoders.get("default", key -> { … })`; preserve the `IllegalStateException` when `defaultIssuerUri` is empty.

**`decode()` (`:39-51`)** — unchanged. **No rebuild-on-exception** in v1.

**Signature changed:** none. Spring wiring (`SecurityConfiguration:108`) unchanged.

**Decision — hard-coded vs property TTL:** **hard-code 24 h / size 200** with the code comment above, per `KeycloakService:61` precedent (smallest diff, matches the only existing in-repo Caffeine usage). *Alternative (rejected for v1):* property keys `rest.security.jwt-decoder.cache-ttl-hours` / `…cache-max-size` — adds `@Value` wiring + config-test surface for a value nobody is expected to tune.

**Config keys / new dependency:** none (Caffeine on classpath `pom.xml:57-58`). **Metrics:** none required (could add `recordStats()` later; out of scope).

**Test seam (Architect A1 — REQUIRED spec for the new unit test):** `MultiTenantJwtDecoder`'s only ctor dep is `MultiTenantKeycloakService` (mockable); but `cachesDecoderPerTenantKey` / `buildsDecoderFromTenantJwkSetUri` cannot count builds or avoid a live JWKS fetch without a seam. Use `try (MockedStatic<NimbusJwtDecoder> ms = mockStatic(NimbusJwtDecoder.class))` (mockito-inline is on the classpath, `pom.xml:337-338`; precedent in `OmsNotificationServiceUnitTest`) returning a mock builder/decoder, and `verify` the build count. The default-issuer branch uses `ReflectionTestUtils.setField(decoder, "defaultIssuerUri", …)`. Tenant context via `TenantContext.setCurrentTenant(profile)` / `TenantContext.clear()` in `@BeforeEach`/`@AfterEach` (established idiom in 10+ tests).

### 3.C — HTTP-in-tx regression guard (Phase C)

**Rationale.** Lock in the (currently-true) property that no `@Transactional` method calls `HttpRestService`, so a future edit can't silently reintroduce HTTP-inside-a-tenant-tx. Reuse the existing ArchUnit harness pattern (`TransactionManagerArchTest`).

**New test** `src/test/java/net/aim_ai/wms/unit/config/HttpInTransactionArchTest.java`:
```java
@DisplayName("HTTP-in-Transaction Architecture Tests")
class HttpInTransactionArchTest {
    private static JavaClasses appClasses;

    @BeforeAll
    static void importClasses() {
        appClasses = new ClassFileImporter()
            .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
            .importPackages("net.aim_ai.wms");
    }

    @Test
    @DisplayName("@Transactional methods must not call HttpRestService (HTTP inside a tenant tx holds a DB connection across external I/O)")
    void transactionalMethodsMustNotCallHttpRestService() {
        methods()
            .that().areAnnotatedWith(Transactional.class)
            .should(notCallHttpRestService())
            .because("an HTTP round-trip inside an open @Transactional holds the tenant DB "
                + "connection across external I/O — under multi-replica deployment this "
                + "starves the per-tenant Hikari pool. Defer HTTP to after-commit "
                + "(OmsNotificationService.sendAfterCommit) or run it non-transactionally "
                + "(MessageService.resendMessage).")
            .check(appClasses);
    }

    private static ArchCondition<JavaMethod> notCallHttpRestService() {
        return new ArchCondition<>("not call HttpRestService") {
            @Override
            public void check(JavaMethod method, ConditionEvents events) {
                method.getMethodCallsFromSelf().stream()
                    .filter(c -> c.getTargetOwner().isEquivalentTo(HttpRestService.class))
                    .forEach(c -> events.add(SimpleConditionEvent.violated(method, String.format(
                        "%s.%s() is @Transactional and calls HttpRestService.%s()",
                        method.getOwner().getSimpleName(), method.getName(),
                        c.getTarget().getName()))));
            }
        };
    }
}
```
**Note for implementer:** ArchUnit 1.3.0 (pom `:310-312`) — `getMethodCallsFromSelf()` / `getTargetOwner()` / `isEquivalentTo()` verified present in that API (Architect review §1d). Target-owner match uses `isEquivalentTo(HttpRestService.class)` (import the concrete class). **Annotation-type assumption (Architect A6):** the rule keys on `org.springframework.transaction.annotation.Transactional` (consistent with `TransactionManagerArchTest`); a `jakarta.transaction.Transactional` usage would not be covered — grep to confirm none exists before shipping (repo convention is Spring's annotation throughout). **Scope note:** this test imports the whole `net.aim_ai.wms` tree (broader than `TransactionManagerArchTest`'s `net.aim_ai.wms.service`) — intentional, so controllers/jobs are covered too; ArchUnit caches the import, cost acceptable. **No production code change.** Snapshot store: the rule is a live `methods().should(...)` check, not a `FreezingArchRule` — it does **not** add a frozen-violations file (unlike the `archunit_store/` snapshot used elsewhere), so no store regeneration needed unless the implementer chooses freezing (see §10).

---

## §4 File Change Summary

| Phase | File | Change | Type |
|---|---|---|---|
| A | `service/PickingorderBusinessService.java` | remove `OptimisticLockRetry` injection; replace inert retry at `:580-589` with plain mutate+save | edit |
| A | `service/UnitloadBusinessService.java` | remove injection; replace inert retry at `:176-181` with plain setter+save | edit |
| A | `service/mobile/MobileReplenishService.java` | remove dead injection (import/field/ctor/assignment) | edit |
| A | `unit/service/PickingorderBusinessServiceUnitTest.java` | drop `@Mock OptimisticLockRetry` | edit |
| A | `unit/service/UnitloadBusinessServiceUnitTest.java` | drop `@Mock OptimisticLockRetry`; **delete** `shouldHandleOptimisticLockingException` | edit |
| B | `landlord/config/MultiTenantJwtDecoder.java` | `ConcurrentHashMap` → Caffeine `Cache`; port `getJwtDecoder`/`getDefaultJwtDecoder`; rewrite GAP-F comment | edit |
| B | `unit/config/MultiTenantJwtDecoderUnitTest.java` | **create** (README already claims it exists) | new |
| B | `unit/config/README.md` | reconcile test-count drift for the now-real decoder test | edit |
| C | `unit/config/HttpInTransactionArchTest.java` | **create** ArchUnit guard | new |

**Unchanged (verified):** `util/OptimisticLockRetry.java`, `service/mobile/MobilePalletizingService.java`, `unit/util/OptimisticLockRetryTest.java`, `unit/service/mobile/MobilePalletizingService*Test.java`, `SecurityConfiguration.java`, `service/HttpRestService.java`, all callers in §0 marked "reference".

---

## §5 Phased Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Phase A | Phase B | Phase C |
|---|---|---|---|---|
| 1 | Database state (schema, rows, Flyway) | N/A — no DB touch | N/A — landlord-config read only, no schema | N/A — test-only |
| 2 | Feature flags / system properties | N/A — none introduced | N/A — TTL/size hard-coded | N/A |
| 3 | Config / env changes | N/A | N/A — no new property; **no Keycloak change** (TTL is internal; JWKS URIs and realms unchanged) | N/A |
| 4 | Deploy-order dependencies | N/A — independent | N/A — independent | N/A — independent |
| 5 | Data migration | N/A | N/A | N/A |
| 6 | External systems | N/A | N/A — Keycloak realms/clients untouched; only in-JVM cache lifetime changes | N/A |
| 7 | Access / permissions | N/A | N/A | N/A |
| 8 | Monitoring / alerts | N/A | N/A — no new metric in v1 | N/A |

All three phases are pure code/test changes with no runtime prerequisites. **Phase B explicitly needs no Keycloak-side change.**

### Phase A — OptimisticLockRetry cleanup

> **STATUS: IMPLEMENTED 2026-06-10** — commit `8864f5f` on `feature/260610-hardening-a-optimisticlockretry`, [PR #40](https://github.com/SiteBossInc/wms2-api/pull/40) → develop.
> TDD gate `OptimisticLockRetryScopeTest` 4/4; verify script Phase A **9/9 PASS**; `mvn clean test` on all touched suites 0 failures / 0 errors. Code review APPROVE (no criticals); ralph architect verification APPROVED.
> **Deviation from plan (in scope):** `UnitloadBusinessServiceUnitTest` had 11 pre-existing failures on develop (`@PersistenceContext` `entityManager` never injected by Mockito ctor injection; broken since the Fix-C re-fetch). Fixed via the `StockunitBusinessServiceUnitTest:91` `ReflectionTestUtils.setField` pattern — included in the Phase A commit.
> Docs updated: boundary-map §8.3 + log row, picking-workflow, stockunit-design, replenishment-design, cancel-cascade-workflow.

- **Goal:** delete two inert retry wrappers + three injections (one dead), preserving the live palletizing consumer and the utility.
- **Changes:** §3.A — edit 3 services + 2 test classes (one method deleted).
- **Testing:** `mvn test -Dtest=PickingorderBusinessServiceUnitTest,UnitloadBusinessServiceUnitTest,MobilePalletizingServiceUnitTest,MobilePalletizingServiceTest,OptimisticLockRetryTest`; clean compile of the three trimmed constructors.
- **Risk:** **LOW** (inert paths cannot regress; one test deletion).
- **Branch:** `feature/260610-hardening-a-optimisticlockretry`
- **Estimated effort:** ~0.5 day.

### Phase B — MultiTenantJwtDecoder Caffeine TTL

> **STATUS: IMPLEMENTED 2026-06-10** — commit `e04ced2` on `feature/260610-hardening-b-jwtdecoder-caffeine`, [PR #41](https://github.com/SiteBossInc/wms2-api/pull/41) → develop.
> TDD gate: 2 structural tests failed on ConcurrentHashMap → `MultiTenantJwtDecoderUnitTest` **9/9**; `SecurityConfigurationTest` 5/5; verify script Phase B **8/8 PASS**. Code review APPROVE; architect verification (THOROUGH, security path) APPROVED incl. Caffeine-port semantic-equivalence review.
> README drift fixed (phantom 24 → 9 tests; total 146 → 131). Docs updated: wms2/wms1 end-to-end request-journey.

- **Goal:** bound + time-expire the decoder cache; create the missing decoder unit test; fix README drift. TTL-only.
- **Changes:** §3.B — edit `MultiTenantJwtDecoder.java`; create `MultiTenantJwtDecoderUnitTest.java`; edit `unit/config/README.md`.
- **Testing:** `mvn test -Dtest=MultiTenantJwtDecoderUnitTest,SecurityConfigurationTest`; context-load sanity (`mvn clean compile` + Spring context — the decoder is a `@Component` in the security chain).
- **Risk:** **MEDIUM** (security filter path; TTL-only keeps blast radius small).
- **Branch:** `feature/260610-hardening-b-jwtdecoder-caffeine`
- **Estimated effort:** ~1 day (most of it the new 24-test class the README already promises).

### Phase C — HTTP-in-tx regression guard

> **STATUS: IMPLEMENTED 2026-06-10** — commit `c4a7579` on `feature/260610-hardening-c-http-in-tx-guard`, [PR #42](https://github.com/SiteBossInc/wms2-api/pull/42) → develop.
> Clean-tree pass 1/1; **failure demo executed** (seeded `@Transactional` on `resendMessage` → rule failed naming `MessageService.resendMessage() ... calls HttpRestService.post()` → reverted → pass); verify script Phase C **3/3 PASS**. Non-freezing rule; direct implementation (no ralph/TDD-gate — deliverable is itself a test; failure demo is the gate).

- **Goal:** ArchUnit rule + test asserting no `@Transactional` method in `net.aim_ai.wms` calls `HttpRestService`.
- **Changes:** §3.C — create `HttpInTransactionArchTest.java`. No production change.
- **Testing:** `mvn test -Dtest=HttpInTransactionArchTest` (must PASS on clean tree); failure-demo by temporarily annotating `MessageService.resendMessage` (see §7 manual plan), then revert.
- **Risk:** **LOW** (test-only; verified clean-tree pass).
- **Branch:** `feature/260610-hardening-c-http-in-tx-guard`
- **Estimated effort:** ~0.5 day.

---

## §6 Backward Compatibility

| Phase | API contract | DB / schema | Runtime behavior | Notes |
|---|---|---|---|---|
| A | none | none | **none** — inert retries never fired; 409 mapping at outer commit unchanged | only externally visible delta: the deleted test scenario no longer exists |
| B | none — `decode()` signature + Spring wiring unchanged | none | valid-token validation unchanged; decoders now expire after 24 h (rebuilt on next use, negligible latency); landlord config changes propagate within 24 h instead of never; cache memory bounded | TenantException→JwtException wrapping, JWKS URI construction, default-decoder fallback all unchanged |
| C | none | none | none — test-only | — |

### What Does NOT Change (from bundle §4)

- `createMessage` / `createServiceLog` signatures, the `REQUIRES_NEW` boundary, `MessageStatus` constants.
- `OmsNotificationService` / `OutboxDispatchService` / `StockSummaryExportJob` behavior; every `createMessage` caller.
- `MessageController.resend` behavior; `resendMessage` still swallows HTTP failure into a `FAILED` row and never throws.
- `MobilePalletizingService.scanPallet` retry; `OptimisticLockRetry` utility; the 409 optimistic-lock mapping; the CO/PO pessimistic-lock guards.
- `MultiTenantJwtDecoder.decode()` signature; `SecurityConfiguration:108` wiring; default-decoder fallback; JWKS URI string; `TenantException`→`JwtException` wrapping.
- No new sysprop, Flyway migration, Keycloak realm/client, or external endpoint.

---

## §7 Testing Strategy

### Unit tests (named, per phase)

| Phase | Test class | Method | Asserts |
|---|---|---|---|
| A | `PickingorderBusinessServiceUnitTest` | existing `confirmPick` happy-path tests | still green after ctor trim |
| A | `UnitloadBusinessServiceUnitTest` | existing `transferUnitLoadToLocation` tests | still green; `shouldHandleOptimisticLockingException` **deleted** |
| A | `MobilePalletizingServiceUnitTest` / `MobilePalletizingServiceTest` | existing retry tests | still green (consumer kept) |
| A | `OptimisticLockRetryTest` | existing utility tests | still green (utility kept) |
| B | `MultiTenantJwtDecoderUnitTest` (**new**) | `cachesDecoderPerTenantKey` | `NimbusJwtDecoder` build invoked **once** across two `decode()` calls for the same tenant key |
| B | `MultiTenantJwtDecoderUnitTest` | `fallsBackToDefaultDecoderWhenTenantNull` / `…WhenConfigNull` | default decoder used; no NPE |
| B | `MultiTenantJwtDecoderUnitTest` | `wrapsTenantExceptionAsJwtException` | `TenantException` from config resolve → `JwtException` |
| B | `MultiTenantJwtDecoderUnitTest` | `buildsDecoderFromTenantJwkSetUri` | URI = `serverUrl + "/realms/" + realm + "/protocol/openid-connect/certs"` |
| B | `MultiTenantJwtDecoderUnitTest` | (negative) `doesNotRebuildOnJwtException` | a `JwtException` from `decode` does **not** trigger a second build (TTL-only) |
| B | `SecurityConfigurationTest` | existing | still green (mock unchanged) |
| C | `HttpInTransactionArchTest` (**new**) | `transactionalMethodsMustNotCallHttpRestService` | PASS on clean tree |

> README reconciliation (B10): `unit/config/README.md:14,53` currently claims `MultiTenantJwtDecoderUnitTest` exists with 24 tests, and `:15` totals **146 tests / 6 classes**. Update **both** the per-class row AND the Total row (Architect A5) to the **actual** counts this class ships (the suite above is the core; expand toward the documented count or correct the numbers — no phantom claims).

### Integration tests

`mvn verify` (Testcontainers) is **unaffected** — no SQL/JPQL/migration/endpoint change. Run before each phase's merge to confirm no regression.

### Manual Test Plan (MANDATORY)

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| **A** — picking confirm smoke | dev tenant (e.g. wineco-dev2) | 1. Log into WMS mobile. 2. Confirm a pick on an open pickingorder position. | Pick confirms; position state advances; no 500; no behavior change vs pre-deploy. | |
| **A** — unitload transfer smoke | dev tenant | 1. Transfer a unit load to a new location via mobile/web. | Transfer succeeds; `carrierunitloadId` cleared; no 500. | |
| **B** — JWT login | dev tenant | 1. Fresh login (new browser/incognito) → exercise an authenticated endpoint. | Token validates; first request builds the decoder (log `Creating JWT decoder for tenant…`), subsequent requests reuse it. | |
| **B** — 24 h TTL behavior (optional live check; the build-once property is covered by the unit suite) | dev | 1. Leave a replica running > 24 h. 2. Log in → expect exactly one `Creating JWT decoder for tenant…` rebuild log line. | Decoder reused within TTL; rebuilt once after expiry; memory bounded (no unbounded growth). | |
| **B** — tenant auth-config change pickup | dev landlord DB | 1. Note current decoder works. 2. Change the tenant's `serverUrl`/`realm` in landlord `tenant_db_configuration`/auth config. 3. Within 24 h, a fresh login uses the **new** config (or force by restart for immediate confirmation in dev). | New config is picked up within the TTL window (vs never before). | |
| **C** — ArchUnit failure demo | local | 1. Temporarily add `@Transactional(value="tenantTransactionManager")` to `MessageService.resendMessage`. 2. `mvn test -Dtest=HttpInTransactionArchTest`. 3. **Revert.** | Test FAILS with a violation naming `MessageService.resendMessage() … calls HttpRestService.post()`; passes again after revert. | |

### Test execution (fill in after running)

| Command | Result | Pass/Fail/Skipped |
|---|---|---|
| `mvn test -Dtest=PickingorderBusinessServiceUnitTest,UnitloadBusinessServiceUnitTest,MobilePalletizingServiceUnitTest,OptimisticLockRetryTest` (A) | | |
| `mvn test -Dtest=MultiTenantJwtDecoderUnitTest,SecurityConfigurationTest` (B) | | |
| `mvn test -Dtest=HttpInTransactionArchTest` (C) | | |
| `mvn verify` (per phase before merge) | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| New integration/e2e tests | No SQL/endpoint/migration change; SHORT mode (no expanded test plan). |
| Rebuild-on-exception tests beyond the negative assertion | Rebuild path intentionally not implemented in v1 (§10). |

---

## §7b Horizontal Scalability Validation

| # | Concern | Phase A | Phase B | Phase C | Verdict | Evidence |
|---|---|---|---|---|---|---|
| 1 | In-JVM state | removes a stateless bean injection | **FIXES** unbounded `ConcurrentHashMap` → bounded TTL Caffeine | none | **Improved** | `MultiTenantJwtDecoder.java:30` → Caffeine `maximumSize(200)`; mirrors `KeycloakService:61` |
| 2 | Connection-pool math | unchanged | n/a (landlord-side decoder, no tenant pool) | guard prevents the **direct/annotation-level** reintroduction of HTTP-in-tx (transitive helper variant out of guard scope — Architect A3) | **OK / improved** | §0 C2-C6 verified non-tx |
| 3 | Scheduled jobs | none | none | none | OK | no `@Scheduled` touched |
| 4 | Long transactions | none (no tx added/removed) | none | guard bans the direct form of the worst long-tx pattern (`@Transactional` method → `HttpRestService`) | **OK / improved** | §3.C |
| 5 | Request affinity | none | decoder cache is per-replica but TTL-bounded; identical build on every replica → no affinity needed | none | OK | each replica independently builds the same decoder from the same JWKS URI |
| 6 | Retry / idempotency | removes inert retry (no behavior change); 409 retry path intact | TTL eviction is idempotent (any replica rebuilds identically) | none | OK | `RestExceptionHandler` 409 unchanged |
| 7 | Tenant context | none | **reads `TenantContext` at decode time — available** (TenantFilter precedes auth filter) | none | OK | `MultiTenantJwtDecoder.java:41` |
| 8 | Distributed lock correctness | CO/PO `findByIdForUpdate` pessimistic locks unchanged | none | none | OK | `confirmPick:528,531` untouched |
| 9 | Cache invalidation | none | **adds** TTL eviction (24 h cross-replica staleness bound); no `@Cacheable` entity cache touched | none | **Improved** | each replica expires independently at 24 h |
| 10 | External notifications | none | none | **guards** the direct/annotation-level form of the "HTTP inside a tx" anti-pattern (not the transitive extract-into-helper variant) | **OK / improved** | §3.C rule |

### Evidence (for any improved/Yes row)

| Concern # | What | Reference |
|---|---|---|
| 1, 9 | `ConcurrentHashMap` → Caffeine `expireAfterWrite(24h).maximumSize(200)` | `MultiTenantJwtDecoder.java:30` (Phase B) |
| 2, 4, 10 | ArchUnit guard bans `@Transactional` → `HttpRestService` | new `HttpInTransactionArchTest` (Phase C) |
| 7 | `TenantContext.getCurrentTenant()` available at decode time | `MultiTenantJwtDecoder.java:41`; `TenantFilter` precedes `BearerTokenAuthenticationFilter` |

---

## §7c v2-Only Constraint Checklist

| Constraint | Verdict | Evidence |
|---|---|---|
| OSIV disabled | OK — no new lazy-load surface | Phase A operates on managed entities; Phase B is landlord-config; Phase C test-only |
| Tenant TM on tenant writes | OK | Phase A removes no tx annotation; `confirmPick`/`transferUnitLoadToLocation` keep `value="tenantTransactionManager"`; Phase B is landlord-config (no tenant tx) |
| `rollbackFor={BusinessException,FacadeException}` | N/A for touched methods | no `@Transactional` annotation added/changed |
| readOnly correctness | OK — no read-only method touched | — |
| Cache invalidation | OK / improved | Phase B *adds* TTL eviction; no `@Cacheable` entity cache touched |
| Micrometer | OK — no new metric in v1 | optional `recordStats()` deferred |
| Jakarta namespace | OK | no `javax.*`; `JwtDecoder`/`JwtException` already `org.springframework…`; Caffeine import `com.github.benmanes.caffeine.cache.*` |
| H2-compatible test SQL | OK | no SQL/migration change |
| Base*Test conventions | OK | `MultiTenantJwtDecoderUnitTest` follows `SecurityConfigurationTest`; `HttpInTransactionArchTest` follows `TransactionManagerArchTest` |

---

## §8 Rollout Plan

- **Three independent branches → develop, no release-tag coupling.** Recommended order **A → B → C** (ascending decision-risk), but any order is safe (disjoint files).
  - `feature/260610-hardening-a-optimisticlockretry` → PR → develop.
  - `feature/260610-hardening-b-jwtdecoder-caffeine` → PR → develop.
  - `feature/260610-hardening-c-http-in-tx-guard` → PR → develop.
- Each PR: run `bash sbdocs/9-System/scripts/verify-260610-wms2-multi-replica-hardening.sh` (phase-scoped checks must pass) + the named `mvn test` + `mvn verify`.
- No coordinated deploy, no feature flag, no DB step. Standard dev → develop promotion per phase.
- Cross-link this plan from the audit report §8 items 3–5 and from SBDEV-2238 (outbox owns the deferred `resendMessage` migration).

---

## §9 Alternatives Considered + Acceptance

### Alternatives (condensed from bundle §8)

**Phase A.** (1) Make the inert retries functional with `REQUIRES_NEW` per attempt — rejected (user decision + merit: CO/PO pessimistic locks already serialize; optimistic retry on top is redundant and worsens pool math). (2) Keep injection, delete only wrappers — rejected (leaves dead fields/params = slop). (3) Delete `OptimisticLockRetry` entirely — rejected (`scanPallet` is a legitimate non-tx consumer).

**Phase B.** (1) Spring `CacheManager`-backed `@Cacheable` decoder — rejected (decoder is a low-level filter-chain bean, not a service method; Caffeine `Cache` à la `KeycloakService` is the idiom, avoids proxy/self-invocation concerns). (2) Rebuild on every `JwtException` — rejected (security: JWKS-refetch DoS amplification). (3) **TTL-only — selected** (lowest blast radius; Nimbus `RemoteJWKSet` already auto-refetches on unknown `kid`). (4) Periodic background refresh — rejected (more moving parts than `expireAfterWrite`). (5) Property-driven TTL — rejected for v1 (hard-coded per `KeycloakService` precedent).

**Phase C.** (1) Restructure `resendMessage` — rejected (bundle §10; already non-tx). (2) Close out with no code — rejected (leaves the safety property unguarded). (3) **Regression guard — selected** (provable, zero production change).

### Acceptance script

`sbdocs/9-System/scripts/verify-260610-wms2-multi-replica-hardening.sh` (authored alongside this plan, before implementation). Each rollout item is a grep/test assertion (positive + negative). Checks the script encodes:

**Phase A:**
- `check_a_retry_removed_picking` (NEG): `grep -n "optimisticLockRetry\|executeWithRetry" service/PickingorderBusinessService.java` → **0 hits**.
- `check_a_retry_removed_unitload` (NEG): same grep on `UnitloadBusinessService.java` → **0 hits**.
- `check_a_injection_removed_replenish` (NEG): `grep -n "OptimisticLockRetry\|optimisticLockRetry" service/mobile/MobileReplenishService.java` → **0 hits**.
- `check_a_palletizing_kept` (POS): `grep -n "optimisticLockRetry\|executeWithRetry" service/mobile/MobilePalletizingService.java` → **≥1 hit** (consumer preserved).
- `check_a_utility_kept` (POS): `test -f util/OptimisticLockRetry.java` and `test -f .../unit/util/OptimisticLockRetryTest.java`.
- `check_a_test_deleted` (NEG): `grep -rn "shouldHandleOptimisticLockingException" src/test` → **0 hits**.
- (optional) `mvn test -Dtest=PickingorderBusinessServiceUnitTest,UnitloadBusinessServiceUnitTest,MobilePalletizingServiceUnitTest,OptimisticLockRetryTest`.

**Phase B:**
- `check_b_no_concurrenthashmap` (NEG): `grep -n "ConcurrentHashMap" landlord/config/MultiTenantJwtDecoder.java` → **0 hits**.
- `check_b_caffeine_present` (POS): `grep -n "Caffeine" landlord/config/MultiTenantJwtDecoder.java` → **≥1 hit** with `expireAfterWrite`.
- `check_b_ttl_24h` (POS): `grep -n "ofHours(24)\|24, TimeUnit.HOURS" landlord/config/MultiTenantJwtDecoder.java` → **≥1 hit**.
- `check_b_maxsize` (POS): `grep -n "maximumSize" landlord/config/MultiTenantJwtDecoder.java` → **≥1 hit**.
- `check_b_no_rebuild` (NEG): `grep -n "invalidate\|rebuild" landlord/config/MultiTenantJwtDecoder.java` → **0 hits** (TTL-only v1).
- `check_b_test_exists` (POS): `test -f .../unit/config/MultiTenantJwtDecoderUnitTest.java`.
- `check_b_readme_reconciled` (POS): README test-count row matches the shipped class (no phantom 24).
- `mvn test -Dtest=MultiTenantJwtDecoderUnitTest`.

**Phase C:**
- `check_c_guard_exists` (POS): `test -f .../unit/config/HttpInTransactionArchTest.java`.
- `check_c_guard_targets_httprestservice` (POS): `grep -n "HttpRestService" HttpInTransactionArchTest.java` → **≥1**; `grep -n "Transactional" …` → **≥1**.
- `check_c_guard_passes` (behavioral): `mvn test -Dtest=HttpInTransactionArchTest` → **PASS** (asserts the clean-tree property holds).

### Recommended OMC composition (for implementation)

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | 3 phases, ~6 prod/test files, single subsystem each, no contract change |
| Pre-draft step | analyst+planner (done) + **ralplan consensus** (this loop) | high-confidence scope already fixed in bundle §10 |
| Plan-review step | **critic** | Standard+ requires it (this consensus loop covers it) |
| Implementation shape | **executor** per phase (one branch each) | each phase is small and self-contained; verify-script is comprehensive |
| Verification step | **verify-script + verifier** | mandatory; run per phase |
| Code-review step | **code-reviewer** | security-path (Phase B) warrants a review pass |
| Commit step | **git directly** (3 atomic commits, one per phase/branch) | clean per-phase history |

---

## §10 Open Questions / Resolved Decisions

### Resolved (user, 2026-06-10 — binding, bundle §10)

1. **Phase C (item 3) = regression guard ONLY.** The audit's §5.5 `MessageService` finding was retracted same-day (agent conflated `createServiceLog:75` with `resendMessage:114`; source report corrected). Scope: ArchUnit rule + unit test asserting no `@Transactional` method in wms2-api calls `HttpRestService`; **NO** restructure of `resendMessage`; **NO** caller migration (SBDEV-2238-4.x owns outbox).
2. **Phase A (item 4):** remove inert wrappers + dead injection as analyzed; do **NOT** make retries functional; keep `MobilePalletizingService` consumer + the utility.
3. **Phase B (item 5):** **TTL-only v1** (Caffeine `expireAfterWrite` ~24 h, `maximumSize` ~200, `KeycloakService` idiom); **NO** rebuild-on-exception (deferred); create the missing `MultiTenantJwtDecoderUnitTest`; fix `unit/config/README.md` drift.
4. **Filename:** `sbdocs/1-Projects/wms2/plan/260610-wms2-multi-replica-hardening.md` (untracked; cross-link SBDEV-2238 + the 260610 audit report).
5. **Phasing:** 3 independent phases, order P4 (A) → P5 (B) → P3 (C), separate branches/PRs.

### Remaining open

- [ ] **Rebuild-on-exception deferred** — does the field actually see *same-`kid`* Keycloak key rotation (the only case Nimbus `RemoteJWKSet` does NOT auto-handle)? — If yes, a future plan adds a **scoped + rate-limited** rebuild (signature/kid failures only, ≥30s/tenant). If no, TTL-only is permanently sufficient. Needs a Keycloak rotation-policy answer.
- [ ] **ArchUnit store regeneration** — the Phase C rule is a live `methods().should(...)` check (no frozen-violations file). *If* the implementer chooses to make it a `FreezingArchRule` (to grandfather any pre-existing violation found at run time), `src/test/resources/archunit_store/` must be regenerated and committed. Default: **non-freezing** (clean-tree verified, so no grandfathering needed).
- [ ] **README documented count vs shipped tests (Phase B)** — `unit/config/README.md` claims 24 decoder tests; confirm whether a test class was previously deleted without README update, and either ship the full count or correct the number (no phantom claims).

---

## §11 ADR & Consensus Record

**Decision.** Ship three independent, separately-branched hardening phases: (A) delete the two inert `OptimisticLockRetry` wrappers and three injections (one dead), keeping the utility and its sole working consumer; (B) bound the per-tenant JWT-decoder cache with Caffeine `expireAfterWrite(24h)` + `maximumSize(200)`, TTL-only; (C) add an annotation-scoped ArchUnit regression guard banning `@Transactional` → `HttpRestService` calls.

**Drivers.** (1) Multi-replica safety + memory boundedness — the decoder map is the only live runtime defect (unbounded, never picks up landlord auth-config changes). (2) Reviewer trust — inert retries imply conflict handling that doesn't happen. (3) Lock in a currently-true safety property (no HTTP inside a tenant tx) that no test guards.

**Alternatives considered.** Per §9: make retries functional via REQUIRES_NEW (rejected — redundant under pessimistic locks, worsens pool math); rebuild decoder on every JwtException (rejected — JWKS-refetch DoS amplification); scoped rate-limited rebuild (deferred behind field evidence); property-driven TTL (rejected — `KeycloakService` hard-coded precedent); restructure `resendMessage` (rejected — already non-transactional; original audit finding retracted); connection-scoped transitive ArchUnit rule (rejected — false-positives on after-commit paths).

**Why chosen.** Lowest blast radius per item, zero new dependencies, every change mirrors an existing repo idiom, each phase independently shippable and machine-verifiable.

**Consequences.** Decoder memory bounded; landlord auth-config changes propagate within 24 h (was: never); same-`kid` rotation still requires TTL expiry (documented, deferred); the Phase C guard is annotation-shaped, not connection-shaped (disclosed in §1/§7b — the transitive extract-into-helper variant is out of guard scope); one mock-harness test deleted because its construct is removed.

**Follow-ups.** §10 open questions (same-`kid` rotation evidence → possible scoped rebuild plan; ArchUnit freezing choice; README count). `resendMessage` outbox migration remains owned by SBDEV-2238-4.x.

**Consensus record (ralplan, 2026-06-10).**
| Pass | Verdict |
|---|---|
| Planner draft | produced from analysis bundle `.omc/plans/260610-wms2-multi-replica-hardening-analysis.md` |
| Architect | **SOUND-WITH-AMENDMENTS** — all 5 load-bearing claims verified in code; amendments A1–A6 applied (A1 test seam, A2 explicit save, A3 guard-scope calibration, A4 test-deletion rationale, A5 README total, A6 annotation-type note + clean grep) |
| Critic | **APPROVE** — 0 critical, 0 major; 3 cosmetic notes (1 applied, 2 acknowledged) |
| User | Approved & saved 2026-06-10 (implementation deferred) |

**Acceptance script:** `sbdocs/9-System/scripts/verify-260610-wms2-multi-replica-hardening.sh` (baseline FAIL output captured below at plan creation; must show `0 fail` with `RUN_MVN=1` before any phase is declared done).

### Baseline verify output (2026-06-10, pre-implementation)

```
verify-260610-wms2-multi-replica-hardening — running acceptance checks
  PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api

Phase A — OptimisticLockRetry cleanup
  FAIL  A-pick      inert retry + injection gone from PickingorderBusinessService
  FAIL  A-pick-save  post-mutation save(pickingPosition) present (Architect A2)
  FAIL  A-ul        inert retry + injection gone from UnitloadBusinessService
  PASS  A-ul-clear  setCarrierunitloadId(null) retained
  FAIL  A-repl      dead injection gone from MobileReplenishService
  PASS  A-pall      working consumer kept in MobilePalletizingService
  PASS  A-util      OptimisticLockRetry utility + its test kept
  FAIL  A-test      shouldHandleOptimisticLockingException deleted
  FAIL  A-mocks     @Mock OptimisticLockRetry dropped from the two trimmed tests

Phase B — MultiTenantJwtDecoder Caffeine TTL
  FAIL  B-nochm     ConcurrentHashMap removed
  FAIL  B-caffeine  Caffeine.newBuilder() present
  FAIL  B-ttl       expireAfterWrite(Duration.ofHours(24))
  FAIL  B-maxsize   maximumSize bound present
  PASS  B-norebuild  no rebuild-on-exception path (TTL-only v1)
  FAIL  B-test      MultiTenantJwtDecoderUnitTest exists
  FAIL  B-seam      test uses mockStatic(NimbusJwtDecoder) seam (Architect A1)
  FAIL  B-readme    unit/config/README.md count matches shipped @Test count

Phase C — HTTP-in-tx regression guard
  FAIL  C-exists    HttpInTransactionArchTest exists
  FAIL  C-shape     guard targets @Transactional -> HttpRestService calls
  PASS  C-springtx  no jakarta.transaction.Transactional in main (A6 assumption)

  SKIP  A-mvn       Phase A touched suites pass  (set RUN_MVN=1 to execute)
  SKIP  B-mvn       MultiTenantJwtDecoderUnitTest passes  (set RUN_MVN=1 to execute)
  SKIP  C-mvn       HttpInTransactionArchTest passes  (set RUN_MVN=1 to execute)

Result: 5 pass, 15 fail, 3 skip
```
