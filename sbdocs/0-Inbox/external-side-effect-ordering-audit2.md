# External Side-Effect Ordering Pattern Audit

## Purpose

This document lists code paths where the system changes local state and also calls another system, printer, or notification service. The safe fix depends on whether the external call is a required command, a best-effort notification, a physical side effect, or UI-only state.

## Pattern categories

| Pattern | Meaning | Safe default |
| --- | --- | --- |
| Required downstream command | External call performs required business state in another source of truth. | Do not treat as best-effort. Add targeted compensation on explicit downstream failure. |
| Best-effort notification | Local system is source of truth; external call informs another system. | Commit local state first, notify after commit, log failures to `service_log`. |
| Physical side effect | Label, picksheet, or printer output. | Do not assume rollback can undo it. Sequence deliberately and make retries/reprints explicit. |
| UI-only optimistic state | Frontend changes local state before backend confirmation. | Usually low risk; reset on failure or commit only after success if operator confusion is possible. |

## Pattern inventory

| ID | Area | File / function | Pattern | Risk | Safest fix |
| --- | --- | --- | --- | --- | --- |
| QA-1 | QA pass | `flask_app/view_helpers/parcel_info_helper.py` / `process_qa_parcel()` | Commits `parcel_status=27` at line 800, then calls `ship_order()` | QA API row is permanently `parcel_status=27` while WMS remains `PICKED` if any downstream call in `ship_order()` fails | Add targeted except block after `ship_order()` that resets the parcel and re-raises |
| QA-2 | QA side effects | `parcel_info_helper.py` / `ship_order()` | Prints label, optionally prints picksheet, then calls WMS `finishedQA` | Physical output exists before WMS packaging succeeds; if WMS fails, operator has paper for a parcel WMS still considers `PICKED` | Keep print-before-WMS ordering (documented); paper waste is the explicit accepted trade-off; WMS-first would create split-brain if WMS succeeds but print fails |
| QA-3 | WMS error handling | `flask_app/common_util/wms_api.py` / `check_wms_qa_response()` and `send_wms_create_advice()` | `response.json()` called unconditionally on non-204 responses; `WmsException` constructed with `data.get('code')` / `data.get('description')` | Non-JSON body (e.g. 502 HTML) raises `JSONDecodeError`; missing `code`/`description` fields produce `None: None` in operator-facing error messages | Handle non-JSON responses; add fallback values; align `send_wms_create_advice` contract to raise `WmsException` instead of returning a dict |
| QA-4 | Return check-in | `flask_app/view_helpers/returns_helper.py` / `process_returned_parcel()` | Commits `rt_` row and `psh_` row, calls Komatik (line 149), then calls `set_parcel_returned_status()` | Komatik network failure or HTTP error prevents `set_parcel_returned_status` from running; parcel never reaches `parcel_status=5` | Wrap `trigger_komatik_started_notification` in try/except; also check HTTP status; log failures to `service_log`; continue to `set_parcel_returned_status` unconditionally |
| QA-5 | Managed return | `returns_helper.py` / `process_managed_returned_parcel()` | Calls `advise_wms_of_managed_return` at line 350 before local `rt_`/`rti_` commit at line 376 | WMS advice can succeed while the QA API DB commit subsequently fails; WMS inventory is updated but no local managed-return record exists | Reorder so local commit (lines 362–376) runs before WMS advice; add `WmsException` compensation to undo the local commit on explicit WMS failure; wrap Komatik in try/except + log |

## Safe solution rules

### Required downstream commands

Examples: QA API calling WMS `finishedQA`; QA API telling WMS to create return advice when WMS inventory depends on it.

Safe options:

1. Add targeted compensation for explicit downstream failure.
2. Use the same open DB connection for compensation — do not open a new connection, which creates a visibility window where inconsistent state is observable.

Avoid:

- Holding DB transactions open around HTTP calls.
- Treating command failure as a harmless notification failure.
- Broadly undoing on timeout when downstream may have succeeded.
- Catching `Exception` broadly — be explicit about which exception types trigger compensation.

### Best-effort notifications

Examples: Komatik notification after return state.

Safe options:

