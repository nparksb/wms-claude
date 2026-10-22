---
name: wms2-problemdetail-custom-properties-are-nested
description: "wms2-api ProblemDetail custom props: FLAT when a controller returns the ProblemDetail (measured live), NESTED under properties via the exception-handler path (pinned in IT) — clients must read both"
metadata:
  node_type: memory
  type: project
  originSessionId: d8604442-fd63-442e-8753-45c7e1cca1a5
  modified: 2026-10-06T17:55:08.822Z
---

The shape of a ProblemDetail's `setProperty()` fields depends on the path that produced it. Don't assume either shape; read both.

- **Controller returns `ResponseEntity<ProblemDetail>` → flat.** Measured on live dev 2026-10-07 (SBDEV-3626 claim endpoints, `ReplenishController.claimProblem`): `{"type":…,"status":409,"detail":…,"code":"REPLENISH_ALREADY_FINISHED","retryable":false}`.
- **Exception-handler path → nested** under `properties`. `CustomerOrderControllerIntegrationTest` pins `$.properties.retryable` (full context), and `FunctionGuardInterceptor`'s comment records the same nesting. Not re-measured live.
- `detail` and `status` are top-level on both paths.

**Why this note exists, and why it was corrected:** a conformance lane on SBDEV-3626 inferred "always nested" from the IT plus the `@Primary new ObjectMapper()` in `WebConfigurer`, and called the UI's `data.code` read a blocker. The UI was changed to read both shapes, which is right either way. The original version of this note repeated "always nested". The live dev run showed the claim endpoints are flat, so a reviewer's inference from one path was generalised to all of them. See [[a-zero-scan-needs-a-positive-control]] and [[green-tests-that-prove-nothing]].

**How to apply:**
- A UI reading a custom ProblemDetail property: `data.code ?? data.properties?.code`.
- Settle the shape for a given endpoint with one live call, not by reading the `ObjectMapper` config.
- API tests that check a body with `contains("\"code\":\"X\"")` pass for either shape.
