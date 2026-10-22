---
name: sbdev-2778-vs-2236-return-autoreceive-conflict
description: "SBDEV-2778 asks to restore the RETURN auto-receive that SBDEV-2236 deliberately deleted; same stakeholder on both, plus the latent boxtype NPE and dead-code chain found while planning it"
metadata: 
  node_type: memory
  type: project
  originSessionId: d5f13cf8-214a-4fc1-a051-83bf1e52421b
  modified: 2026-08-04T12:44:29.357Z
---

SBDEV-2778 ("Return to Inventory does not fully receive / close the return inbound BOL") asks to
restore exactly the code **SBDEV-2236 deliberately deleted** — v2 `AdviceRestController` RETURN
auto-receive block. 2236: merged 2026-05-15, PR wms2-api#24, commit `7f9c250`, requester **David
Oppenheim**, who is also an **assignee on 2778**. 2236 §3.2:245 rejected keeping auto-receive because
it *"Conflicts with OMS-team requirement (from David Oppenheim) that physical confirmation must
precede the WMS stock increment."* Tests now ENFORCE the absence:
`AdviceRestControllerUnitTest` `shouldCreateReturnAdviceWithoutAutoReceive` (`@DisplayName :523`,
method `:524`) and `shouldCreateReturnAdviceAndIgnorePrinterId` (`:566`) — so v2 ignoring `printer_id`
is deliberate, not an oversight. **Never "port the v1 block back" without resolving this.**

Plan drafted 2026-07-30: `sbdocs/1-Projects/wms2/plan/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md`
+ verify script, `db_verified: true`, status draft/pending-approval, **blocked on Q0 then Q1**. Design
chosen: gate auto-receive on an explicit `qa_confirmed` assertion from OMS rather than reverting 2236.
`wms-tdd-gate` deliberately deferred until Q0/Q1 land.

**Q0 (ask BEFORE the 2236 question):** OMS already has TWO return→WMS flows and already distinguishes
advise from receive. `QaReturnService::sendReturnRestockAdvice` (`:590`) produced the repro and sends
**no** `printer_id`; `receiveReturnInWms` (`:196-286`) is documented "Flow 2: Receive + Print" and
**does** send `printer_id`. Different payload contracts too (`type`/`client_id`/`day_of_delivery` vs
`advice_type`/`client_code`/`expected_date` via `buildAdvicePayload:2337`). If Flow 2 is the sanctioned
path, `qa_confirmed` is the wrong fix and the ticket is a wiring error.

LANDMINES found while planning (all verified, all reusable):
- **`getErrorMap()` (`WebserviceBusinessExceptionClientSide:46-51`) emits ONLY `status` + `description`.**
  `WebserviceError.code`/`.errorCodeName` are set in the ctor (`:47-49`) but never serialized ⇒ **no WMS
  error code has ever reached OMS.** Proof: OMS's `stripos($message,'ENTITY_ALREADY_EXITS')`
  (`QaReturnService.php:658`) can never match — code 101's text is `"entity %1s already exists for %2s"`
  (`WmsConstants:1262`) and the literal token lives only in `getErrorCodeName` (`:1330`). Dead code.
  Any plan relying on OMS branching per WMS error code must change `getErrorMap()` first.
- **`optionalBoxtype.get()` NPE ⇒ HTTP 500.** `AdviceRestController:245` inits
  `Optional<Boxtype> optionalBoxtype = null` and assigns it only inside
  `if (isNotEmpty(getBoxId()))`, but `:261` dereferences unconditionally. Latent only because OMS
  hard-codes `'box_id' => 1` (`QaReturnService.php:747`). **v1 identical at `:258`.** Needs its own
  v1+v2 ticket (SBDEV-2116 unguarded-Optional family).
- **v1's 3-step boxtype fallback chain is DEAD CODE on the REST create path** (both versions) because
  `:262` always sets `boxtypeId`. Don't port it; a verify script that asserts it forces dead branches.
- **`ReceivingService:534` → `sendStockChangeMessage` → `sendAfterCommit`** (`MessageService:109-111`)
  fires a `CODE_RECEIVING_RETURN` STOCK_UPDATE per position. A partial multi-position receive sends OMS
  N−1 stock increments for a return OMS then rolls back (`QaReturnService.php:330`
  `DB::connection('tenant')->transaction`). 2236 got explicit sign-off for moving this notification to
  dock-receive time (its checklist `:312`) — re-introducing auto-receive reverses that.
