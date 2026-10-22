---
title: "SDR item PATCH on Advice and Cyclecount binds every field"
ticket: "SBDEV-3873"
ticket_url: "https://app.clickup.com/t/868mm4m7n"
type: bugfix
priority: high
status: "PR 1 on dev (#561 f53a6eb2); PR-W draft (web-ui #180, held by gate P1); PR 2 not started (gate P2)"
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

## 3. Regression chain
N/A. Nothing regressed: the PATCH was kept deliberately for `saveComment` (§2).

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
- **The invariant, not a list:** a context test built from runtime `PersistentEntities` asserts that the writable properties
  declared on each class equal `{comment}` for `Advice` and `{}` for `Cyclecount`.
  - "Declared" means `p.getField() != null && p.getField().getDeclaringClass() == X.class`. It is not `getOwner()`, which is `Advice` for the
    inherited fields too.
  - The test cross-checks that set against plain reflection (non-static `getDeclaredFields()`), so a property the mapping
    context skipped cannot hide.
  - A new column fails the test until it is fenced.
- **Residual until PR 2:** the inherited `AbstractBaseEntity` fields stay bindable. Annotating the superclass would touch every
  entity.
  - `id` is ignored by SDR's item merge.
  - `modified` is overwritten by auditing.
  - `version` takes part in the optimistic check.
  - `created` can be rewritten.
  - PR 2 closes all of them.

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
  - Using an entity save means `@Version` applies to **overlapping transactions only**: if another write commits between
    this request's load and its save, the save fails with 409 (`RestExceptionHandler` maps
    `ObjectOptimisticLockingFailureException` to CONFLICT). The request carries no version, so it is **not**
    stale-tab protection: a browser tab opened earlier still overwrites a newer comment without error (last write
    wins), as the old SDR PATCH did. Security review PR-W L2, 2026-10-22.
  - An unchanged value produces no UPDATE (dirty checking). That matters because the closed-notice page re-saves on every
    open.
  - It calls no state method and no OMS or outbox service.
- **Behaviour carried over:**
  - `""` stores `""` and `null` stores NULL (AC-5).
  - There is no state restriction.
- **One behaviour change:** a body with **no** `comment` key also clears the comment, where the old PATCH left it alone. That
  is harmless for the one caller (`closedNoticeDescription.vue` always sends the key), and AC-5 pins it.
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
    PATCH has `state` non-writable". After PR 2 its real subject set is empty (no SDR-writable type has a `state` field), so
    the **synthetic positive control is mandatory**:
    - the predicates ("exposes PATCH", "`state` is writable") are extracted into methods;
    - they are applied to a known violating case, a test-only stub metadata of a type that exposes PATCH with a writable
      `state`, which must be reported;
    - and to a known clean case, which must not be.
    - A "scanned more than 0 exported types" guard is **not** acceptable; it passes for any export list.
    - **Plus a source floor:** the number of exported types that have a `state` property is at least 2 (Advice and Cyclecount
      keep `state` and stay exported, per AC-B3). This fails if the scan reads the wrong metadata source and silently finds
      nothing.
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

