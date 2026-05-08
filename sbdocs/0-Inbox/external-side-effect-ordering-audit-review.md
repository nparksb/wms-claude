# Critic Review: External Side-Effect Ordering Audit

**Plan reviewed:** `external-side-effect-ordering-audit.md`
**Reviewed against:** `/Users/np1076/dev/spk/qa-api` codebase
**Review date:** 2026-05-01
**Verdict:** ACCEPT-WITH-RESERVATIONS

All 5 findings (QA-1 to QA-5) are real and confirmed in current code. However, 2 critical issues, 8 major issues, and several gaps must be addressed before implementation begins.

---

## Per-Finding Verification

### QA-1 — `process_qa_parcel` commits status 27 then calls `ship_order`

**Problem confirmed.** `parcel_info_helper.py:800` commits `parcel_status=27` before `ship_order()` runs. If `send_wms_qa_complete_request` raises `WmsException`, the QA API row is permanently `parcel_status=27` while WMS still considers the parcel `PICKED`.

**Recommendation issues:**

- Plan says "Restore `ul_code` from original row" but never specifies WHERE to capture it. The `row` object (from the frozen query result) holds the pre-update value. An implementer who re-queries after commit reads `NULL` (the just-written value), silently producing a buggy compensation that "restores" `ul_code` to `NULL`. Must be explicit: capture `original_ul_code = row.ul_code` BEFORE `parcel_status_update` executes.
- Plan says "Reset parcel to Waiting for QA (status 25)" in recommendations but does NOT mention `qa_status=0` or `qa_scan_date=NULL`. These appear only in the test checklist — inconsistency will cause implementation to miss these fields.
- Plan says "Insert `parcel_status_history` explaining the reset" but does not specify what status value to write or the `status_txt` wording. Most defensible: `parcel_status: 25` with text like `"Automatic reset: WMS packaging failed after QA complete commit"`.
- `set_parcel_qa_fail()` (`parcel_info_helper.py:704-733`) is existing prior art for the reset-to-25 path. The plan should reuse this pattern (adjusted for `qa_scan_date=NULL`, `ul_code=<captured>`) rather than inventing a new compensation path.
- Transaction scope unspecified: after `conn.commit()` at line 800, the connection is still open inside `with engine.connect() as conn:`. Compensation should reuse this same `conn` (not open a new connection) to avoid a visibility window where `parcel_status=27` is observable.

**What the plan misses:**

- `PrinterSetupError` and `CupsPrinterError` from `print_zpl` (inside `ship_order`) also leave `parcel_status=27` corrupted after the pre-`ship_order` commit. Plan only mentions `PicksheetApiError`.
- `ConfigurationError` from `send_wms_qa_complete_request` (when WMS URL is unconfigured, `wms_api.py:23`) has the identical corruption problem.
- After compensation resets to status 25, `parcel_pre_qa_check` accepts `parcel_status_code in (25, 26, 27, 30)` — so the parcel is immediately rescannable by the operator. Plan should verify and document this as an intentional property.
- Caller `parcel_info.py:126-128` catches `WmsException` and formats `f'{we.code}: {we.message}'`. After QA-3 hardening, this produces a meaningful message. Plan should verify the user-facing message becomes useful (e.g. "QA failed: HTTP 502 / Bad Gateway").

---

### QA-2 — `ship_order` prints before WMS call

**Problem confirmed.** `parcel_info_helper.py:1015-1021`:

```python
def ship_order(label: str, job_name: str, parcel_info: "Row"):
    print_zpl(label, job_name)
    if parcel_info.full_page_picksheet:
        send_print_picksheet_request(parcel_info)
    if get_config().CONTACT_EXTERNAL:
        send_wms_qa_complete_request(parcel_info)
```

Physical label printed first, then picksheet, then WMS. If WMS fails after both printers have ejected pages, the operator has paper output for a parcel WMS still considers `PICKED`.

**Core ordering decision is still open.** Plan says "decide intended ordering" — this is deliberation deferred, not a recommendation. The plan must commit to one of:

1. Move WMS call BEFORE printing — if WMS fails, no paper waste; but then operator never gets a label for a successfully confirmed parcel.
2. Keep current ordering, accept paper waste, but add DB compensation and emit an operator instruction ("discard printed label for parcel X").
3. Accept physical output is unrecoverable and document the failure mode explicitly.

**What the plan misses:**

- Picksheet is conditional (`parcel_info.full_page_picksheet`). Picksheet failures only matter for that subset of parcels.
- `reprint_label` (`parcel_info_helper.py:1078-1093`) depends on `parcel_status in [27, 30]`. After QA-1 compensation resets to 25, `reprint_label` correctly refuses — plan should verify this interaction.

---

### QA-3 — `check_wms_qa_response` produces `None: None`

**Problem confirmed.** `wms_api.py:60-68`:

```python
else:
    data = response.json()                              # raises JSONDecodeError on non-JSON
    if data.get('status') != 'success':
        raise WmsException(data.get('code'), data.get('description'))  # None: None when fields missing
```

