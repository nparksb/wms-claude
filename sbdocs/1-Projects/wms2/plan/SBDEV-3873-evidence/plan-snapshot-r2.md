---
title: "SDR item PATCH on Advice and Cyclecount binds every field"
ticket: "SBDEV-3873"
ticket_url: "https://app.clickup.com/t/868mm4m7n"
type: bugfix
priority: high
status: "draft: pending approval (ralplan round 2)"
project: [wms2-api, wms2-web-ui]
version: v2
tier: T3
db_verified: true
requester: "Nam Park"
created: 2026-10-22
updated: 2026-10-22
related: [SBDEV-3183, SBDEV-3215, SBDEV-3157, SBDEV-3545]
tags:
  - plan
  - authz
  - sdr
---

# SDR item PATCH on Advice and Cyclecount binds every field

**Ticket:** [SBDEV-3873](https://app.clickup.com/t/868mm4m7n) · **Tier:** T3 (authorization and data integrity, two repos) · **Version:** v2

**Inputs** (all in `SBDEV-3873-evidence/`):
- `analysis.md` ("A"; quotes `origin/develop` at wms2-api `bafa2301` and web-ui `98accaf`);
- `db-verification.md`;
- `decisions-2026-10-22.md` (D1–D5; D3 amended to 422);
- round-1 reviews `review-r1-architect.md` and `review-r1-critic.md`, both ITERATE. Their dispositions are in §11.

## RALPLAN-DR summary

**Principles**
1. Close the write surface rather than filter it.
2. The replacement is strictly narrower than what it replaces.
3. No environment runs a UI whose write path its API doesn't serve.
4. A test that loses its subject is re-scoped, never made vacuous.
5. Shrink the exposure as early as the ordering allows.

**Decision drivers**
1. PRD exposure today: every tenant is at guard mode OFF.
2. The two repos are promoted independently; both usually ride one paired release.
3. Comment saves on closed inbound notices keep working.

**Options considered**

| Option | For | Against | Verdict |
|---|---|---|---|
| **A. Typed endpoint, then withdraw PATCH** | Removes the verb outright; SBDEV-3545 UserRole precedent | 3 PRs with ordering holds; on its own it leaves PRD open until PR 2 | **chosen, with C as the stop-gap (synthesis)** |
| B. `@HandleBeforeSave` refusing non-comment changes | One PR | The body is already merged into the managed entity when the hook runs, so the old value needs a second read; easy to get silently wrong | rejected |
| C. `@ReadOnlyProperty` on every field but `comment` | One api PR closes the dangerous fields at once; PATCH binding honours it (SBDEV-3215 `AdviceStateReadOnlyContextTest`); collection POST and item PUT/DELETE are already withdrawn on both types, so it has no bypass | It is a field list that drifts with new columns, so it needs an invariant test; inherited `created`/`version` stay bindable; the verb stays | **adopted in PR 1 as the stop-gap (D5)**; not the end state |
| D. Enforce the guard mode past OFF | No code | Holders of INBOUND_BOL or CYCLECOUNT (42 and 44 of 53 on dev) still bind every field; needs the PRD go-live checks | complementary, not the fix |

## 0. Affected sites (method and blind spots: A §0.1–0.2 and the A claim register)

| # | Site | Construct | In scope |
|---|---|---|---|
| S1 | web `store/receiving/inboundNotices.js` `saveComment`: ``$patch(`/advice/${data.id}`, data)`` | live SDR PATCH, body `{id, comment}`; also fires on every page open (echo, A §2) | PR-W: POST `/advice/setComment` |
| S2 | web `store/internalOps/cycleCount.js` `saveComment`: ``$patch(`/cyclecount/${data.id}`, data)`` | echo-only PATCH; textarea `readonly` on main, release and develop | PR-W: delete the action and the watcher (D1) |
| S3 | web `cypress/support/helpers/wmsHelpers.js` `patchAdvice` | dead helper | PR-W: delete |
| S4 | same file `patchCycleCount`; `cycle-count.cy.js` P1.5 asserts 200 | live e2e PATCH | PR-W: drop the PATCH step |
| S5 | api `model/Advice.java`, `model/Cyclecount.java` fields | PATCH-bindable fields | **PR 1** stop-gap (D5) |
| S6 | api `RestConfiguration.configureAdviceItemVerbWriteExposure`: `httpMethods.disable(HttpMethod.PUT, HttpMethod.DELETE)` | PATCH left open (**root**) | PR 2 |
| S7 | api `RestConfiguration.configureMustStayWritableItemVerbWriteExposure`, Cyclecount block | same (**root**) | PR 2 |
| S8 | api tests T1–T8 (A §3.4) | pins of the surviving PATCH | PR 1 (T5) and PR 2 |
| S9 | web `inboundNotices.js:197` `$delete(/advice/…)` | dead, already 405 | no |
| — | mobile-ui, OMS, siteboss-frontend, Jest | 0 callers (positive controls, A §0.2) | no |

## 1. Problem statement

`PATCH /v3/advice/{id}` and `PATCH /v3/cyclecount/{id}` (Spring Data REST) bind every field except `state`, the only
`@ReadOnlyProperty`. The UI needs them only for a comment.

**Reproduced on dev 2026-10-22** (`develop-b399ae5d`, as panderson):
- PATCHing `externalid` on advice 87150 and `name` on cyclecount 742350 both landed.
- Both were restored (`snapshot.sh diff`: restored), and no OMS rows were written.

**What a caller can do.** Advice rows span 122 clients and the types REGULAR, RETURN and TRANSFER. A caller can move an advice
to another client, retype it, enable over-delivery, or change the `externalid` and `transferId` that transfer lookups key on.

**Who can do it.** Every tenant is at `WMS2_SDR_READ_GUARD_MODE=OFF` (dev is at SHADOW; source: SBDEV-3183 AC-5 record,
2026-10-22; the PRD DBs were not re-queried this session, see §10), so today any authenticated `wms_user` can.

## 2. Root cause

SBDEV-3157 and SBDEV-3183 kept item PATCH on both types for `saveComment` and withdrew every other write (A §3.1–3.3). An SDR
item PATCH binds every field whose `PersistentProperty.isWritable()` is true. Only `state` is fenced, so the open verb is far
wider than the one field its caller needs.

## 4. Architecture

```
before: closedNoticeDescription.vue ─(on open + 700ms after typing)─> inboundNotices.saveComment ─PATCH /v3/advice/{id}──> SDR (binds all writable fields)
        plannedCycleCountDescription.vue (readonly; echo on open) ─> cycleCount.saveComment ─PATCH /v3/cyclecount/{id}─> SDR
PR 1:   SDR PATCH binds only Advice.comment (all other declared fields @ReadOnlyProperty; Cyclecount: none)
        + POST /v3/advice/setComment {id,comment} ─> AdviceController.setComment (@RequiresFunction INBOUND_BOL) ─> AdviceService.setComment
PR-W:   inboundNotices.saveComment ─POST /v3/advice/setComment; cycle-count echo deleted
PR 2:   SDR_WRITE_WITHDRAWN += Advice, Cyclecount ─> every write verb 405 on both; reads unchanged
```

| File | Role |
|---|---|
| `controller/AdviceController.java` (`/v3/advice`; precedent `setPurchaseOrderNumber`) | new handler |
| `service/AdviceService.java` | new `setComment` |
| `model/Advice.java`, `model/Cyclecount.java` | stop-gap annotations |
| `RestConfiguration.java` | PR 2 withdrawal |
| `security/Sbdev3017TrancheGateContextTest` | gate golden map (231 → 232) |

## 5. Fix design

### Fix A1 (PR 1): stop-gap field fence (D5)
- Annotate every field declared on `Advice` except `comment` with `@ReadOnlyProperty`, and every field declared on `Cyclecount`.
  `state` is already annotated on both.
  - Hibernate ignores the annotation, so service writes still persist.
  - SDR's merge consults `PersistentProperty.isWritable()`, which the annotation drives to false (traced in
    `AdviceStateReadOnlyContextTest`'s javadoc).
  - The echo PATCH from the old cycle-count UI then binds nothing and still returns 200, so there is no user-visible change.
- **The invariant, not a list:** a context test built from runtime metadata asserts that the set of writable properties on
  `Advice` declared in `Advice.class` equals `{comment}`, and on `Cyclecount` is empty. A new column fails the test until it
  is fenced.
- **Residual until PR 2:** the inherited `AbstractBaseEntity` fields (`created`, `modified`, `version`) stay bindable.
  Annotating the superclass would touch every entity. `modified` is overwritten by auditing; `created` is not. PR 2 closes it.

### Fix A2 (PR 1): comment-only endpoint
- **Handler:** `AdviceController.setComment`, mapped `@PostMapping(path = "/setComment", consumes = "application/json")` and
  gated with `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL)`.
  - The body is a typed DTO `{Long id, String comment}`. The primary `ObjectMapper` has `FAIL_ON_UNKNOWN_PROPERTIES=false`, so
    extra fields are dropped and never reach the entity.
  - A missing `id` returns 422.
  - `comment.length() > 255` (UTF-16 length, matching `varchar(255)`) returns **422** (`ApiInvalidParameterException`, D3
    amended) before the load.
- **Service:** `AdviceService.setComment(Long id, String comment)` with `@Transactional(value = "tenantTransactionManager",
  rollbackFor = {BusinessException.class, FacadeException.class})`.
  - It loads with `findById(id).orElseThrow(() -> new EntityNotFoundException(...))`, then calls `setComment` and `save`.
  - Using an entity save means `@Version` applies, so a lost update fails as a 409 (`RestExceptionHandler` maps
    `ObjectOptimisticLockingFailureException` to CONFLICT).
  - An unchanged value produces no UPDATE (dirty checking). That matters because the closed-notice page re-saves on every
    open.
  - It calls no state method and no OMS or outbox service.
- **Behaviour carried over:**
  - `null` and `""` clear the comment.
  - There is no state restriction.
- **Response:** 200 `{id, comment}` (`NON_NULL` drops a null comment); 404 for an unknown id. Never a 200 carrying `errors`.

### Fix B (PR-W, wms2-web-ui)
- `inboundNotices.saveComment` becomes ``$post('/advice/setComment', { id: data.id, comment: data.comment })``.
- The closed-notice textarea gets `maxlength="255"`.
- Delete `cycleCount.saveComment` and the `comment` watcher in `plannedCycleCountDescription.vue`; the box stays read-only and
  displays the loaded comment.
- Delete `patchAdvice`, `patchCycleCount`, the P1.5 PATCH step, and the unused import in `inbound-receiving.cy.js`.

### Fix C (PR 2, wms2-api): withdraw
- Add `Advice.class` and `Cyclecount.class` to `SDR_WRITE_WITHDRAWN`, which disables POST, PUT, PATCH and DELETE on the
  collection, item and association axes. The filters stack, so the removals below are safe.
- Delete `configureAdviceCollectionCreateWriteExposure`, `configureAdviceItemVerbWriteExposure` and their calls.
- Remove Cyclecount from `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` and from the item-verb method.
- Reads stay exported, and the `SdrFunctionRules` read rules stay (comments rewritten).
- Keep the PR 1 annotations as defence in depth.
- Update tests T1–T8 (A §3.4):
  - `WITHDRAWN` goes 51 → 53 and `MUST_STAY_WRITABLE` 8 → 6.
  - **T4** is re-scoped, not retired: from runtime metadata, "every exported type with a `state` property that still exposes
    PATCH has `state` non-writable". It needs a positive control that seeds the check with a synthetic subject, or it asserts
    the scanned-set size is greater than 0 over all exported types. It must never assert a found-set of at least 0.
  - T5 (`AdviceStateReadOnlyContextTest.commentRemainsWritable`) changes in **PR 1**: its rationale moves to the new endpoint
    plus the stop-gap invariant.

## 6. File changes

| Repo / file | PR | Change |
|---|---|---|
| api `model/Advice.java`, `model/Cyclecount.java` | 1 | `@ReadOnlyProperty` (stop-gap) |
| api `controller/AdviceController.java`, new `json/AdviceCommentRequest.java`, `service/AdviceService.java` | 1 | endpoint |
| api tests: new `SdrCommentOnlyWritableContextTest`, `AdviceSetCommentIntegrationTest`; `AdviceControllerUnitTest` (`@Nested SetComment`); `Sbdev3017TrancheGateContextTest` (231 → 232); T5 | 1 | tests |
| web `store/receiving/inboundNotices.js`, `components/receiving/closed/closedNoticeDescription.vue` | W | POST and maxlength |
| web `store/internalOps/cycleCount.js`, `components/internalOps/cycleCount/planned/plannedCycleCountDescription.vue` | W | delete the echo |
| web `cypress/support/helpers/wmsHelpers.js`, `cypress/e2e/wms/cycle-count/cycle-count.cy.js`, `cypress/e2e/wms/inbound-receiving/inbound-receiving.cy.js` | W | delete the PATCH helpers and step |
| web Jest: `test/store/receiving/inboundNoticesSaveComment.spec.js`, `test/components/internalOps/plannedCycleCountDescription.spec.js`, `test/store/noSdrPatchOnAdviceCyclecount.spec.js` | W | new |
| api `RestConfiguration.java`; T1–T4, T6–T8; stale javadoc (`Advice`, `Cyclecount`, `AdviceController`, `CycleCountController`, `SdrFunctionRules`, `SDR_WRITE_WITHDRAWN` list) | 2 | withdraw, update pins |

## 7. Implementation steps (template §5)

### 5.1 Prerequisites

| Item | State |
|---|---|
| DB / Flyway | N/A: no schema change |
| Sysprop / flag | N/A: `@RequiresFunction` always enforces; `@ReadOnlyProperty` is independent of the guard mode |
| **Gate G1 (before merging PR-W)** | PR 1 is **served on PRD**. Proof: `GET /api/public/version` on each PRD api host reports a build containing PR 1's merge (`git merge-base --is-ancestor`, plus `git grep setComment` at that SHA, per memory *is-ancestor ≠ fix shipped*). Branch membership alone is not enough |
| **Gate G2 (before merging PR 2; D4)** | PR-W is **served on PRD**. Proof: the deployed web bundle on each PRD web host contains `/advice/setComment` and no `/cyclecount/` PATCH (curl the bundle JS) |
| Gate notes for devops | Both gates go in each PR body and on the ticket. Both repos usually ship as one paired release, so the gates are stated in release terms |
| Rollback | Reverse order only. Never roll web back past PR-W while PR 2 is live, or comment views get 405s |
| Grants | Closed-notice users already hold INBOUND_BOL (route guard). The Cypress user needs INBOUND_BOL |
| External | OMS none; mobile none (A §8) |

### Steps
1. **PR 1:** write the failing tests (AC-1 to AC-9), then A1 and A2. Kill every mutant in §8.1. Then four review lanes and the
   full suite against a fresh baseline. Merge, then dev probes M1 and M1b.
2. **Wait for G1.** Then PR-W: failing Jest (AC-W1 to AC-W3), the changes, review, merge. Confirm the dev web image carries the
   change (`:develop` tag race), then M2 and M3.
3. **Wait for G2.** Then PR 2: flip the pins first (red), then the withdrawal, review, merge, then M4.

## 8. Testing plan

**PR 1**
- **AC-1** The tranche pin holds `row("AdviceController", "/v3/advice/setComment", "WEB_UI_VIEW_INBOUND_BOL")`; size 232.
- **AC-2** A Testcontainers IT seeds an Advice and POSTs `{id, comment:"x", externalid:"EVIL", clientId:<other>,
  type:"REGULAR", allowoverdelivery:true, state:"FINISHED"}`. Reloaded by id, `comment == "x"`, every other declared column
  equals its seeded value, and `version` and `modified` may move.
- **AC-3** Through the real filter chain (webAppContext MockMvc): a user with no functions gets 403 and the row is unchanged; an
  INBOUND_BOL holder gets 200 and the row changes.
- **AC-4** 256 characters returns **422** with the row unchanged; 255 returns 200.
- **AC-5** `""` and `null` clear the comment. Assert the **DB** value, not the response, because `NON_NULL` drops the key.
- **AC-6** An unknown id returns 404.
- **AC-7** No OMS or outbox interaction (`verifyNoInteractions`).
- **AC-8** Stop-gap invariant from runtime `PersistentEntities`: writable declared properties of `Advice` == `{comment}`; of
  `Cyclecount` == `{}`. Each with a non-vacuity guard: scanned declared properties of at least 10 and at least 5.
- **AC-9** Stop-gap through the stack: as an INBOUND_BOL holder, `PATCH /v3/advice/{id} {"externalid":"EVIL","comment":"y"}`
  returns 2xx, `externalid` is unchanged and `comment == "y"`. `PATCH /v3/cyclecount/{id} {"name":"EVIL"}` returns 2xx and
  `name` is unchanged.

**PR-W (Jest)**
- **AC-W1** `saveComment` calls `$post('/advice/setComment', {id, comment})` and never `$patch`.
- **AC-W2** Mount `plannedCycleCountDescription` with details carrying a comment, `await $nextTick()`, advance 700 ms:
  `dispatch` is never called. The module exports no `saveComment`.
- **AC-W3** A source scan over `store/**` and `components/**` finds no `$patch(` or `.patch(` whose path starts with
  `/advice/` or `/cyclecount/`, covering template-literal and `+` forms. Web-ui CI does not run Jest, so this is run locally
  and recorded in the PR.

**PR 2**
- **AC-B1** Neither type exposes a write verb on any axis; `WITHDRAWN` 53, `MUST_STAY_WRITABLE` 6.
- **AC-B2** As a user **holding** INBOUND_BOL and CYCLECOUNT, in the context test, with the guard mode set explicitly:
  `PATCH /v3/advice/{real id} {}` and `/v3/cyclecount/{real id} {}` return **405** (a 403 cannot mask it).
- **AC-B3** GET on both still returns 200.
- **AC-B4** Re-scoped T4 is green and non-vacuous (§5 Fix C).
- **AC-B5** AC-3's 200 case still passes.

### 8.1 Mutation plan
PIT runs unit tests only, and these tests are context and integration tests, so the mutants are made by hand. Each kill must
name the mutant in its failure message.

| Mutant | Must turn red |
|---|---|
| m1 remove `@RequiresFunction` from `setComment` | AC-3 (403 case) and AC-1 |
| m2 service binds the request map onto the entity (or the DTO gains `externalid`) | AC-2 |
| m3 drop the length check | AC-4 |
| m4 `@Modifying` UPDATE instead of an entity save | AC-2 (`version` unchanged), plus an assertion that `version` increments |
| m5 remove `@ReadOnlyProperty` from `Advice.externalid` | AC-8 and AC-9 |
| m6 add a new unannotated field to `Advice` | AC-8 |
| m7 the service calls `outboxService.enqueue` | AC-7 |
| m8 (web) restore the `$patch` line | AC-W1 and AC-W3 |
| m9 (web) restore the watcher | AC-W2 |
| m10 (PR 2) remove `Advice.class` from `SDR_WRITE_WITHDRAWN` | AC-B1 and AC-B2 |
| m11 (PR 2) re-scoped T4 with an empty subject set | AC-B4 non-vacuity guard |

**Floor:**
- Full `mvn clean verify -Pci` and `yarn test` against fresh baselines, compared by failure name.
- Four review lanes per PR (conformance, code, security, re-review), each writing to a file.

### 8.2 Manual test plan (dev `dev_wh01_om1`)

| # | Scenario | Precondition (query → dev count, 2026-10-22) | Steps | Expected |
|---|---|---|---|---|
| M1 | Endpoint writes only the comment | `select state,count(*),count(*) filter (where coalesce(comment,'')<>'') from advice group by 1` → FINISHED **12,530**, of which **6,443** have a comment | Snapshot 87150; POST setComment with extra fields; restore | only `comment` changed; outbox unchanged; `restored` |
| M1b | Stop-gap on the old verb | same | `PATCH /v3/advice/87150 {"externalid":"X"}` | 2xx, `externalid` unchanged |
| M2 | UI comment save | same | Edit a closed-notice comment; reload | persisted; no toast; DevTools shows the POST, no PATCH |
| M3 | Cycle count open sends nothing | `select state,count(*),count(*) filter (where coalesce(comment,'')<>'') from cyclecount where state not in ('FINISHED','CANCELLED') group by 1` → CREATED **99**, of which **55** have a comment | Open a planned cycle count with a comment | no network write |
| M4 | Withdrawal | same | `PATCH /v3/advice/87150 {}` and `/v3/cyclecount/742350 {}` | 405 both; M2 still works |

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| PR-W reaches an environment before PR 1 | Every closed-notice open (it re-saves) gets a 405 toast; about 6,443 notices carry a comment | Gate G1 (live version proof on PRD) |
| PR 2 reaches an environment before PR-W | Comment saves and cycle-count opens 405 | Gate G2 (bundle proof) |
| A stop-gap annotation breaks a non-SDR write | A service write silently not persisted | Hibernate ignores the annotation; PR 1 runs the full IT lane (receiving, close, transfer ITs write these fields); review lane checks it |
| Rollback out of order | 405s | Reverse-order rule (§5.1) |
| Re-scoped T4 goes vacuous | A guard that guards nothing | AC-B4 and m11 |
| Exposure until PR 1 ships | PRD patchable | PR 1 needs no gate; the dangerous fields close one release after merge |
| Inherited `created` bindable until PR 2 | `created` can be rewritten | Accepted residual; closed in PR 2 |

## Checklists

**Horizontal scalability:**
- No in-JVM state, scheduled job or external call.
- One short tenant transaction per request.
- No affinity.
- Idempotent: a replay re-sets the same value with no UPDATE.
- Tenant context comes from the request.
- Optimistic lock only.
- No cache on these types.
- No notification.

**v2 constraints:**
- (1) OSIV: load and save in one transaction.
- (2) Tenant transaction manager named.
- (3) `readOnly`: N/A (a write).
- (4) Cache: none.
- (5) Jakarta: no port.
- (6) H2: the ITs use Testcontainers.
- (7) Controller test plus a context test (AC-3) for the gate; `setupMockMvc` has no interceptor.
- (8) Metrics: N/A.

**Completeness:**
- (0) DB verified ✓.
- (1) §0 rows placed ✓.
- (2) Adjacent: the other six `MUST_STAY_WRITABLE` types are SBDEV-3183's recorded decisions; out of scope.
- (3) Compatibility: the SDR PATCH is narrowed in PR 1 (no UI-visible change) and removed in PR 2 after G2.
- (4) Concurrency ✓ (409).
- (5) Tenant ✓.
- (6) Errors: 422, 403, 404, 409 ✓.
- (7) Observability: the existing request log.
- (8) Rollback: reverse order ✓.
- (9) Tests ✓ (§8, §8.1).
- (10) v1: N/A (reference-only).

## ADR
- **Decision:** PR 1 fences the SDR PATCH down to `Advice.comment` and adds a typed, gated `POST /v3/advice/setComment`.
  PR-W moves the UI to it and deletes the cycle-count echo. PR 2 withdraws every SDR write verb on both types.
- **Drivers:** PRD exposure at OFF; independently promoted repos; comment saves keep working.
- **Alternatives:**
  - `@HandleBeforeSave` (rejected).
  - The field fence alone (adopted only as the stop-gap: the list drifts and the verb stays).
  - Guard-mode enforcement (complementary).
- **Why:** the stop-gap closes the dangerous fields at the first deploy without waiting on cross-repo order, and the withdrawal
  leaves no verb to drift.
- **Consequences:**
  - Advice and Cyclecount become read-only over SDR.
  - Cycle-count comments stay uneditable (as today).
  - Two promotion gates must be honoured.
- **Follow-ups (proposed, not in scope):**
  - The `CycleCountController` class-level tripwire gap (A §4.4).
  - `AdviceController`'s legacy 200-with-`errors` handlers.

## 10. Open questions
- PRD guard mode is assumed OFF on every tenant from the SBDEV-3183 AC-5 record. Re-query before the PR 1 merge if the DB MCPs
  are back; it does not change the design.

## 11. Round-1 review dispositions
All round-1 findings are taken. The architect's M1/M2/M3 equal the critic's M1/M2/M3; the remaining architect Lows are folded
in.

| Finding | Disposition |
|---|---|
| Critic H1 | PR-W blocked on PR 1: gate G1 |
| Both M1 (400 vs 422) | 422 (D3 amended by Nam) |
| Both M2 (PIT cannot reach the mutants) | §8.1 hand mutants |
| Both M3 (option C dismissed on a closed hole) | C re-evaluated and adopted as the stop-gap (D5) |
| Critic M4 (gates unverifiable) | Live proofs in G1 and G2 |
| Lows | Echo on open named; 405 not 404; T4 re-scoped; rollback order; gates stated in release terms; AC-5 checks the DB; `String.length()`; AC-W2 awaits `$nextTick`; AC-W3 widened and run locally; AC-B2 holder plus explicit mode; AC-2 allows `version`/`modified` to move; counts tied to their queries; 409 confirmed; section numbering |

## 12. Implementation status
Not started.
