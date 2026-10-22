---
title: "SDR item PATCH on Advice and Cyclecount binds every field"
ticket: "SBDEV-3873"
ticket_url: "https://app.clickup.com/t/868mm4m7n"
type: bugfix
priority: high
status: "draft: pending approval (ralplan round 1)"
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
**Inputs:** `SBDEV-3873-evidence/analysis.md` (A), `db-verification.md`, `decisions-2026-10-22.md` (D1–D4). The citations below
point into A, which quotes `origin/develop` at wms2-api `bafa2301` and web-ui `98accaf`.

## RALPLAN-DR summary

**Principles**
1. Close the write surface. Don't filter it.
2. The replacement must be strictly narrower than what it replaces.
3. No environment ever runs a UI whose write path its API doesn't serve.
4. A test that loses its subject is retired or re-scoped, never made vacuous.

**Decision drivers**
1. PRD exposure today: every tenant is at guard mode OFF.
2. The two repos are promoted independently: api `develop` is 120 commits ahead of `release`, web-ui is 11.
3. Comment saves on closed inbound notices must keep working.

**Options considered**

| Option | For | Against | Verdict |
|---|---|---|---|
| **A. Typed endpoint, then withdraw PATCH** (chosen) | Removes the verb outright; matches the SBDEV-3545 UserRole precedent; reads untouched | Three PRs and an ordering constraint | chosen |
| B. `@HandleBeforeSave` refusing non-comment changes | One API PR, no UI change | SDR has already merged the body into the managed entity when the hook runs, so detecting a change needs a second read. It fences only this verb, and is easy to get silently wrong | rejected |
| C. Mark every other field `@ReadOnlyProperty` | One-file change | A closed list of fields that drifts with each new column, and collection POST bypassed the same annotation before (SBDEV-3215) | rejected |
| D. Enforce the SBDEV-3183 rules (guard mode past OFF) | No code | Holders of INBOUND_BOL or CYCLECOUNT (42 and 44 of 53 on dev) still bind every field; it also needs the PRD go-live checks first | rejected as the fix (complementary) |

## 0. Affected sites (enumeration; method and blind spots in A §0.1–0.2 and the A claim register)

| # | Site | Construct | Same cause? | In scope |
|---|---|---|---|---|
| S1 | web-ui `store/receiving/inboundNotices.js` `saveComment`: ``$patch(`/advice/${data.id}`, data)`` | live SDR item PATCH; body `{id, comment}` from `closedNoticeDescription.vue` | yes | **PR-W**: repoint to `POST /advice/setComment` |
| S2 | web-ui `store/internalOps/cycleCount.js` `saveComment`: ``$patch(`/cyclecount/${data.id}`, data)`` | echo-on-load PATCH; the textarea is `readonly` on main, release and develop | yes | **PR-W**: delete the action and the `comment` watcher (D1) |
| S3 | web-ui `cypress/support/helpers/wmsHelpers.js` `patchAdvice` | dead helper (imported, never called) | yes | PR-W: delete |
| S4 | same file `patchCycleCount`, used by `cycle-count.cy.js` P1.5 (asserts 200) | live e2e PATCH | yes | PR-W: drop the PATCH step, keep the detail GET |
| S5 | api `RestConfiguration.configureAdviceItemVerbWriteExposure`: `httpMethods.disable(HttpMethod.PUT, HttpMethod.DELETE)` | leaves item PATCH open | **root** | **PR 2** |
| S6 | api `RestConfiguration.configureMustStayWritableItemVerbWriteExposure`, Cyclecount block | same | **root** | **PR 2** |
| S7 | api tests T1–T8 (A §3.4) pinning PATCH as surviving | test pins | — | PR 2 (T4 retire or re-scope) |
| S8 | web-ui `inboundNotices.js:197` `$delete(/advice/…)` | dead (callers commented out), already 405 | no | no |
| — | mobile-ui, oms-laravel-api, siteboss-frontend, Jest | zero callers (positive controls in A §0.2) | — | no |

## 1. Problem statement

`PATCH /v3/advice/{id}` and `PATCH /v3/cyclecount/{id}` (Spring Data REST) bind every field except `state`, the only
`@ReadOnlyProperty`. The UI uses them only to save a comment.

**Reproduced on dev 2026-10-22** (`develop-b399ae5d`, as panderson):
- PATCHing `externalid` on advice 87150 landed.
- PATCHing `name` on cyclecount 742350 landed.
- Both were restored (`snapshot.sh diff`: restored) and no OMS rows were written.

**What a caller can do.** Advice rows span 122 clients and the types REGULAR, RETURN and TRANSFER, so a caller can move an
advice to another client, retype it, enable over-delivery, or change the `externalid` and `transferId` that transfer lookups
key on.

