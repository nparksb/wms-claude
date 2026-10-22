# SBDEV-3873 — ralplan round 1, Critic review

- **Subject:** `plan-snapshot-r1.md` (fixed snapshot), with `analysis.md`, `db-verification.md`, `decisions-2026-10-22.md`
- **Verified against:** wms2-api `origin/develop` `bafa2301`, `release` `0300945b`, `main` `2f87e1ee`. wms2-web-ui `origin/develop`
  `98accaf`, `release` `ad6dc46`, `main` `0a2e178`. Both repos were fetched 2026-10-22, and every read below is `git show` /
  `git grep` against those refs. I did not use the working checkouts, ran no Maven and wrote nothing to any DB.
- **Mode:** started THOROUGH. Escalated to ADVERSARIAL after H1 plus four Mediums.

## VERDICT: ITERATE

**High 1 · Medium 4 · Low 9**

The design is sound: a typed endpoint, then withdrawal on the SBDEV-3545 precedent. The PR 2 test-pin inventory T1–T8 is
complete, and its numbers check out. Two things must change before approval:
- The plan's own Principle 3 is not enforced for the PR-W → PR 1 direction. Its mitigation reasoning is inverted.
- AC-4 and Fix A specify a 400 that the chosen exception cannot produce in this codebase.

Several "mutation-check" claims also rest on an instrument (PIT) that cannot produce the mutants that matter.

## Verified numbers and claims (pass)

| Claim | Evidence | Result |
|---|---|---|
| Tranche size 231 → 232 | `Sbdev3017TrancheGateContextTest.java:1112` `assertThat(EXPECTED).hasSize(231)`. `EXPECTED` is a map keyed on class+path, so a new key adds one. The drift test reports `ROUTE NOT DEPLOYED` for a row with no handler (`:972-975`), so AC-1 is red pre-fix for the right reason | ✓ |
| `WITHDRAWN` 51 → 53, `MUST_STAY_WRITABLE` 8 → 6 | `SdrWriteWithdrawalContextTest.java:228` `hasSize(51)` and `:336` `hasSize(8)`. `SDR_WRITE_WITHDRAWN` (RestConfiguration `:452-565`) holds 50 distinct classes, and 50 + UserRole = 51 | ✓ |
| T2 `checked` 7 → 6 | `MustStayWritableCollectionPostWithdrawalContextTest:33` `COVERED_ELSEWHERE = Set.of("Advice")`, `:38` Cyclecount row, `:78` `isEqualTo(7)` | ✓ |
| T4 goes to 0 | `SdrMustStayWritableStateNotPatchableContextTest` iterates `MUST_STAY_WRITABLE`, then `isGreaterThanOrEqualTo(2)`. `grep -ci '\bstate\b'` returns 0 in each of Section, Boxtype, Client, Location, Sysprop and UserGroup | ✓ |
| T1–T8 is complete | I re-swept `src/test` for `MUST_STAY_WRITABLE`, `configureAdvice*`, `configureMustStay*`, the `/v3/advice/` and `/v3/cyclecount` literals, reflective `getDeclaredMethod`/`getDeclaredField` on RestConfiguration, and size pins on `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN`. Nothing outside T1–T8 asserts on these types' write verbs. `PutForCreationWithdrawalContextTest`, `SdrReadGateEnforcementContextTest` and `SdrSurfaceInventoryContextTest` have zero Advice or Cyclecount references | ✓ |
| Cyclecount reads stay pinned after PR 2 | It joins `WITHDRAWN`, so `withdrawnResourcesStillExposeReads` (T3) covers GET on both axes. `CyclecountRepository` does not un-export `findAll` | ✓ |
| `advice.comment varchar(255)` | `V2.2.00__base_v2_schema.sql:621`. The onboarding path `v1-to-v2-onboarding/schema/V1.0.01__wms_tables.sql:21` also has `character varying(255)`, so the cap holds on both tenant arrival paths. `cyclecount.comment` is `text` (`:898`) | ✓ |
| Readonly textarea | `plannedCycleCountDescription.vue:57` `readonly` on web-ui `origin/develop`, `release` and `main` alike. The watcher at `:84-93` dispatches `saveComment` 700 ms after `setInitialComment()` | ✓ |
| Lag 120 / 11 | `git rev-list --count origin/release..origin/develop`: api 120 (also 120 vs `main`), web 11 | ✓ |
| Unknown JSON fields are ignored by the DTO | `WebConfigurer.java:78,108,121` `FAIL_ON_UNKNOWN_PROPERTIES=false` | ✓ |
| `@RequiresFunction` always enforces | `FunctionGuardInterceptor` has no mode switch. The mode wording (`:93-98`) applies only to SDR rules | ✓ |
| Closed-notice users hold INBOUND_BOL | `util/appMenuList.js:169` `'/receiving/closedNotice/:id': 'WEB_UI_VIEW_INBOUND_BOL'`. The second mount (the `closedNotices.vue` dialog) sits under the inbound-notices leaf (`:44`), which has the same function | ✓ |