1. Commit the source-of-truth system first.
2. Notify after commit.
3. Log payload and HTTP response to `service_log` (reuse the `insert_wms_response_in_service_log` pattern). For network-level failures with no response object, log `response_data=None`; the helper writes `''` to the `response` column, which is acceptable.
4. Check both network exceptions AND HTTP status codes — `requests.post` does not raise on 4xx/5xx by default.

Avoid rolling back correct local state because a notification failed.

### Physical side effects

Examples: `print_zpl(...)`, `send_print_picksheet_request(...)`.

Safe options:

1. Sequence printing intentionally relative to required WMS/QA API state, and document the chosen ordering explicitly in code.
2. Log print attempts.
3. Make duplicate reprints visible to operators.

Avoid combining printer failure and WMS command failure under one broad catch unless the code knows which side effects already happened.

### Ordering trade-off for QA pass (committed decision)

`ship_order()` currently prints label, then picksheet, then calls WMS. **This ordering is kept intentionally.** Moving WMS before printing would create split-brain if WMS succeeds but the subsequent `print_zpl` raises — WMS would mark the parcel packaged while the QA API resets it to status 25. Paper waste from print-before-WMS is the accepted trade-off; the QA API DB state remains authoritative via the compensation in QA-1. A code comment in `ship_order()` must document this decision.

## Specific recommendations

### QA-1: QA pass compensation

**Prerequisite:** QA-3 must land first so that `WmsException` carries a human-readable message rather than `None: None`.

Implementation steps inside `process_qa_parcel()`:

1. Before executing `parcel_status_update` (line 783), capture the pre-update values:
   ```python
   original_ul_code = row.ul_code
   ```
   Do not re-query the DB for these values — the commit at line 800 will have written `NULL` by then.

2. Wrap `ship_order(...)` (lines 802–804) in a targeted except block, **inside the existing `with engine.connect() as conn:` block** and after `conn.commit()` at line 800, so the same open connection is reused for compensation:
   ```python
   try:
       ship_order(row.carrier_label, f'Parcel {row.parcel_id} Label', row)
   except (WmsException, PrinterSetupError, CupsPrinterError, ConfigurationError) as exc:
       # Compensation: undo the committed parcel state
       conn.execute(
           update(p_)
           .where(p_.c.parcel_id == row.parcel_id)
           .values(parcel_status=25, qa_status=0, qa_scan_date=None,
                   ul_code=original_ul_code, update_date=func.NOW())
       )
       conn.execute(insert(psh_), {
           'parcel_id': row.parcel_id,
           'parcel_status': 25,
           'status_txt': 'Automatic reset: QA pass reversed due to downstream failure',
           'status_date': qa_ts,
           'updated_date': qa_ts,
           'updated_by': rep_id,
       })
       conn.commit()
       raise
   ```

3. The re-raised `WmsException` propagates to `parcel_info.py:126–128`, which formats it as `f'{we.code}: {we.message}'`. After QA-3 hardening, this produces a human-readable message for the operator.

4. After compensation resets to `parcel_status=25`, `parcel_pre_qa_check` (line 736–741) accepts `parcel_status_code in (25, 26, 27, 30)`, so the parcel is immediately rescannable. This is the intended operator flow.

5. The `psh_` audit log will retain the original `parcel_status=27` entry followed by the compensation `parcel_status=25` entry. Do not delete the original entry; the two rows together form a correct audit trail showing the attempt and the reset.

**Prior art:** `set_parcel_qa_fail()` (lines 704–733) is the existing reset-to-25 path for failed QA scans. The compensation above follows the same pattern — `parcel_status=25`, `update_date=func.NOW()` — but additionally resets `qa_status=0`, `qa_scan_date=NULL`, and restores `ul_code`.

**Scope of caught exceptions:**

| Exception | Source | Why compensate |
| --- | --- | --- |
| `WmsException` | `send_wms_qa_complete_request` | WMS packaging failed; state inconsistency |
| `PrinterSetupError` | `print_zpl` — no printer configured | No label printed; WMS not called; safe to reset |
| `CupsPrinterError` | `print_zpl` — printer communication error | No label printed; WMS not called; safe to reset |
| `ConfigurationError` | `send_wms_qa_complete_request` — WMS URL not set | WMS not called; safe to reset |

