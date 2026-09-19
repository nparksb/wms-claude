---
name: spring-detectmappedinterceptors-matches-already-created-singleton
description: A MappedInterceptor @Bean whose DECLARED return type is widened is still found by detectMappedInterceptors if the singleton already exists — so gating becomes instantiation-order-dependent, not disabled
metadata:
  type: reference
---

`AbstractHandlerMapping#detectMappedInterceptors` calls
`beansOfTypeIncludingAncestors(ctx, MappedInterceptor.class, true, /* allowEagerInit */ false)`
(spring-webmvc 6.2.15:443). The natural conclusion — that a `@Bean` method whose **declared** return type is
widened from `MappedInterceptor` to `HandlerInterceptor` becomes invisible, disabling the interceptor — is
**wrong**.

Measured 2026-08-24 in v2/wms2-api (SBDEV-3017 slice A): with the return type widened, the interceptor was
still installed and `FunctionGateEnforcementPointContextTest` stayed **3/3 green**. By the time SDR's
`RepositoryRestHandlerMapping` initialises, that singleton already exists, so it is matched on its actual
runtime type despite `allowEagerInit=false`.

**Why:** the real risk is subtler and worse than "it breaks" — the interceptor's presence becomes dependent
on **bean-instantiation order**, which nothing in the app controls and no test observes. In an authorization
path that is a silent order-dependency rather than a loud failure. Pin the declared type for determinism,
but do not justify the pin by claiming a widened type disables the interceptor: that claim is false and is
the same plausible-but-unverified shape as the six javadocs described in
[[wms2-sdr-is-gatable-via-mappedinterceptor-bean]].

**How to apply:**
- Never state a Spring container-behaviour claim in a javadoc or a review without running the mutant.
  This one was caught only by the floor's mutation-check step, *after* being written into two files.
- Corollary worth knowing: `MappedInterceptor` beans reach EVERY `AbstractHandlerMapping`; interceptors
  registered via `WebMvcConfigurer#addInterceptors` reach only `requestMappingHandlerMapping`. Registering
  both installs the interceptor **twice** — measured, the chain read
  `[FunctionGuardInterceptor, FunctionGuardInterceptor, …]`. `AbstractHandlerMapping#getHandlerExecutionChain`
  (6.2.15:624-639) unwraps `MappedInterceptor` before adding it, so a duplicate is visible by counting
  instances in `HandlerExecutionChain#getInterceptorList()`.