| # | Prerequisite | Blocking? | Proof / notes |
|---|---|---|---|
| **P1** | **Gate G1, before merging PR-W:** PR 1 is served on UAT **and** PRD | **YES** | Also check UAT's API (its `/api/public/version` must map to a release tag containing PR 1, by the same grep), and name the separate `develop-arden` web build in the PR body (security review PR-W M1). PR-W is opened as a **draft** until this row is satisfied. `GET https://wms-api.sbo.li/api/public/version` reports the release version (nearest tag, e.g. `0.0.42`), not a SHA. Map it to tag `v<version>`, then `git merge-base --is-ancestor <PR1 merge> v<version>` **and** `git grep -nE 'path *= *"/setComment"' v<version> -- src/main/java/net/aim_ai/wms/controller/AdviceController.java` (memory *is-ancestor ≠ fix shipped*; the controller writes `path= "/…"`, so the pattern tolerates spacing). Controls: it finds nothing on `v0.0.42` (checked 2026-10-22), and it must match at PR 1's merge commit (record that when PR 1 merges). A bare `setComment` grep is useless, because the entity setter matches on every release. Then compare `/actuator/info` `build.time` with that tag's release build, to tell two builds of one release apart. Enumerate every PRD api stack from the landlord tenant list at gate time |
| **P2** | **Gate G2, before merging PR 2 (D4):** PR-W is served on PRD | **YES** | On every PRD web host (wsl-wineco and nywh-hydra today; enumerate the rest from the landlord tenant list at gate time), fetch the bundle chunks. Run the three commands below the table. Positive control: today chunk `c6e59b2.js` matches both absence patterns. Accepted: browser tabs opened before the deploy keep the old code until reloaded |
| P3 | DB / Flyway | no | none: no schema change |
| P4 | Sysprop / flag | no | none: `@RequiresFunction` always enforces; `@ReadOnlyProperty` is independent of the guard mode |
| P5 | Rollback order | no | Reverse order only. Never roll web back past PR-W while PR 2 is live, or comment views get 405s |
| P6 | Grants | no | Closed-notice users already hold INBOUND_BOL (route guard). The Cypress user needs INBOUND_BOL |
| P7 | External systems | no | OMS none; mobile none (A §8) |

**G2 commands** (run per PRD web host, over every JS chunk the page loads). They are kept out of the table so no `\|` escape
can corrupt them:

```bash
grep -l '"/advice/setComment"' chunks/*.js        # must list a file
grep -lE '\$patch\("/advice/'      chunks/*.js   # must list nothing
grep -lE '\$patch\("/cyclecount/'  chunks/*.js   # must list nothing
```

Both gates hold the **merge into `develop`**, so every later paired release that carries the gated PR already comes after its
predecessor is on PRD. They go in each PR body and on the ticket for devops.

### Steps
1. **PR 1:** write the failing tests (AC-1 to AC-10, including AC-2b), then A1 and A2. Kill every mutant in §8.1. Then four review lanes and the
   full suite against a fresh baseline. Merge, then dev probes M1 and M1b.
2. **Wait for G1.** Then PR-W: failing Jest (AC-W1 to AC-W3), the changes, review, merge. Confirm the dev web image carries the
   change (`:develop` tag race), then M2 and M3.
3. **Wait for G2.** Then PR 2: flip the pins first. AC-B1 and AC-B2 go red first; AC-B3, AC-B4 and AC-B5 are green before and must stay green, and their mutants (m13–m16) prove they guard. Then the withdrawal, review, merge, then M4.

## 8. Testing plan

**PR 1**
- **AC-1** The tranche pin holds `row("AdviceController", "/v3/advice/setComment", "WEB_UI_VIEW_INBOUND_BOL")`; size 232.
- **AC-2** An integration test on the **H2, non-transactional** base `BaseRollbackIntegrationTest` (it commits, so each test
  cleans up its own rows by id; **not** the class-level `@Transactional` `BasePostgresIntegrationTest`, under which the
  `version` assertions are meaningless) seeds a **RETURN** advice with known values and POSTs `{id, comment:"x", externalid:"EVIL", clientId:<other>, type:"REGULAR", allowoverdelivery:true,
  state:"OPEN"}`.
  - Reloaded by id, `comment == "x"`, every other declared column equals its seeded value, and `version` is exactly
    seeded + 1.
- **AC-2b** POSTing the same comment again leaves `version` unchanged. This pins the claim that the re-save on every page
  open writes nothing.
- **AC-3** Through the real filter chain (webAppContext MockMvc on the same base), with the guard mode set explicitly and an
  access stub that answers per requested function, so the CYCLECOUNT-only case can kill m1b:
  - a user with no functions gets 403 and the row is unchanged;
  - a user holding only a **different** function (CYCLECOUNT) gets 403;
  - an INBOUND_BOL holder gets 200 and the row changes.
- **AC-4** 256 characters returns **422** with the row unchanged; 255 returns 200.
- **AC-5** `""` stores `""`; `null` and a body without the key (`{id}`) store NULL. This carries over today's PATCH, which
  stores `""` as sent. Assert the **DB** value, not the response,
  because `NON_NULL` drops the key.