If WMS succeeds and `print_zpl` subsequently raises, `ship_order` currently calls WMS AFTER printing — so a printer exception means WMS was not reached. After QA-2's comment is in place, this ordering guarantee is documented.

### QA-2: Document the chosen print ordering

Add an explicit comment to `ship_order()` documenting the trade-off:

```python
def ship_order(label: str, job_name: str, parcel_info: "Row"):
    # Ordering: print first, then WMS. This means a WMS failure after printing
    # produces physical output for a parcel that WMS still considers PICKED.
    # The caller (process_qa_parcel) compensates by resetting DB state on any
    # downstream exception. Moving WMS before printing would create split-brain
    # if WMS succeeded but printing subsequently failed.
    print_zpl(label, job_name)

    if parcel_info.full_page_picksheet:
        send_print_picksheet_request(parcel_info)

    if get_config().CONTACT_EXTERNAL:
        send_wms_qa_complete_request(parcel_info)
```

The `reprint_label` function (lines 1078–1093) checks `parcel_status in [27, 30]`. After QA-1 compensation resets to status 25, `reprint_label` correctly refuses, preventing phantom reprints on a reset parcel.

### QA-3: WMS error formatting

`check_wms_qa_response()` (lines 51–74) has three branches. All three must be preserved after hardening:

| Branch | Trigger | Current behaviour | Post-fix behaviour |
| --- | --- | --- | --- |
| 204 No Content | WMS success | Log, insert service log with `None` | Unchanged |
| Non-204, `status != 'success'` | WMS failure | `response.json()` unconditional; `None: None` on missing fields | See below |
| Non-204, `status == 'success'` | WMS quirk (e.g. 200 OK) | Log and treat as success | Unchanged — must not collapse into failure branch |

Fix for the failure branch:

```python
else:
    try:
        data = response.json()
    except ValueError:
        # Non-JSON body (e.g. 502 HTML page, empty body)
        raw = response.text or ''
        insert_wms_response_in_service_log(wms_url, request, {'raw_body': raw})
        raise WmsException(
            str(response.status_code),
            f'WMS returned non-JSON response (HTTP {response.status_code})'
        )

    if data.get('status') != 'success':
        logger.error('Parcel %s: QA failed in WMS', parcel_id)
        insert_wms_response_in_service_log(wms_url, request, data)
        raise WmsException(
            data.get('code') or str(response.status_code),
            data.get('description') or 'WMS returned failure without description'
        )
    else:
        logger.info(f'Non-204 response received from WMS with status success: {response.status_code}')
        logger.info('Parcel %s: QA passed in WMS', parcel_id)
        insert_wms_response_in_service_log(wms_url, request, data)
```

**`send_wms_create_advice` contract change (required for QA-5):**

`send_wms_create_advice()` (lines 101–134) currently returns a failure dict on non-204 non-success responses. To align with `check_wms_qa_response` and make QA-5's `WmsException` compensation reachable, change it to raise `WmsException` instead:

```python
if response.status_code == 204:
    return {'status': 'success'}

try:
    data = response.json()
except ValueError:
    raise WmsException(
        str(response.status_code),
        f'WMS Create Advice returned non-JSON response (HTTP {response.status_code})'
    )

if data.get('status') != 'success':
    raise WmsException(
        data.get('code') or str(response.status_code),
        data.get('description') or 'WMS Create Advice returned failure without description'
    )

return {'status': 'success'}
```

Update `advise_wms_of_managed_return()` (lines 414–435) to remove its `if wms_response.get('status') != 'success': return wms_response` check — exceptions now propagate directly. The function returns `None` on success or skipped (unchanged), and raises `WmsException` on failure (changed).

Update `insert_wms_response_in_service_log` to accept an optional `raw_body` string so non-JSON responses can be persisted:

```python
def insert_wms_response_in_service_log(wms_url: str, request, response_data):
    if isinstance(response_data, str):
        response_str = response_data
    else:
        response_str = json.dumps(response_data) if response_data else ''
    ...
    conn.execute(insert(sl_), {'response': response_str, ...})
```