---

## High

### H1 — Principle 3 is asserted for PR-W → PR 1, but nothing in the plan enforces it, and the mitigation argues the wrong way
**Location:** §5.1 row *Deploy order (hard)*; §7 Steps 1–2; §9 risk row 2.

**Evidence:**
- §5.1 says `"PR 1 must be on every environment before PR-W reaches it"`.
- Step 2 is `"PR-W: failing Jest … Review and merge."` It has no wait condition after Step 1's merge to api `develop`.
- Risk row 2 mitigates with `"the web-ui lag (11 commits) is smaller than the api lag (120), so check that release carries PR 1
  before PR-W is promoted"`.
- Merges here go to `develop` only, and devops promotes `release` and `main` per repo, independently.

**Failure scenario:**
1. PR 1 merges to api `develop` and joins a 120-commit backlog.
2. PR-W merges to web `develop` and joins an 11-commit backlog.
3. The smaller web backlog is the one that gets promoted first. The lag figures make PR-W the **more** likely to reach UAT/PRD
   first, not the less likely.
4. On that environment, `POST /v3/advice/setComment` hits an API without the handler. SDR matches `/v3/advice/{id}` with
   `id=setComment` and has no item POST, so the request fails with 405 (not the 404 the plan predicts).
5. Every closed-notice comment edit fails with the generic toast, and the comment is lost.
6. `closedNoticeDescription.vue:233-243` carries the same echo-on-load watcher as the cycle-count box. So **every open of a
   closed notice that has a comment also toasts**, and about half of advices carry one (6,443/12,626).

The "check that release carries PR 1" step has no owner, no instrument and no gate. The plan applies a hard merge-hold to
PR 2 (D4) but not to the symmetric PR-W edge.

**Fix:**
- Make Step 2's merge conditional, the same way D4 conditions PR 2: **PR-W merges to web-ui `develop` only after PR 1 is
  served by the api on `release` and `main`.** Prove it with an instrument, not branch membership: a probe of
  `POST /v3/advice/setComment` with `{}` that returns 422/403 rather than 405 on each UAT/PRD API host, or `actuator/info`
  build time against the merge.
- Alternatively, get devops to promote PR 1 explicitly first and record their acknowledgement on the ticket.
- Update risk row 2: correct the 404 to 405, add the echo-on-every-open impact, and apply the same rule to UAT (web
  `release` vs api `release`).
- Note that this lengthens the exposure window, which feeds M3.

**Self-audit:** confidence HIGH, not refutable from repo context, a flaw. **Realist check:** the worst case is a PRD-wide
comment-save outage plus toasts on half of closed-notice opens, for as long as the api backlog lags. It is detected fast but
is not trivially rolled back, because rolling back means reverting a web promotion. It stays High because it violates a
principle the plan states, and its trigger is the likely path.

---

## Medium

### M1 — AC-4 and Fix A specify 400, but `ApiInvalidParameterException` maps to 422 here
**Location:**
- §5 Fix A: `"A missing id returns 400 (ApiInvalidParameterException)"` and `"A comment over 255 characters returns 400"`;
- AC-4: `"256 characters returns 400"`;
- Completeness (6): `"400, 403, 404 and 409 defined"`.