**Who can do it.** Every tenant is at `WMS2_SDR_READ_GUARD_MODE=OFF`, PRD included (dev is at SHADOW), so today **any
authenticated `wms_user`** can.

## 2. Root cause

SBDEV-3157 and SBDEV-3183 kept item PATCH on both types because `saveComment` used it, and withdrew everything else (A §3.1–3.3).
An SDR item PATCH is a generic field binder. The only per-field fence is `@ReadOnlyProperty`, and only `state` carries it.
Nothing ties the open verb to the one field its caller needs.

## 4. Architecture

```
closedNoticeDescription.vue ─dispatch─> inboundNotices.saveComment ─PATCH /v3/advice/{id}──> SDR RepositoryEntityController (binds all fields)
plannedCycleCountDescription.vue (readonly box, watcher echoes on load) ─> cycleCount.saveComment ─PATCH /v3/cyclecount/{id}─> SDR
after:  inboundNotices.saveComment ─POST /v3/advice/setComment {id,comment}─> AdviceController.setComment (@RequiresFunction INBOUND_BOL)
        ─> AdviceService.setComment (tenant tx: load, setComment, save)        cycle-count echo deleted; SDR PATCH 405 on both
```

| File | Role |
|---|---|
| `controller/AdviceController.java` (`/v3/advice`, method-level gates; precedent `setPurchaseOrderNumber`) | new handler |
| `service/AdviceService.java` | new `setComment` |
| `RestConfiguration.java` | PR 2 withdrawal |
| `security/Sbdev3017TrancheGateContextTest` | gate golden map (231 → 232) |

## 5. Fix design

### Fix A (PR 1, wms2-api): a comment-only endpoint
- **Handler:** `AdviceController.setComment`, mapped `@PostMapping(path = "/setComment", consumes = "application/json")` and
  gated with `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL)`.
  - The body is a typed DTO `{Long id, String comment}`. Nothing else binds, because unknown fields are ignored by the DTO and
    never reach the entity.
  - A missing `id` returns 400 (`ApiInvalidParameterException`).
  - A `comment` over 255 characters returns 400 before any load (D3; `advice.comment` is `varchar(255)`).
- **Service:** `AdviceService.setComment(Long id, String comment)` under `@Transactional(value = "tenantTransactionManager",
  rollbackFor = {BusinessException.class, FacadeException.class})`.
  - It loads with `findById(id).orElseThrow(() -> new EntityNotFoundException(...))`, then calls `setComment(comment)` and
    `save`.
  - It uses an entity save, not a `@Modifying` UPDATE, so `@Version` and `modified` move and a concurrent stale save fails on
    the optimistic lock instead of silently reverting the comment.
  - It calls no state method and no OMS or outbox service.
- **Behaviour carried over:**
  - `null` and `""` both clear the comment, as the UI does today.
  - There is no state restriction; the SDR PATCH had none.
- **Response:** 200 with `{id, comment}`. A missing advice returns 404, never a 200 carrying an `errors` map, because
  `saveComment` toasts only on a thrown error.
- **Kept:** the SDR PATCH stays (Principle 3).

### Fix B (PR-W, wms2-web-ui)
- `inboundNotices.saveComment` becomes ``$post('/advice/setComment', { id: data.id, comment: data.comment })``.
- The closed-notice textarea gets `maxlength="255"`.
- Delete `cycleCount.saveComment` and the `comment` watcher in `plannedCycleCountDescription.vue`. The box stays read-only
  and displays `setInitialComment()` (D1).
- Delete the Cypress helpers `patchAdvice` and `patchCycleCount`, and the P1.5 PATCH step.

### Fix C (PR 2, wms2-api): withdraw
- Add `Advice.class` and `Cyclecount.class` to `SDR_WRITE_WITHDRAWN`. That set already disables POST, PUT, PATCH and DELETE on
  the collection, item and association axes.
- Delete `configureAdviceCollectionCreateWriteExposure`, `configureAdviceItemVerbWriteExposure` and their calls.
- Remove Cyclecount from `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` and from the item-verb method.
- Keep reads exported, and keep the `SdrFunctionRules` read rules (rewrite their comments).
- Keep `@ReadOnlyProperty` on `state` as defence in depth.
- Update the tests T1–T8 (A §3.4):
  - `WITHDRAWN` goes 51 → 53 and `MUST_STAY_WRITABLE` 8 → 6.
  - **T4** (`SdrMustStayWritableStateNotPatchableContextTest`) is retired, with the reason in the commit: no SDR-writable type
    has a `state` field any more. Its threshold must **not** be lowered.