Alternatively, wrap non-JSON bodies in `{'raw_body': raw}` before passing to the existing helper, which avoids changing the helper signature.

### QA-4: Return check-in — Komatik resilience

Replace the bare `trigger_komatik_started_notification(kom_data)` call at line 149 of `process_returned_parcel()` with:

```python
try:
    response = trigger_komatik_started_notification(kom_data)
    if response is not None and response.status_code >= 400:
        logger.error(
            f'Komatik startReturn HTTP error {response.status_code} for parcel {parcel_id}: {response.text}'
        )
        insert_wms_response_in_service_log(
            f'{get_config().KOMPHP_BASE_URL}services/call/startReturn',
            kom_data,
            {'raw_body': response.text}
        )
except requests.RequestException as exc:
    logger.error(f'Komatik startReturn network failure for parcel {parcel_id}: {exc}')
    insert_wms_response_in_service_log(
        f'{get_config().KOMPHP_BASE_URL}services/call/startReturn',
        kom_data,
        None
    )
```

Change `trigger_komatik_started_notification` to return the `response` object so the caller can inspect `status_code`.

Continue to `set_parcel_returned_status(parcel_id, returns_info['scan_date'])` in all cases — Komatik availability must not gate the final status commit. This resolves the TODO at line 245.

**Note:** `requests.post` raises on network/connection failures only, not on HTTP error responses. Both cases must be handled separately.

### QA-5: Managed return — reorder and compensation

**Prerequisite:** QA-3's `send_wms_create_advice` contract change must land first. The compensation below catches `WmsException`, which `send_wms_create_advice` only raises after that change.

**Cursor lifetime fix:** `managed_return_item_data` is a `CursorResult` iterated inside `advise_wms_of_managed_return`, after the `with engine.connect()` block that executed it (lines 344–346) has already closed. Materialize it before the block closes:

```python
with engine.connect() as conn:
    managed_return_data = conn.execute(managed_return_data_query).first()
    managed_return_item_data = conn.execute(managed_return_item_data_query).fetchall()
```

**Reorder and compensation — applies only to `disposition_id == 2 and receive_now in true_values` branch:**

```python
if disposition_id == 2 and receive_now in true_values:
    logger.info('Parcel %s: receive now', parcel_id)

    # Capture pre-update rt_ state for compensation
    pre_update_rt = conn.execute(
        select(rt_).where(rt_.c.parcel_id == parcel_id)
    ).first()

    # 1. Local commit first
    with engine.connect() as conn:
        update_return_query = get_update_return_query(parcel_id, comment, disposition_id, return_ts, rep_id)
        conn.execute(update_return_query)
        for returned_item in returned_items:
            conn.execute(insert(rti_), {...})
        conn.commit()

    # 2. WMS after commit
    try:
        advise_wms_of_managed_return(
            returned_items, managed_return_data, managed_return_item_data,
            return_location, return_ts
        )
    except WmsException:
        # Compensation: undo the rt_ update and rti_ inserts
        with engine.connect() as conn:
            conn.execute(
                update(rt_)
                .where(rt_.c.parcel_id == parcel_id)
                .values(
                    comment=pre_update_rt.comment,
                    disposition=pre_update_rt.disposition,
                    managed=pre_update_rt.managed,
                    manage_date=pre_update_rt.manage_date,
                    managed_by=pre_update_rt.managed_by,
                )
            )
            conn.execute(
                delete(rti_).where(
                    rti_.c.order_item_parcel_id.in_(
                        [item['item_id'] for item in returned_items]
                    )
                )
            )
            conn.commit()
        return {'status': 'failure', 'messages': str(exc)}

    # 3. Komatik only on WMS success
    try:
        trigger_komatik_managed_notification(parcel_id, managed_return_data.client_id)
    except (requests.RequestException, Exception) as exc:
        logger.error(f'Komatik managedReturn failure for parcel {parcel_id}: {exc}')
        insert_wms_response_in_service_log(...)

else:
    # Non-WMS dispositions: local commit only (unchanged)
    with engine.connect() as conn:
        ...
        conn.commit()
    trigger_komatik_managed_notification(parcel_id, managed_return_data.client_id)
```

