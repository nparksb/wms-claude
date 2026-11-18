---
name: sbdev-3197-jwt-cachemap
description: "SBDEV-3197 — JwtAccessTokenCustomizer auth cache; the full-token compare is the ONLY cross-tenant guard; ON DEV — #651 c0bd417b, 2026-11-09"
metadata:
  node_type: memory
  type: project
  originSessionId: 84080b6f-e417-4a64-a861-704136a5f9bf
  modified: 2026-11-08T23:33:39.198Z
---

**SBDEV-3197 — ✓ merged(SBDEV-3197: #651 c0bd417b, 2026-11-09).** On dev (deployed `develop-c0bd417b`), re-tiered
T3→T2 by Nam 2026-11-09. Develop no longer has the `PassiveExpiringMap` shape.

**The load-bearing line (true before AND after the fix):** the cache is keyed by `preferred_username`,
which is NOT unique across tenants, so `isCacheValid`'s **full token-string comparison** is the only
thing preventing a cross-tenant authority leak. "Optimising" it to subject/expiry/username is the leak.
Pinned by `JwtAccessTokenCustomizerUnitTest.cachedAuthoritiesAreNeverServedToADifferentToken`.

**What changed:** Caffeine (2h / 1000) instead of
the unsynchronised, read-mutating `PassiveExpiringMap`; caches `(tokenValue, authorities)` and builds a
NEW `JwtAuthenticationToken` per call (caching the token object let `JwtAuthenticationProvider.setDetails`
leak request 1's details onto later requests); claim-less AND blank-username tokens not cached; the
customizer owns a private ObjectMapper (the `@Primary` one's timestamp serializers hit `SyspropService`);
`filterChain` takes the customizer + `CorsConfigurationSource` as injected params, and
`BeanMethodSelfInvocationArchTest` forbids `@Bean` self-invocation repo-wide (3 latent WebConfigurer /
RestConfiguration sites frozen in its allow-list).

**How it hid:** two of [[sbdev-3190-singleton-tenant-state]]'s rail blind spots at once — no stereotype
annotation AND a `final` field with mutable contents. Sweep for the OLD literal after a fix.

**Out of scope, filed:** SBDEV-4075 (was P82) — `MultiTenantJwtDecoder` validates no issuer or
audience (timestamps only).
