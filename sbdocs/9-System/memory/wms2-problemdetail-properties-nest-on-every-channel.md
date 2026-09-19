---
name: wms2-problemdetail-properties-nest-on-every-channel
description: "In wms2-api ProblemDetail setProperty values serialise under $.properties on EVERY channel (no ProblemDetailJacksonMixin anywhere) — but standaloneSetup DOES flatten them to the root, so the unit lane asserts a body shape production never emits"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 71657bb8-afdf-47d1-8cac-f5db05eda6e2
  modified: 2026-09-18T04:55:15.735Z
---

**`ProblemDetail.setProperty(...)` values appear at `$.properties.<key>`, not `$.<key>`, on every wms2-api channel — MVC and SDR/HAL alike.**

`ProblemDetailJacksonMixin` — whose `@JsonAnyGetter` does the root-flattening everyone expects — is registered **only** by `Jackson2ObjectMapperBuilder`. Its own javadoc excepts the case: *"unless an ObjectMapper is instantiated directly and configured for use"*. That is exactly what this app does:

- `WebConfigurer` declares an **`@Primary` bare `new ObjectMapper()`** and wires *that same instance* into `mappingJackson2HttpMessageConverter` → the MVC channel has no mixin.
- SDR's fallback converter is built on its own `basicObjectMapper()` → no mixin either.

So there is **no SDR-vs-MVC difference here**. Getting this wrong cost a review round on SBDEV-3420, where a javadoc confidently explained a channel difference that does not exist.

**Production shape is pinned** by `CustomerOrderControllerIntegrationTest`: `jsonPath("$.properties.retryable", is(false))` on a **plain MVC** route.

⚠ **`MockMvcBuilders.standaloneSetup` builds its OWN `Jackson2ObjectMapperBuilder` mapper, which DOES carry the mixin.** So the unit lane flattens to the root while production nests. `RestExceptionHandlerUnitTest`'s `assertThat(body).contains("\"retryable\":false")` assertions pass against a body shape **production never emits**. Assert error-body shape in the full-context lane (`BaseControllerIntegrationTest`) only — same family as [[wms2-controller-mappings-must-carry-v3-standalonesetup-cannot-see-it]]: standaloneSetup is systematically blind to whatever the real context configures.

**Don't read a root-level assertion as counter-evidence.** `SdrReadGateEnforcementContextTest` asserts `$.reason` at the root and is correct — that body is **not a `ProblemDetail`**. `FunctionGuardInterceptor` hand-builds a `LinkedHashMap`, and its comment says it does so *precisely because* the mixin is absent.

**Consequence for clients:** a UI reading `body.<key>` at the root for a `ProblemDetail`-backed error gets `undefined`. `wms2-mobile-ui/plugins/axios.js` reads only `reason`/`requiredFunction` and only on 403 — both from the hand-built interceptor body, so nothing is broken today. Anyone adding a root-keyed field to a `ProblemDetail` error will find it nested.

See also [[wms2-sdr-param-conversion-500-is-a-commons-exception]], [[wms2-businessexception-key-vs-message-traps]].