**Evidence:**
- `exceptions/RestExceptionHandler.java:51` `private final HttpStatus invalidParameterStatus = HttpStatus.UNPROCESSABLE_ENTITY;`
- `:60-64` `@ExceptionHandler(ApiInvalidParameterException.class)` → `ResponseEntity.status(invalidParameterStatus)`.
- The advice is global (`@Order(0) @ControllerAdvice`, no basePackages), so it covers `AdviceController`.
- `MethodArgumentNotValidException` (`@Valid @Size`) also maps to 422 (`:89-101`).
- The cited precedent, `UserRoleController:266`, returns 422 as well. Its own javadoc at `:239` says "every 422".

**Failure scenario:** the executor implements Fix A as written, and AC-4 stays red forever (422 ≠ 400). The executor then
either silently edits the AC, which is a contract change with no review, or the TDD gate stalls. D3 (Nam) says 400, so the
plan's mechanism contradicts a user decision without flagging it.

**Fix:** pick one and state it.
- (a) Throw `new ResponseStatusException(HttpStatus.BAD_REQUEST, …)` before the load. No `@Order(0)` handler intercepts it, so
  it reaches `ResponseStatusExceptionResolver` and returns 400. Pin the status in AC-4.
- (b) Ask Nam to amend D3 to 422, the repo convention for invalid parameters, and change AC-4, Fix A and Completeness (6).

The UI behaves the same either way, because axios throws on both.

### M2 — The floor's mutation instrument cannot produce the mutants that decide AC-2, AC-3 or the PR-W ACs
**Location:** §8 Floor: `"mutation-check every assertion with PIT on AdviceService and AdviceController (Jest by hand), and the
kill must name the mutant"`; AC-2; AC-3.

**Evidence:**
- **AC-2.** Pre-fix, `POST /v3/advice/setComment` fails because the route does not exist (SDR item path, 405). AC-2 is
  therefore red **only on its status assertion**. The assertion that is the point of the ticket ("only `comment` changed") is
  never shown to bite.
- **The analysis named the right mutant.** `analysis.md` AC-A2: *"Mutation check: bind the body map onto the entity, which
  must turn it red"*. The plan dropped it in favour of PIT. PIT's mutators do not rewrite a typed-DTO read into a map-to-entity
  bind.
- **AC-3.** The decisive mutant is removing `@RequiresFunction`. PIT does not mutate annotations (analysis AC-A3 named this
  mutant explicitly).
- **PIT is not wired in.** It is not declared in `pom.xml` at `origin/develop` (`grep -i pitest` returns nothing), so "PIT" means
  an ad hoc plugin run, and that run cannot reach the Testcontainers/H2 context tests that carry AC-2 to AC-6 without extra
  setup.

**Failure scenario:** a future refactor replaces the DTO with `objectMapper.updateValue(advice, body)` or
`BeanUtils.copyProperties`. AC-2 would catch it, but nobody has proven that, and the floor item "mutation-check every new
assertion" is recorded as met when it was not.

**Fix:** list hand mutants per AC, each with the expected red:
- AC-2: map-to-entity bind;
- AC-3: delete `@RequiresFunction`, and swap it to a different function;
- AC-4: delete the length guard, which should go red with a 500 / DataIntegrityViolation and the row unchanged;
- AC-5: replace null with `""` coercion;
- AC-6: `findById(...).orElse(new Advice())`;
- AC-7: add an `omsNotificationService` call;
- AC-W1: restore `$patch`;
- AC-W2: restore the watcher;
- AC-W3: reinsert the line, as already stated.

Keep PIT as a supplement only, for `AdviceService` branch logic.

### M3 — Driver 1 (PRD exposure) is served last, and Option C was rejected on a rationale that no longer applies to these types
**Location:** Decision driver 1 `"PRD exposure today: every tenant is at guard mode OFF"`; Options table row C, Against:
`"collection POST bypassed the same annotation before (SBDEV-3215)"`; §9 `"Exposure stays open until step 4 … Accepted
(D4). PR 1 alone does not narrow anything"`.

