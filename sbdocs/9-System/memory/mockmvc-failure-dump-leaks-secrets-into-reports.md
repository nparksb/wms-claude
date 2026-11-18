---
name: mockmvc-failure-dump-leaks-secrets-into-reports
description: "A failing MockMvc assertion dumps the full response body into target/failsafe-reports, so an IT against Flyway-seeded credential rows writes the real secret to disk"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 18156d73-0126-470f-8a03-0c8b0759719b
  modified: 2026-11-14T11:02:29.470Z
---

An IT that reads a credential-bearing row (for example the Flyway `OMS_API_USER` sysprop on the Postgres+Flyway base) will copy the real value into `target/failsafe-reports/*.xml|txt` whenever it fails on the unfixed build. MockMvc prints the response on failure, and a failing `contains`/`isEqualTo` assertion echoes the value in its message. This happened on SBDEV-4133 at the TDD gate, where failing first is the whole point.

**Why:** gate tests are meant to fail first, and they run against the real Flyway seed, so the leak happens by design unless it is guarded. The reports persist in the worktree and get pasted into review lanes.

**How to apply:**
- In any IT that touches secret rows, use `@AutoConfigureMockMvc(print = MockMvcPrint.NONE)`.
- Assert on Flyway secret values as booleans only (`assertThat(body.contains(x)).as("raw value absent").isFalse()`), never with `contains(x)`, which echoes x.
- Use synthetic seeds (`"it-secret-" + RUN_ID`).
- After a red run, grep the reports for `MockHttpServletResponse` before sharing them.

Related: [[hub-wms2-test-harness]], [[hub-secrets-exposures]]