**Recommendation is correct but incomplete:**

- `check_wms_qa_response` has THREE branches: 204 (success), non-204 with `status != 'success'` (raise), non-204 with `status == 'success'` (success-with-quirks log). Plan only addresses the failure case. Hardening must preserve the non-204 success branch or legitimate WMS 200s become raised exceptions.
- `insert_wms_response_in_service_log` accepts JSON-decoded `response_data`, writing `json.dumps(response_data) if response_data else ''`. For a non-JSON response body, the raw text is never persisted. Plan should specify: extend the helper to accept raw text, or wrap non-JSON body in a fallback dict like `{'raw_body': response.text}`.
- A shared response-decoding helper used by BOTH `check_wms_qa_response` and `send_wms_create_advice` would prevent the same bug from re-emerging independently. Plan should specify this rather than patching the two functions separately.

---

### QA-4 — `process_returned_parcel` Komatik failure skips final commit

**Problem confirmed.** `returns_helper.py:133-151`:

```python
insert_new_return_row(...)           # commits inside (line 216)
insert_parcel_status_history(...)    # commits inside (line 236)
trigger_komatik_started_notification(...)   # network call, no try/except
set_parcel_returned_status(...)     # commits inside (line 279) — never reached on exception
```

**Recommendation is correct but oversimplified:**

- `requests.post` does NOT raise on HTTP error status by default; it only raises on connection/network failures. A Komatik server returning 500s is currently silently ignored (just logs `response.status_code` at line 248). Plan's "wrap in try/except" only catches network exceptions. Must also check `response.status_code` and treat 4xx/5xx as failures.
- The TODO at line 245 (`# TODO: Handle error responses from the OMS.`) is the exact target of this fix — reference it.
- On Komatik connection error with no response object, `insert_wms_response_in_service_log` receives `response_data=None` and writes `''` to the response column. This is acceptable but plan should state it explicitly.

---

### QA-5 — `process_managed_returned_parcel` WMS before local commit

**Problem confirmed**, but plan's line numbers are stale and the exception flow description is wrong.

**Stale line numbers:**
- Plan claims `update_return_query` commit at lines 345-359; actual lines are **362-376**.
- Plan claims `advise_wms_of_managed_return` at line 333; actual line is **350**.

**Critical: the `WmsException` compensation is unreachable as written.** `send_wms_create_advice` (`wms_api.py:128-134`) **returns a dict on failure** — it does not raise `WmsException`. `advise_wms_of_managed_return` (`returns_helper.py:428-435`) returns that dict. The caller at line 355 checks `if wms_response is not None`. Writing `try: ... except WmsException: ...` around `advise_wms_of_managed_return` will never fire. An implementer following the plan literally produces unreachable compensation code while the bug remains unfixed.

Fix options:
- (a) QA-3's hardening of `send_wms_create_advice` explicitly changes its contract to raise `WmsException` on non-success. QA-5's compensation then catches it. **QA-5 is only implementable AFTER this contract change lands.** Plan must document this dependency.
- (b) Write QA-5's compensation against the existing return-dict pattern: `if wms_response is not None: <compensate and re-return failure>`.

**Additional issues:**

- The reorder makes compensation more invasive than QA-1: must roll back `rt_` update (capturing `comment`, `disposition`, `managed`, `manage_date`, `managed_by` before overwrite) AND delete just-inserted `rti_` rows. Plan treats this as equivalent to QA-1's single-row compensation.
- Current code's early return at line 357 (`return {'status': 'failure'}`) means `trigger_komatik_managed_notification` is also skipped on WMS failure. After reorder with local-commit-first, plan must decide: if local commit succeeds but WMS fails, does Komatik still fire? If yes, OMS thinks the return is managed even though WMS does not.
- This reorder only matters when `disposition_id == 2 and receive_now in true_values` (`returns_helper.py:348`). Other dispositions skip WMS entirely. Plan should narrow scope to this branch.
- `managed_return_item_data` is a `CursorResult` iterated inside `advise_wms_of_managed_return` (called at current line 350, after the second `with engine.connect()` block at lines 344-346 closes). On reorder, verify cursor lifetime — the data must be materialized into a list before the connection closes.
- Apply QA-3 hardening to `send_wms_create_advice`: it calls `response.json()` unconditionally at line 134, crashing on non-JSON (502 HTML pages, empty bodies). Same root cause as QA-3.

---

## Critical Issues

### C-1: QA-5 `WmsException` compensation flow does not exist

`send_wms_create_advice` returns a dict; it does not raise `WmsException`. A `try/except WmsException` around `advise_wms_of_managed_return` will never fire. Implementation follows the plan literally → unreachable code → bug persists silently.

**Required resolution before implementation:** Choose option (a) or (b) above and document explicitly.

### C-2: Rollout step 6 silently depends on step 5 changing `send_wms_create_advice`'s contract

Step 5 says "apply QA-3-style hardening" — implementers read this as defensive parsing only, not a contract change from return-dict to raise-exception. Step 6's compensation is only reachable if step 5 changes the contract. This dependency is undocumented; an implementer doing the steps in order will write dead code in step 6.