**Evidence:**
- **The bypass argument is gone for these types.** Collection POST on Advice is withdrawn (`RestConfiguration:640-644`), on
  Cyclecount too (`:798-801`), and item PUT and DELETE on both (`:682-686`, `:877-880`). The surviving verb is item PATCH,
  where SDR honours `@ReadOnlyProperty` (`DomainObjectReader.doMerge`, quoted in RestConfiguration's own javadoc at
  `:584-598`), and `Advice.state` already proves the mechanism in production.
- **C works as an interim even though it fails as the fix.** "A closed list that drifts" is a fair objection to C as the final
  answer. It is no objection to C as a stop-gap that PR 2 deletes.
- **H1 makes the window longer.** The window is three sequential promotions: PR 1 → api `main`, PR-W → web `main`, then PR 2
  through the api backlog.

**Failure scenario:** PRD stays fully field-patchable (`clientId`, `type`, `allowoverdelivery`, `externalid`, `transferId`)
by any `wms_user` for that whole window, while the plan's first decision driver names that very exposure.

**Fix:** none is mandated, because D4 is Nam's and is not unsafe. The RALPLAN-DR table should, though, evaluate
"**C as an interim in PR 1**":
- annotate `clientId`, `type`, `allowoverdelivery`, `allowshortdelivery`, `externalid`, `transferId`, `number` and `name` on
  Advice, and `clientId`, `type`, `subtype`, `number` and `name` on Cyclecount;
- the UI's `{id, comment}` body is unaffected;
- it reaches PRD with PR 1;
- PR 2 removes the annotations, or keeps them as defence in depth.

Then either adopt it or record why the longer window is accepted. As written, the rejection rationale is stale, so the
alternatives-depth gate does not pass.

### M4 — The D4 gate ("confirmed on web-ui `main`") and Step 3 ("Wait until PR-W is on web-ui `main` (PRD)") have no verification instrument
**Location:** §5.1 Deploy-order row, §7 Step 3, §9 risk row 1.

**Evidence:**
- Branch membership is not deployment (memories: *Deployed image ≠ branch HEAD*, *is-ancestor ≠ fix shipped*, *:develop tag
  race*).
- The web PRD image is built on push to `main` (`.github/workflows/docker-image.yml:5`) and deployed by webhook per stack.
- The v2 estate has several PRD tenants (memory: *WineCo env map; v2 PRD = 3 clients*).
- Step 2 does specify an instrument for dev ("Confirm the dev web image actually carries it"). PRD and UAT get none.

**Failure scenario:**
1. PR-W is merged to web `main`.
2. One tenant's PRD web stack did not redeploy (or deployed an older tag).
3. PR 2 then ships, and that tenant's closed-notice page 405s on every open that has a comment.

