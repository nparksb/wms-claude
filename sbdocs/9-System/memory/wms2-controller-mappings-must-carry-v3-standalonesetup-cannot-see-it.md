---
name: wms2-controller-mappings-must-carry-v3-standalonesetup-cannot-see-it
description: "wms2-api controllers must be @RequestMapping(\"/v3/...\") or the web UI 404s; standaloneSetup never applies the class prefix, so no unit test or verify row can catch a wrong one"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 1b9cf4f0-8bcb-4ecb-ad1f-d775f9530fa7
  modified: 2026-08-13T01:26:10.876Z
---

**Every hand-written controller in `wms2-api` must be `@RequestMapping("/v3/...")`.** The web and mobile UIs' axios `baseURL` ends in `/v3`, so a store action requesting `/foo/bar` puts `GET /v3/foo/bar` on the wire. A controller mapped without the prefix 404s for the UI — with **no exception and no stack trace**, only `WARN o.s.web.servlet.PageNotFound - No mapping for GET /v3/foo/bar`.

The only intentional non-`/v3` families: `/rest/*` (inbound OMS integration, `AbstractRestController`), `/api/public`, `/detrack`.

**Hit for real 2026-08-13.** `PutawayConfigController` shipped at `/putawayConfig`, making **all five** of its endpoints unreachable from the browser — `eligibleLocations`, `preview`, and the `sku`/`merchant`/`warehouse` writes. That is SBDEV-2732's entire typed putaway write surface *plus* SBDEV-2643's SKU dialog. Fixed by wms2-api PR #152 (merge `fdd5c7c`, commit `808f17a`): one line, no UI change, since the store's path is already relative to the `/v3` baseURL.

⚠ **THE REASON IT SURVIVED — this is the reusable part.** Nothing in the test surface can see a class-level prefix:

- controller checks assert the **method** annotation (`@GetMapping("/eligibleLocations")`);
- controller unit tests use `MockMvcBuilders.standaloneSetup`, which registers one controller **without applying its `@RequestMapping`**;
- so the full path an HTTP client actually calls is asserted **nowhere**.

It passed 2 tickets, 7 PRs, 289 UI tests, ~4,950 API tests and 94 acceptance-script rows. Only a `curl` could find it, and that manual row had not been run. **When a feature "works" in every test but fails in the browser with no stack trace, check the class-level mapping first.**

Guard now in place: `unit/controller/ControllerRequestMappingConventionUnitTest` — fails on a mapping outside the four families, and pins `PutawayConfigController` specifically. It **strips comments before matching**, because its first version failed against its own fix: the controller's javadoc quotes the old mapping while explaining the bug. Prefer stripping over forbidding documentation from naming the bad value — a warning that cannot name the hazard stops being a warning.

Related trap in the same file: `SecurityConfiguration` lists **both** `/v3/**` and `/putawayConfig/**`, because the un-prefixed path once fell through to `anyRequest().authenticated()` and was patched at the security layer while the mapping stayed wrong. A security matcher naming an odd path is a **smell that a mapping is wrong**, not evidence that the path is correct. The matcher is kept as a fail-safe.

See also [[verify-script-traps]] and [[negative-test-verify-scripts-before-trusting-them]] — same family: the check was true and irrelevant.