- **AC-6** An unknown id returns 404.
- **AC-7** No OMS or outbox interaction. Asserted in an `AdviceService` unit test that runs the **real** service with mocked
  collaborators (`verifyNoInteractions` on the OMS and outbox services), not in the controller unit test, which mocks the
  service.
- **AC-8** Stop-gap invariant from runtime `PersistentEntities` (derivation in §5 A1):
  - writable declared properties of `Advice` == `{comment}`, and of `Cyclecount` == `{}`;
  - the scanned declared set equals the reflection set for each class, so the test is non-vacuous by construction rather
    than by a numeric floor;
  - any **writable** property with no backing field (`getField() == null`) fails the test, rather than being skipped.
- **AC-9** Stop-gap through the stack, as a user holding INBOUND_BOL **and** CYCLECOUNT, with the guard mode set explicitly
  in the test:
  - `PATCH /v3/advice/{id} {"externalid":"EVIL","comment":"y"}` returns 2xx, `externalid` is unchanged and `comment == "y"`;
  - `PATCH /v3/cyclecount/{id} {"name":"EVIL"}` returns 2xx and `name` is unchanged;
  - one JSON-Patch (`application/json-patch+json`) `replace /externalid` on the advice is rejected with **400** (SDR refuses a
    non-writable path; `JsonPointerMapping` raises `HttpMessageNotReadableException`), and the field is unchanged.

- **AC-10** A body with no `id` returns 422.

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
- **AC-B3** GET on both still returns 200, and both types are still exported (`ResourceMappings` exported flag).
- **AC-B4** Re-scoped T4 is green and non-vacuous (§5 Fix C).
- **AC-B5** AC-3's 200 case still passes.

### 8.1 Mutation plan
PIT runs unit tests only, and these tests are context and integration tests, so the mutants are made by hand. A kill is
attributable when the failing assertion's `.as(...)` message names the property, route or invariant the mutant broke. The PR
body records, for each mutant, the failing test and that message.

| Mutant | Must turn red |
|---|---|
| m1 remove `@RequiresFunction` from `setComment` | AC-3 (403 cases) and AC-1 |
| m1b gate on `WEB_UI_VIEW_CYCLECOUNT` instead | AC-3 (CYCLECOUNT-only case) and AC-1 |
| m2 the service binds the request map onto the entity (or the DTO gains `externalid`) | AC-2 |
| m3 drop the length check | AC-4 |
| m4 `@Modifying` UPDATE instead of an entity save | AC-2 (`version` not incremented) |
| m4b always force an UPDATE (for example bump `modified` by hand) | AC-2b |
| m5 remove `@ReadOnlyProperty` from `Advice.externalid` | AC-8 and AC-9 |
| m5b remove `@ReadOnlyProperty` from `Cyclecount.name` | AC-8 and AC-9 |
| m6 add a new unannotated field to `Advice` | AC-8 |
| m6b the AC-8 scan reads `getOwner()` instead of the declaring class | AC-8 (inherited fields counted, so the reflection cross-check fails) |
| m7 the service calls `outboxService.enqueue` | AC-7 |
| m8 the service skips `null` and empty (`if (comment != null) set…`) | AC-5 |
| m9 not-found swallowed into a 200 | AC-6 |
| m10 drop the missing-id check | AC-10 |
| w1 (web) restore the `$patch` line | AC-W1 and AC-W3 |
| w2 (web) restore the watcher | AC-W2 |
| m11 (PR 2) remove `Advice.class` from `SDR_WRITE_WITHDRAWN` | AC-B1 and AC-B2 |
| m12 (PR 2) remove `Cyclecount.class` from `SDR_WRITE_WITHDRAWN` | AC-B1 and AC-B2 |
| m13 (PR 2) remove `Advice` from `SDR_WRITE_WITHDRAWN` **and** strip `@ReadOnlyProperty` from `Advice.state` | re-scoped T4 (AC-B4) |
| m14 (PR 2) T4's "exposes PATCH" predicate always returns false | AC-B4 positive control |
| m15 (PR 2) mark `Advice` `exported = false` | AC-B3 |
| m16 (PR 2) delete the `setComment` handler | AC-B5 |