**Fix:** define the instrument and record it on the ticket. For each UAT/PRD web host: fetch the served JS bundle and grep
for `advice/setComment`, plus the absence of the `` `/cyclecount/${ `` patch string. Then pair each web host with its api
host. Use the same instrument, mirrored, for H1's PR 1 check.

---

## Low

- **L1 — AC-W2 can pass vacuously before the fix** (§8 AC-W2 `"Mounting … and advancing 700 ms dispatches nothing"`).
  - `data.comment` starts `null`, and `mounted()` sets it, so the `comment` watcher is queued for Vue's next tick (a Promise
    microtask that Jest 27 fake timers do not flush).
  - A test that mounts and then calls `jest.advanceTimersByTime(700)` synchronously therefore sees no dispatch on the
    **unfixed** component.
  - Fix: require `await wrapper.vm.$nextTick()` (or `flushPromises()`) before advancing, and require AC-W2 to be shown red on
    the unfixed file. Memory: *Mount-with-value ≠ reactivity test*.
- **L2 — Retiring T4 drops a forward guard.**
  - Nothing would then stop a future `MUST_STAY_WRITABLE` member with a writable `state`.
  - Principle 4 allows retirement, so this is Low. Re-scoping would keep the invariant with real sensitivity: iterate
    `MUST_STAY_WRITABLE` as today, and add a positive control that runs the same detector on `Advice` and `Cyclecount` (the
    count must be 2, both read-only).
  - AC-B4 already allows re-scoping, but Fix C pre-decides "retired".
- **L3 — Risk row 3 leaves as a to-do something that is already true.** `"confirm the handler maps it to 409, not 500"` is
  already the case: `RestExceptionHandler.java:384-390` maps `ObjectOptimisticLockingFailureException` to 409 globally.
  State it as fact, or add a one-line AC.
- **L4 — The Advice echo-on-load is carried forward without being named.**
  - `closedNoticeDescription.vue` has the same watcher as the cycle-count box, so after PR-W every closed-notice open with a
    comment issues a no-op `POST setComment` (load plus save, no UPDATE).
  - It is harmless after the fix, but it should be named. It is the mechanism behind H1 and risk row 1's real impact: a toast
    on every open, not only on a save.
  - Consider dispatching only when the value differs from the loaded one, by the same logic as D1.
  - The component also mounts in two places (`pages/receiving/closedNotice/_id.vue:21` and `closedNoticeDetails.vue:49`
    inside `closedNotices.vue:80`). M2 should exercise both.
- **L5 — AC-W3's scan scope is narrower than the caller sweep.**
  - "store-wide" misses `components/`, `pages/` and `plugins/`, where a direct `this.$axios.$patch` would also be a caller.
    Widen the scan to match analysis P1.
  - Separately, wms2-web-ui CI does not run Jest: `.github/workflows/*` only build images, and `.gitlab-ci.yml` has only a
    build stage. AC-W1 to AC-W3 protect only local runs. Say so in the plan.
- **L6 — AC-B2's harness, user and guard mode are unspecified.**
  - SDR rejects a disabled verb inside the handler, after interceptor `preHandle`.
  - Under an enforcing SDR guard, an unprivileged test user gets 403 before any 405 could appear, and an AC that accepts
    either one proves nothing.
  - Pin the user (holding INBOUND_BOL/CYCLECOUNT) or the mode (OFF), and assert exactly 405.
- **L7 — AC-2 "only `comment` changed" conflicts with Fix A.** Fix A says `@Version` and `modified` move. Enumerate the compared
  columns (`externalid`, `clientId`, `type`, `allowoverdelivery`, `state`, `transferId`, `name`, `number`, …) and assert
  `version` increments, rather than "every other column unchanged".
- **L8 — The rollback order is implicit.** Completeness (8) says `"revert any PR. Ordering per §5.1"`. State the reverse order:
  revert PR 2 before PR-W, and PR-W before PR 1. Reverting PR 1 alone once PR-W is live recreates H1.
- **L9 — The evidence for several numbers is unsourced or mislabelled.**
  - M1's `"FINISHED advices: 12,530 (6,443 with a comment)"`: 12,530 appears nowhere in the evidence.
  - 6,443 is the **all-states** count (`db-verification.md` §2: total 12,626, with_comment 6,443), not a FINISHED subset.
  - M3's `"CREATED cycle counts with a comment: 55"` has no query either.
  - The closed-notice list probably spans `CLOSED` as well as `FINISHED` (`WmsConstants.AdviceState:243-244`).
  - Add the queries to `db-verification.md`, or drop the figures.
  - Cosmetic: there is no §3, and `### 5.1 Prerequisites` sits under `## 7`. Confirm `plan-state.sh` still parses §5.1.

---

## What's missing
- An enforced gate for PR-W relative to PR 1 (H1), and served-bundle and served-API instruments for both ordering edges (M4).
- Named hand mutants per AC (M2).
- An evaluated interim narrowing in PR 1 (M3).
- An audit trail. A comment write logs no actor. A `LOG.info("setComment adviceId={} by {}", id, principal)` without the text
  costs nothing and replaces "the existing request log".
- A UAT row in the ordering analysis. Today the analysis covers only PRD (`main`), but web `release` and api `release`
  diverge the same way.

## Ambiguity risks
- `"check that release carries PR 1 before PR-W is promoted"` can be read two ways:
  - A: the implementer checks before **merging** PR-W;
  - B: devops checks before **promoting** web.
  - Under B, nothing in this ticket's control enforces it (H1).
- `"T4 … is retired"` (Fix C) vs `"retired or re-scoped"` (AC-B4). The executor may read retirement as mandatory (L2).
- `"PR-W is confirmed on web-ui main"` can mean A: merged to the branch, or B: served by every PRD web host. Only B is safe
  (M4).

## Multi-perspective notes
- **Executor:**
  - Will stall on AC-4 (M1).
  - Needs the base class named for AC-2 and AC-3. `BasePostgresIntegrationTest` + `@AutoConfigureMockMvc` has precedent
    (`UserRoleRenameUniqueRaceIntegrationTest:59-62`). `BaseControllerIntegrationTest` is H2, which contradicts v2 constraint
    (6) "the IT uses Testcontainers".
- **Stakeholder:** the plan solves the stated problem at its end state. Driver 1 (PRD exposure) is served last (M3).
- **Skeptic:**
  - The strongest argument against the plan is the three-promotion dependency chain across repos whose promotions this team
    does not control.
  - The plan fences one edge (D4) and leaves the other unfenced (H1).
- **Security:**
  - The new route is strictly narrower than the PATCH it replaces: a typed DTO, an always-on function gate and a length cap.
  - No new trust boundary.
  - The id is a body `Long`, and malformed JSON returns 400 through Spring's default resolver, because the
    `controller.rest`/`controller.mobile`-scoped fallbacks do not apply.

## Verdict justification
ITERATE, not REJECT. The architecture and the PR 2 inventory are correct and verified, and the High finding has a cheap,
local fix: one more merge-hold plus an instrument. It is not APPROVE, for three reasons:
- H1 is a stated-principle violation on the likely path.
- M1 makes an acceptance criterion unsatisfiable as specified.
- M2 means the floor's mutation requirement would be recorded as met without being met.

Mode: escalated to ADVERSARIAL after H1, M1 and M2 surfaced. The extra sweep found nothing new in PR 2's test inventory and
added L4–L6.

Realist recalibrations:
- H1 kept High. It is a user-visible PRD regression with a likely trigger, not data corruption.
- M3 kept Medium rather than High. **Mitigated by:** D4 is Nam's accepted risk, and the exposure is pre-existing, not introduced
  by this plan.

## Open questions (unscored)
- Is every PRD tenant actually at `WMS2_SDR_READ_GUARD_MODE=OFF`? I could not re-verify this, because the DB MCPs were
  unavailable this session. The plan's "who can do it" rests on it.
- Do the three PRD clients' web stacks deploy from the same `main` image and webhook, or separately? This affects how M4's
  instrument is run.
- Should Cycle Count comments be editable at all? D1 says no. If product reopens it, a typed endpoint comes back, and the PR 2
  withdrawal stays.
- AOP aspects matching repository `save`, and DB triggers on `advice`, were not checked (analysis blind spots). They are low
  risk, but the "no OMS side effect" claim inherits both gaps.

---
*Ralplan summary row:*
- **Principle/Option Consistency: Fail.** Principle 3 is not enforced on the PR-W → PR 1 edge (H1). Driver 1 is served last
  (M3).
- **Alternatives Depth: Fail (narrowly).** C's rejection cites a bypass that no longer exists for these types, and C as an
  interim is not evaluated (M3). B and D are fairly rejected.
- **Risk/Verification Rigor: Fail.** No instrument exists for either ordering gate (M4). AC-4 is unsatisfiable (M1).
  Mutation checks rely on PIT for mutants PIT cannot make (M2). The rest of the ACs are concrete and failing-first.
- **Deliberate Additions:** the pre-mortem is adequate in substance (§9 plus analysis §8). The test plan covers unit,
  integration and context tests plus manual M1–M4. Observability is thin (no actor log).