- **`create()` has NO `@Transactional`** (v1 and v2), so `adviceRepository.save` (`:198`) and each
  position save (`:272`) commit immediately. **Any validation that throws AFTER those saves burns
  `externalid=RETURN{parcel_id}`**, and every OMS retry then dies on the duplicate guard (`:139-142`)
  ⇒ return unmanageable without DB surgery. Validate BEFORE persisting.
- `Advice` / `Adviceposition` / `Printer` are **NOT** `@Cacheable` (only ApiTimestampFormatResolver,
  OutboxDispatchService, ClientService, ItemdataService, LocationService, SyspropService are) ⇒ no
  `@CacheEvict` obligation on advice state flips.
- Jackson `FAIL_ON_UNKNOWN_PROPERTIES` is disabled in 4 places (`WebConfigurer:78,108,121`,
  `WmsObjectMapper:41`) ⇒ an old WMS silently discards a new OMS field and returns 204 having done
  nothing. Deploy WMS before OMS for any additive-field change.

DB evidence (wms2-wineco-dev 2026-07-30): `RETURN/FINISHED` 2214 but newest `2025-04-22` (migrated v1
rows); `RETURN/OPEN` 1 = the repro `advice id=30494322 IBOL012604 externalid=RETURN529599`, 0
`goodsreceipt` rows. A `processdefault=true` RETURN printer DOES exist (`id=30346045`) ⇒ the ticket's
"Returns Printer / SBDEV-2206" theory is **refuted**. hydra-dev2: 9 FINISHED, newest 2026-03-09.

**STATUS UPDATE 2026-08-04:** Q0/Q1 resolved — the BA (Brent Campbell) ruled Return QA *is* the
physical confirmation, so the design became **restore v1 behavior behind a default-ON kill switch**
(`RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`, Flyway `V2.2.09`), NOT the `qa_confirmed` assertion field.
Implemented in wms2-api **PR #123** (branch `bugfix/SBDEV-2778-restore-return-advice-auto-receive`),
open, not merged. No OMS change. Verify script 110 pass / 0 fail with `RUN_MVN=1`.

**`/rest/advice/create` batch size is always 1 — measured, not assumed.** Both senders that can emit a
RETURN advice hard-code a one-element list: `oms-laravel-api` `WmsApiService::createReturnAdvice` (via
`makeWmsRequest`, which wraps a single advice dict) and legacy `v1/qa-api`
`build_wms_create_advice_request` (`request = [{...}]`). Empirically **5,226 `ADVICE_IMPORT` payloads
in the `message` table across wineco-uat + wineco-dev + hydra-dev2, 2020-03-26 → 2026-07-31, are 100%
batch size 1** (query: `json_array_length(message::json)` where `process='ADVICE_IMPORT'`). Useful
because the endpoint's `List<AdviceDto>` signature *looks* like a bulk API and isn't used as one — so
narrowing multi-advice behavior costs nothing. PR #123 exploits this to reject a RETURN advice that
shares a request with any other advice: `create()` has no `@Transactional` and each receive commits in
its own tenant tx, so a failure at advice N leaves 1..N-1 with committed inventory and one 400 for the
whole request, and the OMS retry then dies on the duplicate guard — the non-transactional-`create()`
landmine above, at batch scope.

See [[negative-test-verify-scripts-before-trusting-them]],
[[verify-script-traps]] and
[[los-sysprop-description-varchar-255-aborts-migration]].

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

2778 asks to restore what 2236 deliberately deleted (PR #24, 7f9c250) with David Oppenheim on both; tests ENFORCE the absence so don't "port the v1 block back"; ask Q0 first (OMS Flow 2 receiveReturnInWms already means receive-now); LANDMINES: getErrorMap() never emits the error code so OMS's ENTITY_ALREADY_EXITS branch is dead, optionalBoxtype.get() NPE→500 when box_id omitted (v1+v2), v1's boxtype fallback chain is dead code, create() has no @Transactional so validating after save burns externalid and bricks retries