**Floor:**
- Full `mvn clean verify -Pci` and `yarn test` against fresh baselines, compared by failure name.
- Four review lanes per PR (conformance, code, security, re-review), each writing to a file.

### 8.2 Manual test plan (dev `dev_wh01_om1`)

| # | Scenario | Precondition (query → dev count, 2026-10-22) | Steps | Expected |
|---|---|---|---|---|
| M1 | Endpoint writes only the comment | `select state,count(*),count(*) filter (where coalesce(comment,'')<>'') from advice group by 1` → FINISHED **12,530**, of which **6,443** have a comment (every commented advice is FINISHED; `db-verification.md` §3) | Snapshot 87150; POST setComment with extra fields; restore | only `comment` changed; outbox unchanged; `restored` |
| M1b | Stop-gap on the old verb | same | `snapshot.sh save` 87150; `PATCH /v3/advice/87150 {"externalid":"X"}`; `snapshot.sh diff` | 2xx, `externalid` unchanged, `restored` |
| M2 | UI comment save, both mounts | same | Edit a comment on `pages/receiving/closedNotice/_id.vue` **and** in the `closedNotices.vue` dialog; reload each | persisted; no toast; DevTools shows the POST, no PATCH |
| M3 | Cycle count open sends nothing | `select state,count(*),count(*) filter (where coalesce(comment,'')<>'') from cyclecount where state not in ('FINISHED','CANCELLED') group by 1` → CREATED **99**, of which **55** have a comment | Open a planned cycle count with a comment | no network write |
| M4 | Withdrawal | same | `PATCH /v3/advice/87150 {}` and `/v3/cyclecount/742350 {}` | 405 both; M2 still works |

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| PR-W reaches an environment before PR 1 | Every closed-notice open (it re-saves) gets a 405 toast; about 6,443 notices carry a comment | Gate G1 (live version proof on PRD) |
| PR 2 reaches an environment before PR-W | Comment saves and cycle-count opens 405 | Gate G2 (bundle proof) |
| A stop-gap annotation breaks a non-SDR write | A service write silently not persisted | Hibernate ignores the annotation; PR 1 runs the full IT lane (receiving, close, transfer ITs write these fields); review lane checks it |
| Rollback out of order | 405s | Reverse-order rule (§5.1) |
| Re-scoped T4 goes vacuous | A guard that guards nothing | AC-B4, mandatory positive control, m13 and m14 |
| Exposure until PR 1 ships | PRD patchable | PR 1 needs no gate; the dangerous fields close one release after merge |
| Inherited `created` (and `version`) bindable until PR 2 | `created` can be rewritten | Accepted residual; closed in PR 2 |

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
- (6) H2: AC-2, AC-3, AC-9 and AC-10 run on the H2 base `BaseRollbackIntegrationTest`, using only portable SQL.
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
  - The `CycleCountController` class-level tripwire gap (A §4.4): proposals register **P19** (recommended: drop).
  - `AdviceController`'s legacy 200-with-`errors` handlers, which turned out to be repo-wide (129 sites in 33
    controllers): proposals register **P20** (recommended: census the UI callers first).

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
| Round-1 critic suggestion: an audit log line per comment write | Declined: comments are not audited elsewhere, and the existing request log identifies the caller |
| Lows | Echo on open named; 405 not 404; T4 re-scoped; rollback order; gates stated in release terms; AC-5 checks the DB; `String.length()`; AC-W2 awaits `$nextTick`; AC-W3 widened and run locally; AC-B2 holder plus explicit mode; AC-2 allows `version`/`modified` to move; counts tied to their queries; 409 confirmed; section numbering |

