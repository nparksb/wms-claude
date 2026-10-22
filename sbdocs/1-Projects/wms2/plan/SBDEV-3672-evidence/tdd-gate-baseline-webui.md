---
ticket: SBDEV-3672
repo: v2/wms2-web-ui
kind: tdd-gate-baseline
created: 2026-10-13
---

# SBDEV-3672: TDD gate baseline (wms2-web-ui, J1–J5)

- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-web-ui/SBDEV-3672`
- **Branch:** `fix/SBDEV-3672-bol-oms-notification-status` at `origin/develop` `9e31726`. Nothing committed, no production file touched.
- **Plan:** `SBDEV-3672-chunk-bol-shipped-notification.md`, Fix B-5, Fix D-6, §6 ui rows, §7 Step 5, §8 Jest J1–J5.
- **Target files (plan §6):** the existing `components/outbound/bol/outboundBolDetails.vue`, `store/outbound/outboundBols.js` and `components/admin/serviceLog/serviceLog.vue`. §6 names no new child component, so every spec imports an existing module. No module-not-found failures are possible, and none occurred.

## Contract the specs pin (implementer: keep it, or change spec and store together)

| Action | Request (relative to the `/v3` baseURL, `nuxt.config.js:99,201`) | Result |
|---|---|---|
| `outbound/outboundBols/getBolOmsStatus({id})` | `$axios.$get('/billOfLading/omsNotificationStatus/' + id)` | the body. **404 → `null`, no error toast** |
| `outbound/outboundBols/requeueBolOms({id})` | `$axios.$post('/billOfLading/requeueOmsNotification/' + id)` | the body `{requeued, mode, reason}`. **409 → `{ conflict: true }`, no error toast** |

- **Component, via `$store.dispatch`:** a rejected `getBolOmsStatus` dispatch carrying `response.status` 404 must also hide the row. The status is fetched by a watch on `outboundBol.id` that also fires at mount (`immediate`); otherwise a cached `bolDetails` with the same id never fetches.
- **Service Log link:** clicking it commits `admin/setParentTab` 6, then pushes `'/admin?messageId=<lastMessageId>'` or `{path:'/admin', query:{messageId}}` (the spec accepts either).
- **`serviceLog.vue` `mounted()`:** when `$route.query.messageId` matches `^\d+$`, call `showDetails({id})`, which dispatches `admin/serviceLogs/getLogDetail` and opens `full-details` with `overlay` true.

## Tests

| Spec | Test | J# |
|---|---|---|
| `test/components/outbound/outboundBolOmsStatus.spec.js` | fetches the status for the BOL on display (getBolOmsStatus with its id) | J1 |
| ″ | re-fetches when outboundBol.id changes AFTER mount (watch, not mount-time only) | J1 |
| ″ | renders "38/39 delivered · 1 failed" for a FAILED chunked BOL | J1 |
| ″ | renders "39/39 delivered" for a CONFIRMED BOL | J1 |
| ″ | renders pending chunks as pending | J1 |
| ″ | renders a legacy oversized row as "1 legacy notification (1,528 parcels)", never "0/1" | J1 |
| ″ | labels resend-reconciled rows "delivered via manual resend" | J1 |
| ″ | renders a distinct NO_RECORD text for each reason (EMPTY_BOL / PURGED / UNKNOWN), with the PURGED text naming `retentionDays` | J1 |
| ″ | hides the row for NOT_SHIPPED (open BOL), with a positive control in the same test | J1 |
| ″ | hides the row when the endpoint 404s: null (store maps 404 to null) | J1 |
| ″ | hides the row when the endpoint 404s: a rejected dispatch with response.status 404 | J1 |
| ″ | does not keep showing the previous BOL's status when the next BOL 404s (stale state) | J1 |
| ″ | clears the previous BOL's status as soon as the id changes, while the next fetch is still in flight | J1 |
| ″ | ignores a late response for the previous BOL (out-of-order fetches) | J1 |
| ″ | shows the Requeue button when failed > 0 | J2 |
| ″ | hides the Requeue button when failed = 0 (CONFIRMED) | J2 |
| ″ | hides the Requeue button when failed = 0 (PENDING) | J2 |
| ″ | asks for confirmation naming the failed count before dispatching anything | J2 |
| ″ | on confirm dispatches requeueBolOms({id}) and then re-fetches the status | J2 |
| ″ | shows the server reason when the requeue returns mode NONE | J2 |
| ″ | on 409 shows "Another requeue is in progress — refresh and retry", with no error toast | J2 |
| ″ | links to the Service Log when the user holds WEB_UI_VIEW_MESSAGES and the message is present | J3 |
| ″ | no link without WEB_UI_VIEW_MESSAGES (failed list still rendered) | J3 |
| ″ | no link when messagePresent is false | J3 |
| ″ | click commits admin/setParentTab 6 and pushes /admin?messageId=901 | J3 |
| `test/components/admin/serviceLogDeepLink.spec.js` | numeric messageId -> getLogDetail({id}) on mount and the detail dialog opens | J4 |
| ″ | non-numeric messageId `"abc"` / `"901abc"` / `""` / `"-1; DROP"` is ignored (4 cases) | J4 guard |
| ″ | no messageId -> no detail fetch | J4 guard |
| `test/store/outboundBolsOmsStatus.spec.js` | getBolOmsStatus GETs /billOfLading/omsNotificationStatus/{id} relative to /v3 and returns the body | J5 |
| ″ | getBolOmsStatus: 404 resolves null without an error toast | J5 |
| ″ | requeueBolOms POSTs /billOfLading/requeueOmsNotification/{id} relative to /v3 and returns the body | J5 |
| ″ | requeueBolOms: 409 ProblemDetail resolves { conflict: true } without an error toast | J5 |

## Failure excerpts (on develop 9e31726)

```
J1  › renders "38/39 delivered · 1 failed" for a FAILED chunked BOL
    Expected pattern: /OMS notification/i
    Received string:  "BOL-1 Outbound BOL BOL # N1 Type REGULAR Carrier  Truck ID  Dock  Seal ID  Parcel Qty  Status CLOSED Created By…