**Key decisions:**

- `trigger_komatik_managed_notification` is only called on WMS success. If WMS fails and compensation runs, Komatik is skipped — OMS will not receive a notification for a return the WMS also does not know about. This is the safe default.
- Compensation for the `rt_` update requires pre-capturing the four fields (`comment`, `disposition`, `managed`, `manage_date`, `managed_by`) that `get_update_return_query` overwrites, before the commit runs.
- Compensation for `rti_` inserts is a targeted `DELETE` by `order_item_parcel_id`.
- Apply the same Komatik resilience pattern from QA-4 to `trigger_komatik_managed_notification`.

## Rollout order

| Step | Deliverable | Notes |
| --- | --- | --- |
| 1 | Fix WMS error formatting in `check_wms_qa_response` (QA-3 partial) | Fixes `None: None` so failures are diagnosable before adding compensation |
| 2 | Change `send_wms_create_advice` to raise `WmsException` instead of returning failure dict; update `advise_wms_of_managed_return` to propagate (QA-3 contract change) | **Required before step 6.** Aligns both WMS helpers under `WmsException`. |
| 3 | Add QA-1 compensation in `process_qa_parcel` | Catches `WmsException`, `PrinterSetupError`, `CupsPrinterError`, `ConfigurationError`; resets `parcel_status=25`, `qa_status=0`, `qa_scan_date=NULL`, `ul_code=original_ul_code`; re-raises |
| 4 | Add QA-2 ordering comment in `ship_order` | Documents the print-before-WMS decision and its trade-offs |
| 5 | Add unit tests for QA-1 compensation and QA-3 error formatting | See test checklist |
| 6 | Wrap Komatik calls in `process_returned_parcel` (QA-4) | Try/except + HTTP status check + service_log; continue to `set_parcel_returned_status` unconditionally |
| 7 | Reorder `process_managed_returned_parcel`; add `WmsException` compensation; wrap Komatik (QA-5) | Depends on step 2 for `WmsException` to be catchable. Materialize cursor before reorder. |

## Test checklist

**QA-1 compensation:**
- WMS explicit `WmsException` resets parcel to `parcel_status=25`, `qa_status=0`, `qa_scan_date=NULL`, original `ul_code`
- `PrinterSetupError` from `print_zpl` resets parcel identically
- `CupsPrinterError` from `print_zpl` resets parcel identically
- `ConfigurationError` (WMS URL not set) resets parcel identically
- Compensation failure does not mask the original exception (`raise` not `raise SomeNewException`)
- WMS success does not run compensation
- After compensation, parcel is rescannable (`parcel_pre_qa_check` accepts status 25)
- `psh_` audit log contains both the `parcel_status=27` QA-complete entry and the `parcel_status=25` reset entry

**QA-3 error formatting:**
- Missing `code`/`description` fields no longer produce `None: None`; fallback strings are used
- Non-JSON WMS response body does not raise `JSONDecodeError`; raises `WmsException` with HTTP status as code
- Non-JSON response body is persisted to `service_log`
- Non-204 response with `status == 'success'` does NOT raise (non-204 success branch preserved)
- `send_wms_create_advice` non-JSON response raises `WmsException` (not `JSONDecodeError`)
- `send_wms_create_advice` failure dict response raises `WmsException` with correct code/message

**QA-4 Komatik resilience:**
- Komatik network exception (`requests.RequestException`) still allows `set_parcel_returned_status` to run
- Komatik HTTP 500 response (non-exception) still allows `set_parcel_returned_status` to run
- Both failure cases log to `service_log`

**QA-5 managed return:**
- WMS failure (explicit `WmsException`) restores all four `rt_` fields and deletes inserted `rti_` rows
- WMS failure returns `{'status': 'failure', ...}` to caller — does not raise out of the helper
- WMS failure does NOT trigger `trigger_komatik_managed_notification`
- WMS success DOES trigger `trigger_komatik_managed_notification`
- Komatik failure in managed return does not raise out of the helper
- Non-WMS dispositions (`disposition_id != 2`) are unaffected by the reorder
- `managed_return_item_data` is correctly passed to WMS after cursor is materialized (no empty-result regression)