**Rejected alternatives:** see the RALPLAN-DR table (B, C, D).

## 6. File changes

| Repo / file | PR | Change |
|---|---|---|
| api `controller/AdviceController.java`, new DTO `json/AdviceCommentRequest.java` | 1 | add handler and DTO |
| api `service/AdviceService.java` | 1 | add `setComment` |
| api `security/Sbdev3017TrancheGateContextTest` | 1 | add the row; 231 → 232 |
| api tests: `AdviceControllerUnitTest` (`@Nested SetComment`), new `AdviceSetCommentIntegrationTest` | 1 | new |
| web `store/receiving/inboundNotices.js`, `components/receiving/closed/closedNoticeDescription.vue` | W | POST and maxlength |
| web `store/internalOps/cycleCount.js`, `components/internalOps/cycleCount/planned/plannedCycleCountDescription.vue` | W | delete the echo |
| web `cypress/support/helpers/wmsHelpers.js`, `cypress/e2e/wms/cycle-count/cycle-count.cy.js`, `inbound-receiving.cy.js` import | W | delete the PATCH helpers and the step |
| web Jest: new `test/store/receiving/inboundNoticesSaveComment.spec.js`, `test/components/.../plannedCycleCountDescription.spec.js` | W | new |
| api `RestConfiguration.java`; tests T1–T8; stale javadoc in `Advice`, `Cyclecount`, `AdviceController`, `CycleCountController`, `SdrFunctionRules` | 2 | withdraw, update pins, fix prose |

## 7. Implementation steps

### 5.1 Prerequisites
| Item | State |
|---|---|
| DB / Flyway | N/A: no schema change (`comment` is already `varchar(255)` / `text`) |
| Sysprop / feature flag | N/A: `@RequiresFunction` always enforces; independent of the SDR guard mode |
| **Deploy order (hard)** | PR 1 must be on every environment before PR-W reaches it. **PR 2 merges to api `develop` only after PR-W is confirmed on web-ui `main`** (D4). Record both constraints in each PR body and on the ticket, for devops |
| Grants | Users who save closed-notice comments already hold INBOUND_BOL (the route guard on `/receiving/closedNotice/:id`). Cypress user: INBOUND_BOL for the new route |
| External systems | OMS: none (A §8.4); mobile: none |

### Steps
1. **PR 1:** failing tests (AC-1 to AC-7), then handler, DTO and service. Floor: mutation-check each assertion, one review lane
   per the T3 lanes, full suite against a fresh baseline. Merge, then a dev probe (manual M1).
2. **PR-W:** failing Jest (AC-W1 to AC-W3), then the changes. Review and merge. Confirm the dev web image actually carries it
   (the `:develop` tag race), then manual M2 and M3.
3. **Wait** until PR-W is on web-ui `main` (PRD).
4. **PR 2:** flip the pins first (red), then the withdrawal. Merge, then manual M4 (live 405).

## 8. Testing plan

**Acceptance criteria (the failing-first tests)**
- **PR 1:**
  - **AC-1** The tranche pin holds `row("AdviceController", "/v3/advice/setComment", "WEB_UI_VIEW_INBOUND_BOL")`; size 232.
  - **AC-2** A Testcontainers IT seeds an Advice and POSTs `{id, comment:"x", externalid:"EVIL", clientId:<other>,
    type:"REGULAR", allowoverdelivery:true, state:"FINISHED"}`. The reloaded row has only `comment` changed. Assert by id.
  - **AC-3** Through the real filter chain, a user with no functions gets 403 and an INBOUND_BOL holder gets 200 with the row
    changed.
  - **AC-4** 256 characters returns 400 with the row unchanged; 255 returns 200.
  - **AC-5** `""` and `null` clear the comment.
  - **AC-6** An unknown id returns 404.
  - **AC-7** No OMS or outbox interaction (`verifyNoInteractions`).
- **PR-W:**
  - **AC-W1** `saveComment` POSTs `/advice/setComment {id, comment}` and never `$patch`.
  - **AC-W2** Mounting `plannedCycleCountDescription` with a comment and advancing 700 ms dispatches nothing, and the module
    exports no `saveComment`.
  - **AC-W3** A store-wide source scan finds no `$patch(` to `/advice/` or `/cyclecount/`, mutation-checked by reinserting the
    old line.
- **PR 2:**
  - **AC-B1** Neither type exposes a write verb on any axis; `WITHDRAWN` 53, `MUST_STAY_WRITABLE` 6.
  - **AC-B2** `PATCH` on either type returns 405 through the stack.
  - **AC-B3** GET still returns 200.
  - **AC-B4** T4 is retired or re-scoped and does not pass vacuously.
  - **AC-B5** AC-3's 200 case still passes.