## 12. Round-2 review dispositions
Architect APPROVE (1 Medium, 7 Lows); critic ITERATE (4 Medium, 9 Low). All are taken:
- **T4 vacuity** (architect M1, critic M1): the synthetic positive control is mandatory; m13 and m14 added.
- **Mutants for AC-5, AC-6, AC-B3, AC-B5 and the missing-id case** (critic M2): m8, m9, m15, m16, m10; AC-10 added.
- **m4 unkillable** (critic M3, architect L3): AC-2 now asserts `version` + 1, and AC-2b pins the no-op re-save.
- **Gates invisible to `plan-state.sh`** (critic M4): §5.1 rows P1 and P2 are now in the parsed `**P<n>** … **YES**` shape.
- **Section numbering:** §3 added, and §5.1 kept under its template name for the parser.
- **G1/G2 detail** (L): the tag mapping and `build.time`; the absence regex covers both paths; hosts named; stale tabs
  accepted.
- **Missing comment key** (architect L4): the behaviour change is stated and pinned in AC-5.
- **AC-8 derivation** (architect L5): declaring class plus a reflection cross-check; m6b added.
- **More mutants** (architect L6): m1b, m5b, m12, and a JSON-Patch case in AC-9.
- **AC-9 user and mode** (critic L1): pinned.
- **AC-2 fixture** (critic L2): a RETURN advice is seeded.
- **AC-7 placement** (critic L4): a real-service unit test.
- **Residual list** (architect L7): `id` added.

## 13. Round-3 review dispositions
Architect APPROVE; critic ITERATE (1 Medium, 6 Lows each, overlapping). All are taken:
- **G1 grep** (both M1): narrowed to `path = "/setComment"` in `AdviceController.java`, with a `v0.0.42` control.
- **G2 regex** (architect L1): moved out of the table into code blocks.
- **AC-2 base** (both L): the H2 non-transactional base, named, with cleanup by id; checklist (6) corrected.
- **AC-9 JSON-Patch** (architect L3): the case expects 400.
- **T4** (both L): risk row cites m13 and m14. The "≥ 2 state types" floor is not reinstated, because after PR 2 the real
  count is 0; the mandatory synthetic control replaces it.
- **Steps** (both L): AC-10 and AC-2b added; the first-red set for PR 2 corrected.
- **AC-3 stub and mode** (critic L5): applied.
- **AC-8 null guard** (critic L6): applied.
- **Round-2 Lows missed by §12:**
  - `""` stores `""` and null stores NULL, pinned in AC-5;
  - mutant naming restated as an attributable `.as(...)` message;
  - M1b wrapped in a snapshot and restore;
  - M2 covers both mounts;
  - the 6,443 count is backed by `db-verification.md` §3 (all commented advices are FINISHED);
  - the actor log line is declined (§11).

## 14. Round-4 review disposition
Critic APPROVE (3 Lows), all taken:
- the G1 grep tolerates spacing, with a positive control at PR 1's merge;
- the T4 source floor is reinstated (at least 2 exported `state` types). §13's reason for declining it was wrong: it
  counted SDR-writable types, not exported ones;
- AC-8 fails on a writable property that has no backing field.

Cosmetics fixed: A2 wording, "three commands", and AC-10's position.

## 15. Implementation status

