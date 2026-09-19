---
name: wms2-sdr-is-gatable-via-mappedinterceptor-bean
description: Spring Data REST IS reachable by a HandlerInterceptor in wms2-api — as a MappedInterceptor @Bean, not via WebMvcConfigurer#addInterceptors; six src/main javadocs claim otherwise and are wrong
metadata:
  type: project
---

`RepositoryRestHandlerMapping` **is** reachable by a `HandlerInterceptor` in v2/wms2-api. Measured
2026-08-24 against `origin/develop` @ `b10b466` (SBDEV-3017 triage), not inferred:

| Registration of the *identical* probe interceptor | SDR `/v3/itemdata/search/findByItemNr` | MVC `/v3/system/mobileUiUrl` |
|---|---|---|
| `@Bean MappedInterceptor(new String[]{"/**"}, probe)` | **fires**; handler = `RepositorySearchController`; returning `false` → **403** | fires |
| `WebMvcConfigurer#addInterceptors` (what `WebConfig:34` does) | **never fires**, returns 200 | fires |

Same interceptor, same path, same context — only the registration API differs. `addInterceptors`
interceptors are set directly on the `requestMappingHandlerMapping` bean and never become context beans,
so `AbstractHandlerMapping#detectMappedInterceptors` (spring-webmvc 6.2.15:443 — it scans the context for
`MappedInterceptor` **beans**) cannot see them. SDR's mapping does get scanned, because
`RepositoryRestMvcConfiguration:693` calls `setApplicationContext` on it.

**Why:** six javadocs in `src/main` assert SDR is *structurally* ungatable and that only a servlet `Filter`
can reach it — `WebConfig:30`, `RestConfiguration:37`, `FunctionGuardInterceptor:65`, `RequiresFunction:38`,
`ReplenishController:65`, `FixLocationAssignmentRepository:28`. That is one assertion propagated six times,
and it is wrong. It has already steered two shipped designs (SBDEV-3013 door 1 chose verb withdrawal;
SBDEV-2968 §3.1-A9 concluded "and that is fine"). See [[wms2-only-one-of-80-functions-is-enforced]].

**How to apply:**
- Gating SDR needs a `MappedInterceptor` **bean**, ~10 lines. Do not reach for a `Filter`, and do not
  default to `@RestResource(exported = false)` — the surface is 61 exported repositories / ~313 exported
  query methods, so un-exporting does not scale.
- **The mechanism firing is not the same as the guard denying.** For SDR the declaring class is
  `RepositorySearchController`: no `@RequiresFunction`, not in `GUARDED`, so `FunctionGuardInterceptor`
  returns `true`. Testing the mechanism *with the real guard* yields 200 and reads as a refutation of a
  mechanism that worked. Prove the mechanism with a throwaway probe first; the rule source is a separate
  claim. Cf. [[advertised-capability-is-not-exploitable-capability]].
- Adding the bean means the guard also runs a second time on every MVC request (both
  `requestMappingHandlerMapping` and the bean scan pick it up), so `WebConfig:34` must be removed.
- A `MappedInterceptor` bean is resolved while SDR's handler mapping is being built, so a guard depending
  on `AccessService` → repositories is a boot-cycle risk. The `integration` profile boots; that is not
  proof for `dev`/`prd`. See [[verify-spring-bean-changes-clean-compile-and-context-load]].
