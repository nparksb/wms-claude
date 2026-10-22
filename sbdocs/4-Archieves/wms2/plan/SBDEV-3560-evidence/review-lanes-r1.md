---
ticket: SBDEV-3560
tier: T2
reviewed_commit: da585d6 (wms2-web-ui, bugfix/SBDEV-3560-edit-dialogs-close-on-refused-save)
date: 2026-09-28
---

# SBDEV-3560: review lanes, round 1

The lanes ran as subagents that cannot write files, so their reports are recorded here by the author.

## Lane 1: code-reviewer (sonnet). Verdict: COMMENT, 0 blockers on the diff's scope

| Sev | Finding | Disposition |
|---|---|---|
| High (conf. medium) | `store/admin/shippers.js#editShipper` never checks a 200-with-`errors` body, although `addShipper` does (`ComUtil.checkResponseError`) | **No change needed.** The only handler for `PATCH /v3/client/{id}` is Spring Data REST (`ClientRepository`: `@RepositoryRestResource(collectionResourceRel = "client", path = "client")`). `ClientController` maps only `/create`, `/setSection`, `/setPrinter` and `/toggleReceiving`, so no MVC handler can return an `errors` body; a refusal on this path comes back as an HTTP status. `/client/create` is an MVC endpoint, which is why `addShipper` checks. |
| High | Sibling dialogs the sweep missed: `addShipper`, `roleFunctionEdit`, `groupRoleEdit`, `userGroupEdit`, `createSectionDialog`, `editPackagingDialog`, `editRepleishmentRequest` | Scope question for Nam. See the consolidated list below. |
| Medium | `updatePONumber` hoisted `searchInboundOpenNotices` above the errors check. Inert, but unexplained | **Fixed** in 6e2b5e8: the refresh is back after the branch and the action returns a `saved` flag. Mutants P1–P3 were all killed. |
| Medium | A null `results` in `updatePONumber` lands in the catch and shows the generic network toast | **No change.** This behaviour predates the ticket, and the dialog now correctly stays open. The reviewer suggested leaving it. |
| Low | `try/finally` without a `catch`, so a throwing action would surface as an unhandled rejection | **No change.** Every backing action catches everything, so the path cannot be reached. The `finally` is already strictly safer than the `editPrinter` precedent. |
| Low | The "editRole previously not awaited" wording | Only the review prompt said this; the ticket and commit do not. Only `editGroup` was missing its `await`. |

Independently confirmed: the `editUser` exclusion is correct, 49/49 new tests pass, and the full suite has 1655 passing tests with the same 5 suites failing to load as on origin/develop.

## Lane 2: verifier (sonnet). Verdict: PASS for the declared scope

- AC1–AC4: VERIFIED. 49/49 tests pass on a fresh run. The lane reproduced 3 of the mutants in a /tmp copy (editGroup without `await`, `shipper = null` moved outside the branch, the PO errors branch without `return false`), and all 3 were killed.
- The `editUser` exclusion was VERIFIED against `store/admin/user.js`.
- AC5 sweep: 67 candidate files, each method read by hand, **including closes that go through events whose names do not start with "close"**. That class is the blind spot of the author's instrument. Further sites found, all with the same shape (a write, then an unconditional close; the backing action resolves `undefined`):
  - admin: `roles/roleFunctionEdit.vue` save, `groups/groupRoleEdit.vue` save, `users/userGroupEdit.vue` save, `shippers/addShipper.vue` addShipper, `users/importUser.vue` execute, `serviceLog/resendConfirmation.vue` execute (not awaited)
  - receiving: `open/popups/deleteOpenNotices.vue` (`hideDeleteNotice`), `open/popups/closeOpenNoticePop.vue` (`hideCloseNotice` and `$router.push`; the store carries "Error 500 but still will close the open notices // Consult with Sir Nam"), `open/create/createPurchaseOrder.vue` createPo (**high**: it discards a multi-line PO), `open/popups/addMissingSku.vue`, `open/receive/createPallet.vue` (not awaited), `open/popups/adjustAmountOpenNoticeReceipt.vue`, `open/popups/deleteOpenNoticeReceipt.vue`
  - outbound/processes: `processes/clubRuns/activate/confirmationPop.vue`, `processes/transferPicking/activate/confirmationPop.vue`, `outbound/transfer/activate/confirmationPop.vue` (`activateTransferOrder` calls `data.callBack()` without checking `results.errors`)
  - internalOps: `replenishment/open/editRepleishmentRequest.vue` (not awaited), `replenishment/open/cancelRequestPop.vue`
  - masterData: `location/sections/createSectionDialog.vue`, `material/packaging/editPackagingDialog.vue`
- Not exhaustive: `admin/systemManagement/actionConfirmation.vue` (unawaited background triggers, no typed data) and a few export and select-lane popups were not opened.

## Instrument disagreement, as a finding

The author's two instruments (grep, then a script matching a same-method dispatch followed by `closeOverlay()` or `$emit('close…')`) found 4 sites. The hand-read sweep found about 20 more. The miss came from close paths routed through a helper (`this.close()`, `this.closeEdit()`, `this.closeDialog()`, `this.initialize()`) or through events not named `close*`. Both of the author's instruments matched the same literal, so they were one instrument, not two.