J1  › fetches the status for the BOL on display
    expect(received).toEqual(expected)   - Expected [{ id: 1 }]   + Received []
J1  › re-fetches when outboundBol.id changes AFTER mount
    Expected value: 2   Received array: []
J1  › ignores a late response for the previous BOL (out-of-order fetches)
    Expected pattern: /5\s*\/\s*5\s+delivered/i   Received string: "BOL-2 Outbound BOL …"
J2  › shows the Requeue button when failed > 0
    Expected length: 1   Received length: 0
J2  › on confirm dispatches requeueBolOms({id}) and then re-fetches the status
    expect(btn).toBeDefined()   Received: undefined          (no Requeue button)
J3  › links to the Service Log when …
    Expected: > 0   Received: 0
J3  › no link without WEB_UI_VIEW_MESSAGES (failed list still rendered)
    Expected pattern: /1\s+failed/i   Received string: "BOL-1 Outbound BOL …"   (non-vacuity guard fires first)
J4  › numeric messageId -> getLogDetail({id}) on mount
    Expected length: 1   Received length: 0   Received array: []
J5  › getBolOmsStatus GETs …   (same shape for all four J5 tests)
    expect(typeof actions.getBolOmsStatus).toBe('function')   Expected: "function"   Received: "undefined"
```

## Verdicts

| Class | Count | Tests |
|---|---|---|
| Correct failure (assertion naming the missing behaviour) | **30** | J1 ×14, J2 ×7, J3 ×4, J4 ×1, J5 ×4 |
| Guard, passes pre-fix by design | **5** | J4 non-numeric ×4, J4 absent |
| Setup problem | 0 | none |
| Module-not-found | 0 | none |
| Unexpected pass | 0 | none (the 5 passes are the guards above) |

The J1 "hide" tests and the J2/J3 negative tests would pass vacuously on develop. Each one therefore carries a positive control or a non-vacuity assertion first: the row is rendered, or the failed count is rendered. That control is the line that fails today.

**Satisfiability and guard strength (throwaway prototype).** To show these tests can go green and that the guards catch real defects, I ran them against a minimal prototype of the three files. The prototype was staged in an untracked `.sbdev3672-proto-tmp/` dir, loaded through a scratch jest config's `moduleNameMapper`, and deleted afterwards. `git status` shows only the 3 specs. Results:

- Prototype: **35/35 green**.
- Mutants, each killed by the named test:
  - M1, function gate dropped: J3 no-link-without-function.
  - M2, `messagePresent` dropped: J3 no-link-when-purged.
  - M3, no stale reset on id change: J1 in-flight clear. This mutant survived the first draft; the in-flight test was added to kill it.
  - M4, watch not immediate: 22 tests.
  - M5, any `messageId` accepted: J4 ×3 (`""` is falsy, so it is not distinguishing).
  - M6, 404 toasts: J5 404.
  - M7, requeue without confirm: J2 ×4.
  - M8, no re-fetch after requeue: J2 confirm.
  - M9, `/v3` prefix in the path: J5 GET.
  - M10, NOT_SHIPPED shown: J1 NOT_SHIPPED.
  - M11, late response overwrites: J1 out-of-order.

Re-run this mutation check against the real implementation; it does not replace that.

## Deferred / notes

- **Texts the plan leaves open.** The plan fixes no exact wording for the three NO_RECORD reasons. The specs pin only keyword families (`empty|no pallet|no parcel|nothing to notify`, `purged|retention` plus the retention number, `unknown|no record`) and that the three texts are distinct. Likewise the Service Log link only needs to be an `<a>` or `<button>` whose text matches `/service log/i`.
- **Store error contract** (`null` on 404, `{conflict:true}` on 409) is a gate choice. The plan states the UI outcome but not the store shape. If the implementer prefers rethrowing, change J5 and the component dispatch mock together.
- **Confirm button.** The spec looks inside the open dialog for a button labelled `Confirm|Yes|OK|Requeue`.
- **No E2E.** The plan declares E2E manual-only, so it is not part of this gate.
- **Console noise.** `serviceLogDeepLink.spec.js` logs `Unknown custom element` Vue warnings from `shallowMount` of `serviceLog.vue`. They are harmless, and other specs produce the same noise.

## Full-suite baseline

| Run | Suites | Tests |
|---|---|---|
| develop `9e31726`, before the specs (`yarn test`) | **128 passed / 128** | **2239 passed / 2239** (15.5 s) |
| With the 3 new specs | 3 failed, 128 passed / 131 | 30 failed, 2244 passed / 2274 |

The difference is exactly +3 suites, +35 tests, +30 failures and +5 passes, so no pre-existing test changed state. **Green target after the fix: 131/131 suites, 2274/2274 tests.**

## Run commands

```bash
cd /home/nampark/dev/wms-claude/.claude/worktrees/wms2-web-ui/SBDEV-3672
yarn test -- --testPathPattern="outboundBolOmsStatus|serviceLogDeepLink|outboundBolsOmsStatus"
# -> Test Suites: 3 failed, 3 total / Tests: 30 failed, 5 passed, 35 total
yarn test 2>&1 | tail -8
# -> Test Suites: 3 failed, 128 passed, 131 total / Tests: 30 failed, 2244 passed, 2274 total
```

## git status --short

```
?? test/components/admin/serviceLogDeepLink.spec.js
?? test/components/outbound/outboundBolOmsStatus.spec.js
?? test/store/outboundBolsOmsStatus.spec.js
```

**Gate: PAUSED for approval before implementation.**
