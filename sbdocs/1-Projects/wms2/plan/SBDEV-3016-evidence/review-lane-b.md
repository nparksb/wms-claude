# SBDEV-3016 PR #263 — Independent Review, Lane B

Repo: `v2/wms2-api` (worktree `.claude/worktrees/wms2-api/SBDEV-3016`), branch
`chore/SBDEV-3016-mangled-handler-name`, commit `d5a0d19f`, PR base `develop`.

## Verdict: **APPROVE**

No High or Medium findings. Three Low / informational findings below, none of
which block the merge.

## What the diff actually is

`git diff origin/develop` (as instructed) returns a ~230-line diff dominated by
`SdrCacheEvictionEventHandler.java` deletion, `ClientRepository.java`
`@CacheEvict` removal, and test churn. **That is base drift, not this PR.**
`origin/develop` has moved since the branch was cut — it now sits at
`3faa32b6` ("Merge pull request #262 ... SBDEV-3176-sdr-cache-eviction"),
89 commits²... actually just one merge ahead of this branch's actual parent.
Diffing the branch against the moving tip makes an unrelated, already-merged
PR (#262, SBDEV-3176) look like it's being reverted by #263.

The PR's real base is `92ca2e38` (confirmed via `git merge-base HEAD
origin/develop` = `92ca2e38`, and it long-predates `3faa32b6`). The actual
diff of this PR is:

```
git diff 92ca2e38 d5a0d19f --stat
 .../java/net/aim_ai/wms/controller/mobile/PickingController.java | 6 +++---
 1 file changed, 3 insertions(+), 3 deletions(-)
```

One file, three lines changed, exactly as described in the commit message and
PR body — a method rename plus two `LOG.debug` label corrections. Verified
below claim-by-claim.

## Claims checked

**1. Zero behavior change, URL contract untouched — CONFIRMED.**
`@GetMapping(path= "/pickingOrders/{input}", produces = "application/json")`
at `PickingController.java:239` is untouched (it's a context line in both
hunks, not part of the diff). Only the method identifier
(`requpickingOrdersestLocation` → `requestPickingOrders`, line 240) and two
`LOG.debug` string literals (lines 241, 303) changed. Spring routes on the
mapping annotation, never the Java method name, so this cannot change
routing.

**2. Authorization-neutral, end-to-end — CONFIRMED.**
- `PickingController` carries only a **class-level**
  `@RequiresFunction(WmsConstants.FunctionEnum.MOBILE_UI_VIEW_PICKING)`
  (`PickingController.java:33`) and no `@PublicHandler` anywhere in the file
  (`grep -n "PublicHandler|RequiresFunction"` on the file returns only the
  import and the class-level annotation).
- `PickingController.class` is a member of `FunctionGuardInterceptor.GUARDED`
  (`FunctionGuardInterceptor.java:123`).
- `FunctionGuardInterceptor.preHandle` resolves gating via
  `handlerMethod.getMethod().getDeclaringClass()` (line 175) plus
  `GUARDED.contains(declaring)` (line 244) and
  `handlerMethod.getMethodAnnotation(PublicHandler.class)` (line 210) —
  never a method-name string comparison.
- The three `getMethod().getName()` call sites in that interceptor
  (`FunctionGuardInterceptor.java:223`, `:234`, `:249`) are, respectively: a
  `LOG.error` message on the "both `@PublicHandler` and `@RequiresFunction`"
  conflict path (223, unreachable here — neither annotation is present at
  method level), a Micrometer counter tag on `METRIC_PUBLIC` that only
  increments inside the `@PublicHandler` short-circuit (234, this branch is
  never taken since `open` is null for this method), and a `LOG.error` on the
  "not in GUARDED" fail-closed path (249, doesn't apply — the class is in
  `GUARDED`). None of the three affects routing or authorization outcome for
  this handler.
- Net: the rename changes what a log line or an unreachable metric branch
  would print, never what gets enforced.

**3. Nothing else keys on the method name — could not refute, several places checked:**
- `FunctionGuardArchTest.java`: `GOLDEN_MAP` is keyed by class **simple name**
  only (`GOLDEN_MAP.put("PickingController", MOBILE_UI_VIEW_PICKING)`, line
  76). The file's other `Method::getName()` reflective lookups target
  unrelated symbols (`locationByLocationName`, `findByAssignedlocationId`,
  etc. in different services/repos) — none reference
  `requpickingOrdersestLocation`, `requestPickingOrders`, or
  `pickingOrderPositionsInfo`.
- `FunctionGuardStartupAssertion*.java`: builds violation-message strings
  from `handler.getMethod().getName()` at runtime (reflective, always
  current) — no hardcoded name to go stale.
- `src/test/resources/archunit_store/stored.rules`: the **only** frozen
  ArchUnit rule is the `Optional.get()` ban (SBDEV-2116), unrelated to
  controllers or method names; confirmed by `cat`, and confirmed untouched by
  this PR (`git diff <merge-base> HEAD -- src/test/resources/archunit_store`
  is empty).
- `PickingControllerUnitTest.java` (`pickingOrders` `@DisplayName` block,
  lines 248–283): drives the endpoint via MockMvc against the URL
  `/v3/picking/pickingOrders/SECTION-A`, never against the Java method name —
  consistent with the commit's mutation-check claim (breaking the
  `@GetMapping` path, not the method name, is what would turn these red).
- `wms2-mobile-ui/store/picking.js` (`getPickingOrders` action, ~line 399):
  calls `` this.$axios.$get(`/picking/pickingOrders/${data.value}`) `` — path
  only.
- Repo-wide grep for the old identifier `requpickingOrdersestLocation` across
  `*.java/*.md/*.js/*.vue`: zero hits in code; two hits in prose docs (see
  Low finding below).
- No verify script under `sbdocs/9-System/scripts/` references either name.

**4. Line 303 correctness — CONFIRMED.**
Read `PickingController.java:279–306`: the enclosing method is
`pickingOrderPositionsInfo(@PathVariable("id") Long id, ...)`, mapped at
`@GetMapping(path= "/pickingOrderPositionsInfo/{id}", ...)`. Its
`if (errors.size() == 0)` success branch at line 303 is where the debug log
sits — previously logging `"processLocation finished"`, which belongs to a
different, later method (`processLocation`, mapped separately at
`/processLocation/{id}/{input}`, starting ~line 311). The new label
`"pickingOrderPositionsInfo finished"` correctly names its own method. Not a
copy-paste from a shared helper — each method has its own log line.

**5. Downstream consequences of the rename — checked, one informational item found:**
- Micrometer/Actuator: Spring Boot's default `http.server.requests` tags by
  URI template, not handler method name; no custom `MeterFilter` or
  handler-name-keyed tag exists in `src/main/java/net/aim_ai/wms/config/`
  besides `FunctionGuardInterceptor`'s `METRIC_PUBLIC` counter (unreachable
  for this controller, see #2).
- Tracing: no `SpanNamer`/custom span-naming code found in the codebase.
- Log-based alerting: no dashboard/alert config or script anywhere under
  `sbdocs/9-System/scripts/` references the old strings `"scanPallet"` (in
  this context) or `"processLocation finished"`.
- **Swagger/SpringDoc `operationId` (Low, informational)** — neither handler
  carries an explicit `@Operation(operationId=...)`, so SpringDoc derives the
  OpenAPI `operationId` from the Java method name. This means the generated
  operationId for this endpoint silently changes from the old mangled name
  to `requestPickingOrders` as a side effect of the rename. No consumer was
  found: no committed OpenAPI spec, no generated-client/codegen setup for
  `v2/wms2-api` anywhere in the monorepo (the only committed `OpenAPI.json`
  files belong to the unrelated `v1/qa-api`), and SpringDoc's own UI is
  human-consumed. Flagging because the PR body doesn't mention it, not
  because it has any found blast radius.

**6. Commit message / PR body accuracy — spot-checked, accurate**, including
the specific line numbers it cites (`FunctionGuardInterceptor.java:223/234/249`,
`GUARDED` at `:123`, class-level annotation at `PickingController.java:33`)
and the "ArchUnit's only stored rule is the unrelated Optional.get() ban"
claim (verified verbatim against `archunit_store/stored.rules`).

## Findings

**Low — PR body's "Independent review lane: APPROVE" line predates the final diff.**
Per this task's own briefing, an earlier review lane approved a 2-line
version of this change; the line-241 log-label fix and the entire line-303
fix were added afterward and have had no independent review until this pass.
The PR body states "Independent review lane: APPROVE, one Low ... taken in
this diff" without qualifying that the approval covered an earlier revision.
Not a defect in the code — the code is correct (see #4) — but the
verification section overclaims coverage. This review supplies the missing
coverage; no further action needed once this report lands.

**Low — doc drift, not touched by this PR.**
- `v2/wms2-api/CLAUDE.md:282` still describes the mangled name
  `PickingController.requpickingOrdersestLocation` as "tracked as SBDEV-3016
  Fix 2" — i.e., framed as still-open work. Once this PR merges, that line
  should be updated (past tense, or removed) or it will read as inaccurate.
- `docs/plan/completed/PICKING_PERFORMANCE_PLAN.md:100` still lists the old
  mangled name in a table. This is inside a `completed/` plans folder — likely
  intended as a historical snapshot — so may not need changing, but flagging
  in case it's meant to track current state.
Neither file is part of this PR's diff; out of scope for this change to fix,
but worth a follow-up note on the ticket.

**Low/informational — Swagger operationId changes as a side effect.**
See item 5 above. No known consumer; flagged for completeness since the task
asked specifically to check for this class of consequence.

## Not verified (out of scope for a read-only lane)

- The commit's "Full unit suite 5982 pass / 0 fail" and mutation-check
  numbers were not independently re-run — the task constraints forbid `mvn`
  in this worktree, and another lane shares the repo. The claims are
  plausible and consistent with everything checked above (URL-path-based
  tests, no method-name dependencies found), but they are the one thing in
  the PR body this review cannot itself confirm.
- The "30 other sites across 10 mobile controllers" out-of-scope disclosure
  was not spot-checked line-by-line; it's explicitly filed as future work,
  not part of this PR's claims about itself.

## Verdict

**APPROVE.** Zero High/Medium findings. Three Low items above, none blocking.
