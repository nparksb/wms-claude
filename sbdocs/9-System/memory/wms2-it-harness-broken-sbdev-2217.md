---
name: wms2-it-harness-broken-sbdev-2217
description: "v2/wms2-api Testcontainers Postgres IT lane is broken repo-wide (SBDEV-2217) — ITs can't run locally"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3889da24-2941-49de-ad73-50f36d7f30a1
---

The entire **v2/wms2-api Testcontainers PostgreSQL integration-test lane cannot boot** as of 2026-06-25. Two coupled causes:
- `AppPostgresDBSetupExtension` runs Flyway **without** the `integration` profile → migration `V1.2.01__utc_standard_tables.sql` fails with `relation "outbox_message" does not exist`.
- `BasePostgresIntegrationTest` cannot boot the landlord datasource (**SBDEV-2217**).

Evidence: the repo's existing `*ConcurrencyIT` classes and `ClientRepositoryIntegrationTest$GetTransactionDetailSmokeTest` are already `@Disabled` for this reason; running `ClientServiceE2ETest` reproduces the Flyway failure.

**UPDATE 2026-07-14 — a self-contained IT pattern that BOOTS exists (sidesteps the whole broken lane).** Reference: `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/service/mobile/MobileReplenishMultiUnitLoadIT.java` (plan 260713). It boots the FULL `StartApplication` context on `@ActiveProfiles("integration")` but: (1) `@DynamicPropertySource` starts a `postgres:12` `@Testcontainers` container and re-points BOTH `spring.datasource.*` AND `landlord.datasource.*` at it (fixing the landlord-datasource half); (2) runs Flyway over `classpath:db/migration` (the self-contained fresh-v2 base dump `V2.2.00`, which HAS the real schema incl. partial unique indexes) — NOT the broken `db/v1-to-v2-onboarding/schema` replay; (3) `spring.jpa.hibernate.ddl-auto=none` so Flyway owns the schema; (4) `@TestPropertySource` adds `spring.cache.type=none`, `app.cron.cleanup-rest-idempotency=-`, `app.cron.outbox-dispatcher=-`, pool>=2. Also: a direct service-bean call needs `TenantContext.setCurrentTenant(...)` in `@BeforeEach` (TenantFilter isn't in the path); to reproduce a deadlock, `ALTER DATABASE ... SET statement_timeout/lock_timeout` to bound it. Verified: IT compiles+runs green (~23s) with Docker + SDKMAN Java 21/Maven. So NEW v2 ITs CAN run green locally via this recipe — no need to blanket-`@Disabled` them.

The still-broken bits: the LEGACY lane (`AppPostgresDBSetupExtension` + `db/v1-to-v2-onboarding/schema` Flyway replay, `OutboxClaimOrderingIT`) stays red because that onboarding replay is broken from scratch (`V1.2.01__utc_standard_tables.sql:61` `SELECT 1 FROM outbox_message` sorts before `V2.1.11__add_outbox_message.sql` creates it). File separately if repairing the legacy lane. Mirrors the v1 side [[v1-its-blocked-roid-view-drift]]. See also [[wms2-requires-new-in-lock-holding-tx-deadlock]].

**How to apply while the legacy lane stays red:** gate v2 work on unit tests + `mvn clean compile` rather than the legacy IT lane, and leave the legacy ITs `@Disabled`.

**CORRECTION 2026-08-26:** the ticket id in this note's title is wrong as a pointer for IT-harness work. **SBDEV-2217 is the sequence-number `-1` bug and it is CLOSED** — not an IT-harness ticket. The live ticket that owns "the IT runs in neither Maven lane" is **SBDEV-3091** (Open); two more IT-lane traps were added there 2026-08-26. Do not widen 2217.