**Required resolution:** Rollout step 5 must explicitly state: "Change `send_wms_create_advice` to raise `WmsException` on non-success (aligning with `check_wms_qa_response`), and update `advise_wms_of_managed_return` to propagate or convert that exception."

---

## Major Issues

| # | Finding | Impact |
|---|---|---|
| M-1 | `ul_code` capture is under-specified — plan never says capture BEFORE the update; naive re-query reads `NULL` | QA-1 compensation silently restores wrong value |
| M-2 | `qa_status=0` and `qa_scan_date=NULL` in test checklist but absent from recommendation summary | Implementation misses these fields |
| M-3 | Transaction scope for QA-1 compensation unspecified — must reuse existing open `conn` | Visibility window of `parcel_status=27` if new connection opened |
| M-4 | QA-3 has a non-204-success branch that must be preserved; plan only describes fixing the failure branch | Legitimate WMS 200s become raised exceptions after hardening |
| M-5 | Plan says "apply QA-3 hardening to `send_wms_create_advice`" but doesn't specify whether to align contracts (raise) vs. keep return-dict | Directly determines whether QA-5 compensation is reachable |
| M-6 | Komatik `requests.post` only raises on network errors; HTTP 4xx/5xx are silent. Plan's try/except misses HTTP-error responses | Komatik 500s logged as success; operator not informed |
| M-7 | QA-5 line numbers are stale (`345-359`/`333` → actual `362-376`/`350`) | Implementer must re-locate before working |
| M-8 | `set_parcel_qa_fail()` at line 704 is prior art for the reset-to-25 pattern; plan should reference and reuse | Risk of inconsistent compensation implementation |

---

## Open Questions

1. Should `psh_` audit log show both the `27` entry and the compensation `25` entry, or should the `27` entry be deleted on compensation? (Affects QA-1 audit trail design.)
2. Should `CupsPrinterError` / `PrinterSetupError` from `print_zpl` also trigger the QA-1 compensation? They leave identical `parcel_status=27` corruption.
3. Should `ConfigurationError` (WMS URL unconfigured) trigger compensation? Same corruption.
4. QA-2: what is the intended ordering? This must be decided — it cannot remain deferred indefinitely.
5. Is there any value in a circuit-breaker around Komatik to prevent retry-storms when OMS is known-down?
6. `process_returned_parcel` has no error handling if `set_parcel_returned_status` itself fails (DB error after Komatik succeeds). In scope?

---

## Rollout Order — Issues

Current rollout order is sequenced correctly in principle. Required additions:

| Step | Addition needed |
|---|---|
| 1 | No change. Fix `None: None` first — correct. |
| 2 | Must specify: use existing `conn`, capture `ul_code`/`qa_status` before update, reset all four fields. |
| 3 | Tests must extend `test_process_qa_parcel_*` in `tests/test_unit/test_view_helpers/test_parcel_info_helper.py:493-567`; update `mock_ship_order` fixture to allow `side_effect = WmsException(...)`. |
| 4 | Must commit to a `ship_order` ordering decision (QA-2) — cannot remain open. |
| 5 | Must explicitly include the `send_wms_create_advice` contract change: switch from return-dict to raise-`WmsException`. Otherwise step 6 produces dead code. |
| 6 | Depends on step 5 landing first. Compensation must handle multi-table rollback (`rt_` + `rti_`), not just single-row as in QA-1. |

---

## Test Checklist — Gaps

Existing checklist items are valid. Missing:

- `PrinterSetupError` / `CupsPrinterError` from `print_zpl` do NOT reset QA status (or confirm they DO, and add test)
- Komatik HTTP 500 response (not connection error) still allows `set_parcel_returned_status` to run
- After QA-1 compensation, parcel is rescannable (i.e. `parcel_pre_qa_check` accepts status 25)
- `WmsException` message after QA-3 is human-readable (not `None: None`)
- `send_wms_create_advice` non-JSON response (e.g. HTML 502) does not raise `JSONDecodeError`
- QA-5 compensation restores all four `rt_` fields (`comment`, `disposition`, `managed`, `manage_date`, `managed_by`) and deletes inserted `rti_` rows
- QA-5 WMS failure does NOT trigger `trigger_komatik_managed_notification`

---

## Upgrade Criteria

To upgrade verdict from ACCEPT-WITH-RESERVATIONS to ACCEPT, the plan requires:

1. Resolve QA-5 to use actual control flow (return-dict or explicit raise via QA-3 contract change)
2. Document QA-3 → QA-5 contract dependency explicitly in rollout order
3. Specify `ul_code` capture point and full field list for QA-1 compensation: `parcel_status=25`, `qa_status=0`, `qa_scan_date=NULL`, `ul_code=<captured before update>`
4. Commit to a `ship_order` ordering decision (QA-2)
5. Address Komatik HTTP-status (not just network) failure handling
6. Specify transaction scope (reuse existing `conn`) for QA-1 compensation