**Floor:** mutation-check every assertion with PIT on `AdviceService` and `AdviceController` (Jest by hand), and the kill must
name the mutant. Run the full `mvn clean verify -Pci` and `yarn test` against fresh baselines, comparing failures by name.

**Manual test plan (dev `dev_wh01_om1`)**
| # | Scenario | Precondition → dev count | Steps | Expected |
|---|---|---|---|---|
| M1 | API only writes the comment | FINISHED advices: **12,530** (6,443 with a comment) | Snapshot 87150; POST setComment with extra fields; restore | Only `comment` changed; outbox unchanged; restored |
| M2 | UI comment save | same | Edit a closed notice comment in the UI; reload | Persisted; no toast; DevTools shows the POST, no PATCH |
| M3 | Cycle count open sends nothing | CREATED cycle counts with a comment: **55** | Open a planned cycle count with a comment | No network write; comment displayed |
| M4 | Withdrawal (after PR 2) | same | `PATCH /v3/advice/87150 {}` and `/v3/cyclecount/742350 {}` (real ids) | 405 both; M2 still works |

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| PR 2 promoted ahead of PR-W | Closed-notice comment saves get a 405 on that environment | D4: PR 2 merges only after PR-W is on `main`; the constraint goes in the PR bodies and the ticket |
| PR-W promoted ahead of PR 1 | New UI gets a 404 | PR 1 merges first; the web-ui lag (11 commits) is smaller than the api lag (120), so check that `release` carries PR 1 before PR-W is promoted |
| Comment save races `closeInboundBol` | Optimistic-lock failure | Same window as today's PATCH; confirm the handler maps it to 409, not 500 |
| T4 "fixed" by lowering its threshold | A vacuous test | AC-B4; review lane checks it |
| Exposure stays open until step 4 | PRD remains patchable for weeks | Accepted (D4). PR 1 alone does not narrow anything |
| Tranche pin not updated | New route ungated by convention | AC-1; the review lane checks the row |

## Checklists

**Horizontal scalability:**
- No in-JVM state, no scheduled job, and no external call.
- Pool math unchanged: one short tenant transaction per request.
- No request affinity.
- Idempotent: a replay re-sets the same comment.
- Tenant context comes from the request.
- Locking: the optimistic `@Version` lock only.
- No cache on Advice.
- No notification.

**v2 constraints:**
- (1) OSIV: the load and save sit in one transaction.
- (2) The tenant transaction manager is named.
- (3) `readOnly`: N/A (a write).
- (4) Cache: none on Advice.
- (5) Jakarta: no port.
- (6) H2: the IT uses Testcontainers.
- (7) Controller test: `AdviceControllerUnitTest`, plus a context test for the 403.
- (8) Metrics: N/A (low-frequency path).

**Completeness:**
- (0) DB verified ✓ (`db-verification.md`).
- (1) Every §0 row is placed ✓.
- (2) Adjacent: other SDR-writable types are out of scope; the remaining `MUST_STAY_WRITABLE` six have no `state` field and
  their writes are the subject of SBDEV-3183's decisions.
- (3) Backward compatibility: the SDR PATCH contract is removed in PR 2. The only callers are PR-W's (A §0).
- (4) Concurrency ✓ (risk row 3).
- (5) Multi-tenant ✓ (request-scoped).
- (6) Errors: 400, 403, 404 and 409 defined ✓.
- (7) Observability: the existing request log; no new metric.
- (8) Rollback: revert any PR. Ordering per §5.1.
- (9) Tests ✓ (§8).
- (10) v1: N/A (v1 is reference-only).

## ADR
- **Decision:** replace the SDR item PATCH with a typed, gated `POST /v3/advice/setComment`. Delete the cycle-count
  echo-on-load write. Withdraw item PATCH from both types once the UI has moved everywhere.
- **Drivers:** PRD exposure at OFF; independently promoted repos; keeping comment saves working.
- **Alternatives:** `@HandleBeforeSave`, a closed list of `@ReadOnlyProperty` fields, enforcing the guard mode. All are rejected
  above.
- **Consequences:**
  - Advice and Cyclecount become read-only over SDR.
  - Comment edits on Cycle Count stay impossible, as today.
  - Three PRs, with the exposure window closing at PR 2.
- **Follow-ups:**
  - The class-level tripwire gap on `CycleCountController` gate rows (A §4.4). It is pre-existing; propose it, don't fix it here.
  - Whether `AdviceController`'s legacy 200-with-`errors` handlers should move to real 4xx.

## 10. Implementation status
Not started.