### PR 1 (wms2-api): submitted 2026-10-22
- **PR:** [#561](https://github.com/SiteBossInc/wms2-api/pull/561).
- **Branch:** `bugfix/SBDEV-3873-advice-comment-endpoint`, off `origin/develop` `4960631d`.
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3873`.
- **Commits:**
  - `6e7a4f31` test: TDD gate (19 failing criterion tests and the tranche-pin row);
  - `37cfa4ee` fix: the A1 field fence and the A2 `POST /v3/advice/setComment`;
  - `76f60dc2` test: stale rationale (conformance gaps);
  - `61366313` fix: review fixes (422 on a NUL comment, 422 bodies name their parameter, JSON-Patch positive control,
    accurate comments);
  - `610fda68` test: re-review fixes (F1, I1).
- **Tests added:**
  - `security/AdviceSetCommentContextTest` (14: AC-2, 2b, 3×3, 4, 4b, 5×3, 6, 7, 10);
  - `security/SdrCommentOnlyWritableContextTest` (5: AC-8);
  - `security/SdrPatchFieldFenceContextTest` (4: AC-9 plus the JSON-Patch control);
  - `unit/service/AdviceServiceUnitTest$SetComment` (4: AC-7, length, NUL, missing id);
  - a `Sbdev3017TrancheGateContextTest` row (AC-1, pin 232).
- **§6 deviation:** the planned `AdviceSetCommentIntegrationTest` and controller-unit `@Nested SetComment` were not
  written. The context tests above cover the same criteria through the real filter chain.
- **Full suite** (`mvn -B -ntp clean verify -Pci`) at `610fda68`: unit 8743 run, 0 failures, 0 errors, 1 skipped;
  integration 976 run, 0 failures, 0 errors, 23 skipped. The skipped and failing names are identical to the baseline at
  `4960631d` (unit 8716/0/0/1, integration 976/0/0/23).
- **Mutation:** 18/18 hand-made mutants killed (`SBDEV-3873-evidence/mutation-pr1.md`). Two substitutions:
  - m6 removes an existing field's annotation, because `ddl-auto=validate` makes a new column fail context load;
  - m7 uses `outboxService.isKeyPresent` in place of `enqueue`.
- **Reviews** (all in `SBDEV-3873-evidence/`):
  - conformance PASS;
  - code APPROVE (9 Lows: 8 fixed, L6 declined with its reason in the PR);
  - security APPROVE (3 Lows: L3 fixed, L1 and L2 stated in the PR);
  - scoped re-reviews of `61366313` and `610fda68` APPROVE.
- **Docs:** none affected.
- **Merged 2026-10-22 20:54Z** through `merge-one.sh`, pinned to the graded head `610fda68` (PR check run 39847590899
  green). Merge commit `f53a6eb2`, first parent `4960631d` (the graded base). No conflicts.
- **On dev:** `post-merge-verify.sh` ALL PROVEN. Develop run 39852849112 passed test and build, and dev serves
  `develop-f53a6eb2`.
- **Dev test:** M1 ✅ and M1b ✅, restored (`SBDEV-3873-evidence/dev-test-pr1-2026-10-22.md`).
- **Next:** gate P1. PR-W can merge only once #561 is served on PRD.
- **Landmine found:** inserting a test with a string anchor can split a neighbouring test and move its assertion. The
  re-review caught it (F1).

### PR-W (wms2-web-ui): draft PR opened 2026-10-22
- **PR:** [#180](https://github.com/SiteBossInc/wms2-web-ui/pull/180), a DRAFT.
- **Branch:** `bugfix/SBDEV-3873-savecomment-endpoint`, off `98accaf`, head `a8b8307`.
- **Worktree:** `.claude/worktrees/wms2-web-ui/SBDEV-3873`.
- **Commits:**
  - `d11d28c` failing specs;
  - `bcd9c29` Fix B;
  - review fixes `1b6c084`, `abc7710`, `35555dc`, `b9c870d`, `a8b8307`.
- **Beyond the plan's Fix B** (from review):
  - saves happen on user input, not via a watcher, so opening a notice never writes;
  - a pending save captures its notice and text, and is flushed on switch or destroy;
  - per-status toasts, with a single toast on an authz 403;
  - a PATCH call-site census plus a wider SDR scan, including `cypress/`.
- **Tests:** Jest 2529 run, 0 failing (baseline 2448, 0 failing). Every new assertion was mutation-checked by hand.
- **Reviews** (`SBDEV-3873-evidence/review-prw-*.md`):
  - conformance PASS;
  - code APPROVE (1 Medium, 7 Lows, all fixed);
  - security APPROVE (its gate Medium is handled by the draft status and gate P1);
  - re-reviews 1 to 5, the last at `a8b8307`: APPROVE with no findings.
- **Merge:** blocked by gate P1, which needs #561 on UAT **and** PRD. At open time PRD reported `0.0.42`.
- **After merge:** dev checks M2 and M3.

### PR 2
Not started. Waits on gate P2 (PR-W served on PRD).
