# SBDEV-1512 — QA station managed-return flow (qa-api / qa-ui), evidence lane

Derived from `origin/develop` in both repos (checkouts are 2 commits behind; every citation below
was read with `git show origin/develop:<path>` or `git grep -n <pat> origin/develop`).

| Repo | Path | `origin/develop` HEAD |
|---|---|---|
| qa-api | `/home/nampark/dev/wms-claude/v1/qa-api` | `b905d77` *docs: add branching strategy document following GitFlow* |
| qa-ui | `/home/nampark/dev/wms-claude/v1/qa-ui` | `ad4284b` *docs: add branching strategy document following GitFlow* |
| wms-api (v1) | `/home/nampark/dev/wms-claude/v1/wms-api` | (read for the receiving side) |

Live DB evidence: MCP `wms1-shipitez1` → `current_database()` returned **`wh01_shipitez`**, PostgreSQL 14.23.

---

## 0. Headline findings (read this first)

Four independent defects sit on this path. Any one of them reproduces "restock selected, no UL,
bottles disappear". Ranked by how well each matches Ryan Fernandez's 2026-05-29 wording.

| # | Defect | Where | Matches "restock selected every time, no UL, bottles disappear"? |
|---|---|---|---|
| **A** | The disposition dropdown pre-selects the shipper's preference **without emitting `change`**, so the parent keeps its hard-coded default `disposition = 1` and the request never takes the WMS branch. | `qa-ui components/returns/dispositionSelection.vue` + `pages/manageReturn/_id.vue` | **Exact.** Operator sees "Restock Inventory" in the box, submits, gets a green success toast, and no advice is ever sent. |
| **B** | Damaged quantity is **never sent to the WMS** — `amount_of_bottles = qty_undamaged`; a fully-damaged return sends nothing at all (the whole call is skipped) and leaves no trace anywhere. | `qa-api flask_app/common_util/wms_api.py:198` + `view_helpers/returns_helper.py:486` | **Exact for damaged stock.** This is the literal SBDEV-1512 scope ("Receive Damaged from Returns"). |
| **C** | On a WMS failure the UI **shows no error at all** and the modal spinner never clears — `messages` comes back as a *string* and `processApiErrors` calls `.forEach` on it. | `qa-api flask_app/views/parcel_info.py:232` + `qa-ui store/util.js:32` | Explains why the operator reports silence rather than an error. |
| **D** | v1 WMS `advice/create` **silently skips receiving** when no `printer` row of type `RETURN` has `processdefault = true`, then marks the advice `FINISHED` and returns **204 success**. | `v1/wms-api .../controller/rest/AdviceRestController.java:306-318,337` | Exact shape, but **refuted for `wh01_shipitez`** — that DB does have a default RETURN printer (see §3.4). Not checked for ShipItEZ's second warehouse. |

---

## 1. The managed-return flow, UI → WMS

### 1.1 Ordered steps

1. **Scan / search the parcel.** `qa-ui store/returnsCall.js:55` — `GET /parcels?exact_search=<scan>`.
   A parcel already managed is rejected client-side: `store/util.js:78`, `if (parcel['return']['managed'] === 1)`.
2. **Open the manage screen.** `store/returnsCall.js:158` — `this.$router.push(\`/manageReturn/${parcel.parcels[0].internal_tracking_number}\`)`.
3. **Page mount** (`pages/manageReturn/_id.vue:63-69`) fires three calls:
   - `GET /system/returns/dispositions` (`returnsCall.js:166`)
   - `GET /system/returns/comments` (`returnsCall.js:175`)
   - `GET /parcels?exact_search=<id>` if the parcel isn't already in the store.
4. **Build the per-item payload.** Both `pages/manageReturn/_id.vue:75-83` and
   `components/returns/manageReturnTable.vue:59-67` seed
   `{ item_id, qty_returned: items.qty, qty_undamaged: items.qty, qty_damaged: 0, qty_missing: 0 }`
   — i.e. **everything defaults to fully undamaged**. Kits are expanded first
   (`expandChildItems`, product_type 23 = virtual kit → expand children, 22 = physical kit → keep parent).
5. **Operator edits Damaged / Missing.** `manageReturnTable.vue:200-201`:
   `changedObject.qty_returned -= qtyDamagedChangeAmt` and `changedObject.qty_undamaged -= qtyDamagedChangeAmt`.
   **"Qty Returned" in this table is the restockable quantity, not the physically-returned quantity** —
   marking a bottle damaged *decrements* it. Same for missing (`:229-230`).
6. **Operator picks a disposition.** `components/returns/dispositionSelection.vue` — see §2.
7. **Submit.** `pages/manageReturn/_id.vue:128-139` builds
   `{ comment, disposition_id, returned_items }` and, **only if `dataObject.disposition_id === 2`**,
   adds `receive_now = true` and `return_location = this.parcelInfo.fulfillment_facility_code`.
   Then `POST /parcels/returns/<parcel_id>` via `returnsCall.js:184`.
8. **qa-api view.** `flask_app/views/parcel_info.py:201-244`,
   `@parcel_info.post('/parcels/returns/<parcel_id>')` → `view_manage_returned_parcel_by_parcel_id`.
   Validates with `returns_helper.validate_parcel_for_managed_return(parcel_id)` (raises `ParcelStateError` → 400),
   then calls `process_managed_returned_parcel(...)`.
9. **qa-api helper.** `flask_app/view_helpers/returns_helper.py:345-449`. Reads client data
   (`get_client_data_query`), computes a facility-local `return_ts`, reads
   `get_managed_return_data_query` (parcel + client_code) and `get_managed_return_item_data_query`
   (`order_item_parcel_id`, `product_sku`, `client_code`, `assigned_quantity`), then branches on
   `if disposition_id == 2 and receive_now in true_values:` (`:380`).
10. **DB writes — restock branch** (`:382-396`), all in one `engine.connect()` block ending in `conn.commit()`:
    - snapshot: `pre_update_rt = conn.execute(select(rt_).where(rt_.c.parcel_id == parcel_id)).first()`
    - `UPDATE returns SET comment, disposition, managed=1, manage_date, managed_by WHERE parcel_id = ?`
      (`get_update_return_query`, `:504-510`)
    - one `INSERT INTO return_item (order_item_parcel_id, quantity_damaged, quantity_undamaged, quantity_missing)`
      per returned item (`:389-395`). **`order_item_parcel_id` is the PK** (`models.py:686`), so a second
      manage attempt on the same parcel would hit an integrity error rather than upsert.
11. **WMS call.** `advise_wms_of_managed_return` (`:478-496`) — gated twice:
    `if total_returned_items > 0 and get_config().CONTACT_EXTERNAL:` where
    `total_returned_items = sum([item['qty_returned'] for item in returned_items])`.
    Otherwise it logs `'No returned items, skipping call to create advice in WMS.'` and returns `None`.
12. **HTTP to the WMS.** `common_util/wms_api.py:117-168`:
    `wms_base_url = get_wms_base_url(return_location)` (SELECT on `wms_url_lut`, §6),
    `url = f'{wms_base_url}rest/advice/create'`, `response = requests.put(url, json=request)`.
    Body from `build_wms_create_advice_request` (`:171-213`): one advice with
    `'type': 'RETURN'`, `delivery_note_number = reference_id = shipment_id = f'RETURN{parcel_id}'`,
    and one position per item with `'amount_of_bottles': returned_items[item.item_id]['qty_undamaged']`.
13. **WMS side** — `v1/wms-api .../controller/rest/AdviceRestController.java:105`
    `@PutMapping(value = "/create", ...)`. On `AdviceType.RETURN` it auto-receives: §3.
14. **Post-success.** `trigger_komatik_managed_notification_resilient(parcel_id, client_id)` (`:423`)
    → `POST {KOMPHP_BASE_URL}.../manageReturn` with OMS basic auth, then
    `process_managed_email_notifications(client_data, local_time, parcel_id)` (`:444`) inserts rows
    into the notification log for a cron to mail. Response `{'status': 'success', 'messages': ''}`, HTTP 200.
15. **UI post-success.** `returnsCall.js:185-190` — green toast *"… was successfully returned."*
    and `this.$router.push('/returns')`.

### 1.2 Non-restock branch

`returns_helper.py:425-442` — identical `returns` UPDATE + `return_item` INSERTs, the Komatik
notification, the emails, and a 200 success. **No WMS call, no printing, no stock movement.**
The operator's screen is byte-for-byte identical to the restock success case.

---

## 2. What "restock" is

### 2.1 The control

`qa-ui components/returns/dispositionSelection.vue` — a Vuetify `v-select` labelled
`<v-card-subtitle class="pa-0">Return Inventory Process</v-card-subtitle>`, bound
`item-text="disposition_description"`, `item-value="disposition_id"`, options from
`this.$store.state.returnsCall.dispositions` (i.e. `GET /system/returns/dispositions`).

### 2.2 The lookup table and all values

Source: `returns_helper.py:58-68` selects `return_mgmt_lut.return_mgmt_lut_id` / `.value`
against the OMS tenant MySQL schema (table declared at `models.py:694-704`, `'return_mgmt_lut'`).

Two independent instruments give the same four rows:

| id | value | advises WMS? |
|---|---|---|
| 1 | Manually Manage | no |
| 2 | **Restock Inventory** | **yes** |
| 3 | Forward to Address | no |
| 4 | Destroy Product | no |

- **Instrument 1** — qa-api's own API doc, `readme/SYSTEM_INFO.md:222-227`:
  `{ "disposition_id": 2, "rank": 2, "disposition": "Restock Inventory" }`.
  *Blind spot:* a hand-written sample response, not a schema dump; could be stale.
- **Instrument 2** — the v2 OMS tenant seed,
  `v2/oms-laravel-api/database/schema/tenant-seed-data.sql:4939`:
  `INSERT INTO \`return_mgmt_lut\` (...) VALUES (2,'Restock Inventory',2,1,1,1);` — and the column
  it sets to `1` is `advises_wms`, added by
  `database/migrations/tenant/2026_07_24_100000_add_advises_wms_to_return_mgmt_lut.php`, whose own
  docblock says it exists *"instead of keying it off the hard-coded id 2"* and warns that keying
  off the id *"would wrongly flag an unrelated disposition on any tenant whose auto-increment no
  longer lines up with the restock row"*.
  *Blind spot:* that is the **v2** OMS baseline. It is strong evidence for the intended semantics,
  and it is direct evidence that someone has already found id-2 hard-coding to be a real hazard,
  but it is **not** proof of what row id 2 holds in ShipItEZ's live v1 tenant schema.

**Neither instrument reads the live ShipItEZ DB.** `return_mgmt_lut` lives in the OMS tenant MySQL
schema, which I have no access to from this session (no MySQL MCP is registered). See §5 and §6
for the queries that would settle it.

### 2.3 Verdict on "restock == 2 == the only WMS branch"

- **"Restock Inventory" is disposition 2** — confirmed by the two instruments above, with the live-DB
  caveat.
- **2 is the only value that reaches the WMS** — confirmed, by grep over `origin/develop` of both
  repos for `disposition`: the only comparison anywhere is `returns_helper.py:380`
  `if disposition_id == 2 and receive_now in true_values:`, and the only producer of `receive_now`
  is `pages/manageReturn/_id.vue:133` `if (dataObject.disposition_id === 2)`. The id is hard-coded on
  both sides, in two repos, with no lookup of `advises_wms` or of the value string.
  *Blind spot of the method:* a literal-`2` grep would miss a computed or config-supplied
  disposition id; I also grepped `disposition` unqualified across both repos' `flask_app/` and
  `pages|components|store|plugins` and found no other branch, so I regard this as settled for
  these two repos. It says nothing about the OMS (`v1/oms` is not present in this checkout).

### 2.4 ⚠ Defect A — the pre-selected disposition is never emitted

`dispositionSelection.vue:22-31`:

```js
mounted() {
  let return_preference_str = this.$store.state.returnsCall.manageReturn.return_preference
  let preferred_disposition = dispositions.find((elem) => elem.disposition_description === return_preference_str)
  if (preferred_disposition) {
    this.chosenDisposition = preferred_disposition.disposition_id
  }
},
```

The parent only ever learns the value through `@change="changedDisposition"` → `$emit('updateDisposition', ...)`.
The parent's own default is `pages/manageReturn/_id.vue:95` — `disposition: 1`.

A programmatic write to a Vuetify 2 `v-select`'s bound value **does not emit `change`**. Verified
against the installed Vuetify **2.7.2** source (qa-ui's `package-lock.json:15785` pins the same
`2.7.2`; the tree read is the sibling copy at `v2/wms2-web-ui/node_modules/vuetify`, same version):

- `lib/components/VSelect/VSelect.js:810-815` — `setValue(value) { if (!this.valueComparator(...)) { this.internalValue = value; this.$emit('change', value); } }`,
  and `setValue` is reached only from user-interaction paths (`selectItem`, clear, keydown).
- `lib/mixins/validatable/index.js:210-213` — the `value` prop watcher is `value(val) { this.lazyValue = val }`. No `change`.

**Consequence:** for any client whose `return_preference` resolves to a disposition in the list
(notably "Restock Inventory"), the operator opens the screen, sees *Restock Inventory* already
selected, changes nothing, submits — and the request carries `disposition_id: 1`, with no
`receive_now` and no `return_location`. `returns_helper.py:380` takes the **else** branch: the
`returns` row is updated, `return_item` rows are written, the Komatik notification and the emails
fire, HTTP 200, green toast. **No advice. No receipt. No UL. No stock.** This is the reported
symptom verbatim.

The operator only escapes this if they physically touch the dropdown — which is exactly what they
would not do when it already reads "Restock Inventory".

*Not yet confirmed:* that ShipItEZ's client row actually sets `ship_return_management` to the
restock disposition. `parcel_info_helper.py:288,372` shows where `return_preference` comes from:
`func.COALESCE(rtml_.c.value, 'No Preference').label('return_preference')` joined
`ON rtml_.return_mgmt_lut_id == cl_.ship_return_management`. If ShipItEZ leaves it unset the select
renders empty, the operator must click, `change` fires, and the bug does not bite — which would
explain why advices do arrive on some days (§3.4). **This is the single biggest open question.**

---

## 3. The UL-label claim

### 3.1 The QA station prints nothing on the return path

Method: `git grep -nE "print|label|zpl|ZPL|printer" origin/develop -- flask_app/view_helpers/returns_helper.py flask_app/common_util/wms_api.py`.
Every hit in those two files is a SQLAlchemy `.label()` alias (e.g. `returns_helper.py:59`
`rtml_.c.return_mgmt_lut_id.label('disposition_id')`). **Zero printing calls.**

Method 2: `git grep -n "print_to_printer\|send_print_picksheet_request\|manifest_location_label_zpl\|qa_hold_label_zpl" origin/develop -- flask_app`.
All call sites are in `flask_app/view_helpers/parcel_info_helper.py` (lines 1044, 1066, 1135, 1151)
— the **QA-pass / reprint** path, not returns. The two ZPL templates qa-api owns are
`config/templates/qa_hold_label_zpl.py` (`^FO50,325^A0N,150,130^FVHOLD^FS`) and
`config/templates/manifest_location_label_zpl.py`. Neither is a unit-load label.

*Blind spot of the method:* a token grep would miss printing reached through a dynamically-named
attribute or an HTTP call to a print service under a different name. I also read
`process_managed_returned_parcel` end-to-end (`returns_helper.py:345-449`) and its only outbound
calls are `advise_wms_of_managed_return`, `trigger_komatik_managed_notification_resilient` and
`process_managed_email_notifications`.

### 3.2 The WMS owns the UL label

`v1/wms-api .../controller/rest/AdviceRestController.java:272-319`, inside `create`, for
`adviceEntity.getType() == AdviceType.RETURN`:

```java
Optional<Printer> printerOptional = printerRepository.findByTypeAndProcessdefaultTrue(PrinterType.RETURN);
if (printerOptional.isPresent()) {
    Printer defaultReturnPrinter = printerOptional.get();
    receivingService.receiveGoods(pos.getId(), null, false, pos.getNotifiedamount().intValue(),
                                  pos.getNotifiedamount().intValue(), 1, boxtypeId, defaultReturnPrinter);
}
```

and `ReceivingService.receiveGoods` (`.../service/ReceivingService.java:308`) is what creates the
unit load and emits the label: `:529` `outputStream.write(createCaseLabel(unitload, stockUnit, advice, goodsreceipt, warehouseName));`
and `:561-568`

```java
// print label moved here
if (Boolean.parseBoolean(losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY))) {
    try { printService.cupsPrint(printer.getAddress(), outputStream.toByteArray()); }
    catch (Exception e) { throw new BusinessException("Cannot connect to the printer"); }
}
```

(`SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY = "PRINT_CASE_LABEL"`, `WmsConstants.java:974`.)

**Answer: the WMS owns the UL label on the return path, end to end.** The QA station's only role is
the `PUT rest/advice/create` call. Any fix that makes a label appear must either change what qa-api
sends (quantities, disposition gating) or change the WMS receiving/printing side — qa-api cannot
print a UL itself, and has no code to do so.

### 3.3 Concrete failure modes that produce "no UL and the bottles disappear"

Ordered by how silently they fail. **1, 2 and 3 all return HTTP 200/204 and show the operator a
green success toast.**

1. **Disposition never reached 2 (Defect A, §2.4).** No HTTP call at all. `returns` and
   `return_item` rows are written, emails go out, 200 + green toast. Forensically invisible in the
   WMS and invisible in `service_log` (§5).
2. **Everything was marked damaged, or damaged+missing consumed the whole parcel (Defect B).**
   `advise_wms_of_managed_return:486-487` — `total_returned_items = sum(qty_returned)`; since
   `manageReturnTable.vue:200` decrements `qty_returned` by the damaged amount, a fully-damaged
   parcel gives `0`, the `if` fails, and the helper logs *"No returned items, skipping call to
   create advice in WMS."* Success returned. **This is literally SBDEV-1512's scope.**
3. **Partially damaged.** `wms_api.py:198-202` — `amount_of_bottles = returned_items[item.item_id]['qty_undamaged']`,
   and `if not amount_of_bottles or amount_of_bottles == 0: continue`. Only the undamaged portion
   becomes advice positions; the damaged bottles are written to `return_item.quantity_damaged` in
   the OMS and **never reach the WMS in any form**. The UL that prints covers fewer bottles than
   the operator physically holds — which reads as "bottles disappear".
4. **No default RETURN printer in that warehouse's WMS (Defect D).**
   `AdviceRestController.java:306` returns an empty `Optional` → `receiveGoods` is *never called* →
   no goods receipt, no unit load, no label. Execution then falls straight through to `:317-318`
   `advicepositionRepository.updateAdvicepositionToStateByAdviceId(AdviceState.FINISHED, ...)` /
   `adviceRepository.updateAdviceToStateById(AdviceState.FINISHED, ...)` and `:337` returns
   **HTTP 204 `{"status":"success"}`**. The advice is now `FINISHED`, so it can never be received
   through the normal inbound screens either. Stock vanishes, the operator is told it worked.
5. **`PRINT_CASE_LABEL` sysprop false.** `ReceivingService.java:562` — stock *is* created and the
   unit load exists, but nothing is sent to CUPS. "No UL printed", bottles present but un-labelled.
6. **Printer unreachable.** `ReceivingService.java:320` `if(!printService.isPrintAvailable(printer.getAddress())) throw new BusinessException(...)`
   → caught at `AdviceRestController.java:312` → `WebserviceBusinessExceptionClientSide` → HTTP 400
   with an error map → qa-api raises `WmsException` → rollback. **This one is a genuine failure**,
   but see Defect C (§4): the operator still sees nothing.
7. **Client not enabled for receiving.** `AdviceRestController.java:148-151` —
   `if (!client.getEnablereceiving()) throw ... NOT_ENABLLED_FOR_RECEIVING` → 400 → rollback.
8. **Duplicate reference id.** `AdviceRestController.java:136-140` — `findByExternalid(referenceId)`;
   the reference id is `RETURN{parcel_id}` (`wms_api.py:178`), constant per parcel. Any retry of a
   previously-half-succeeded return gets `ENTITY_ALREADY_EXITS` → 400 → **permanently unmanageable**.
9. **Partial WMS commit + full qa-api rollback.** `AdviceRestController.create` carries **no
   `@Transactional`** (verified: `git grep -n "Transactional" origin/develop -- .../AdviceRestController.java`
   returns nothing). Each `adviceRepository.save` / `advicepositionRepository.save` /
   `receiveGoods` commits on its own. If position 3 of 5 throws, positions 1-2 are already received
   and the advice row exists — while qa-api reverses its whole return. The WMS and the OMS now
   disagree, and mode 8 blocks the retry.
10. **`ConfigurationError` — no WMS URL for the facility.** `wms_api.py:125-126`. This one *is*
    surfaced correctly (`parcel_info.py:235` catches `ConfigurationError` → `create_error_response`,
    which produces the standard `messages` **list** the UI can render).

### 3.4 Live DB check against `wh01_shipitez`

Queried via MCP `wms1-shipitez1`:

- `SELECT id,name,type,processdefault,address FROM printer` → **a default RETURN printer exists**:
  `id 2813142, name 'OPS 1', type 'RETURN', processdefault true, address http://oms.siteboss.net:631/printers/ShipItEZ-Coverdale-Ops1ZT411`
  (three more RETURN printers with `processdefault=false`). → **failure mode 4 is refuted for wh01.**
- `SELECT syskey,sysvalue FROM los_sysprop WHERE syskey IN (...)` →
  `PRINT_CASE_LABEL = 'true'`, `DEFAULT_BOX_TYPE = 'COLLTRL'`, `INBOUND_UPDATE_STOCK_IMMEDIATELY = 'true'`.
  → **failure mode 5 is refuted for wh01.**
- `SELECT type,state,count(*) FROM advice GROUP BY 1,2` → `RETURN / FINISHED: 1037`, first
  2022-09-22, last **2026-09-08**. Returns do flow.
- RETURN advices 2026-05-01 → 2026-07-01: **46 rows, every one `FINISHED`, every one with ≥1
  position and `notifiedamount > 0`**. Four of them landed on the complaint date itself
  (2026-05-29: `RETURN108600`, `RETURN121447`, `RETURN121443`, `RETURN121336`).
- Monthly RETURN advice counts from 2025-09: 17, 5, 40, 49, 53, 17, 19, **81 (Apr)**, **30 (May)**,
  16, 6, 4, 5. A steep decline after April — consistent with, but not proof of, a
  regression in what reaches the WMS.

**What this does and does not show.** It shows the wh01 auto-receive path is correctly configured
*today* and that advices were still arriving on 2026-05-29. It does **not** show what fraction of
managed returns produced an advice, because a return that never called the WMS (modes 1, 2) leaves
**no row in any of these tables**. That ratio can only be computed by joining the OMS `returns` /
`return_item` rows against these advice rows — the OMS MySQL is not reachable from this session.

Per session memory, ShipItEZ runs two warehouses (**NY = wh02, LA = wh01** — note the inversion).
The only ShipItEZ MCP registered here is `wms1-shipitez1` = `wh01_shipitez`. **Everything in §3.4
is about one of the two warehouses.** Failure modes 4 and 5 remain live hypotheses for wh02.

---

## 4. The error / rollback path

### 4.1 What qa-api does

`returns_helper.py:404-421`:

```python
except WmsException as exc:
    with engine.connect() as conn:
        conn.execute(update(rt_).where(rt_.c.parcel_id == parcel_id)
                     .values(comment=pre_update_rt.comment, disposition=pre_update_rt.disposition,
                             managed=pre_update_rt.managed, manage_date=pre_update_rt.manage_date,
                             managed_by=pre_update_rt.managed_by))
        returned_item_ids = [item['item_id'] for item in returned_items]
        if returned_item_ids:
            conn.execute(delete(rti_).where(rti_.c.order_item_parcel_id.in_(returned_item_ids)))
        conn.commit()
    return {'status': 'failure', 'messages': str(exc)}
```

- It is a **compensating write**, not a transaction rollback — the original UPDATE/INSERTs were
  already committed at `:396`.
- The `DELETE` is keyed on `order_item_parcel_id` with **no parcel predicate**. That is safe only
  because `order_item_parcel_id` is `return_item`'s primary key (`models.py:686`) — worth stating
  explicitly, because the name reads like a foreign key.

### 4.2 Notifications on the failure path — **not reached**

`returns_helper.py:418` returns immediately from inside the `except`. Therefore:

- `trigger_komatik_managed_notification_resilient` (`:423`) — **not called**.
- `process_managed_email_notifications` (`:444`) — **not called**.

Method: read of the full `process_managed_returned_parcel` body, `:345-449`; the `except` block's
`return` precedes both call sites in the same function, and neither appears in a `finally`.
*Blind spot:* none within this function — but note the **non-restock** branch (`:442`) and the
success branch (`:423`) both do fire them, so a `disposition_id == 1` submission (Defect A) sends
the customer the full "your return has been processed" email while nothing was restocked.

### 4.3 ⚠ Defect C — the UI swallows the error and hangs

`parcel_info.py:231-234`:

```python
if result.get('status') == 'failure':
    response = result
    code = 400
```

so the 400 body is `{'status': 'failure', 'messages': '<code>: <description>'}` — a **string**,
because `WmsException.__str__` is `return f'{self.code}: {self.message}'` (`config/exceptions.py:62-63`)
and `code` is never empty (`wms_api.py:164` falls back to `str(response.status_code)`).

Every other error in this app returns `messages` as a **list of dicts** — that is what
`create_error_response` produces and what `store/util.js:6-15` documents:
`'messages': [{'type': ..., 'message': ..., 'parameter': ...}]`.

`qa-ui store/util.js:31-41`:

```js
if (!!(error.response && error.response.data && error.response.data.messages)) {
    error.response.data.messages.forEach((elem) => { ... })
}
```

A non-empty string is truthy, so the guard passes, and `String.prototype.forEach` does not exist →
**`TypeError: error.response.data.messages.forEach is not a function`**, thrown from inside
`processApiErrors`, which is itself called from the `catch` in `returnsCall.js:191-193`. The
exception escapes the `catch`, so:

- **no toast of any kind is shown** — neither the WMS message nor the generic fallback at `util.js:44`;
- the action's promise **rejects**, so `pages/manageReturn/_id.vue:140`
  `.then((res) => {this.$store.commit('qaParcelScan/hideQaLoadingWheelPop')})` never runs;
- `components/qaParcel/qaLoadingWheelPop.vue` is `<v-dialog persistent v-model="showPop" ...>` —
  **persistent**, so it cannot be dismissed by clicking outside. The operator is left staring at
  *"Submitting return for &lt;tracking&gt;…"* forever and must reload the page.

**Can a failure look like a success?** Not as a green toast — but it looks like a *hang*, and after
a reload the parcel is back to unmanaged (§4.1) with no explanation. Combined with modes 1 and 2
of §3.3, which really do show the green success toast, the operator's mental model "I selected
restock and it said it worked" is fully explained.

*Verification note:* this is a code-reading result. I did not execute the UI. The three facts it
rests on are each independently checkable: `WmsException.__str__` returns a non-empty string,
`parcel_info.py` assigns that dict straight to the response body, and `util.js` calls `.forEach`
on it. `tests/unit/axiosAuthRecovery.test.cjs` is the repo's only JS test and does not cover this.

---

## 5. The service log — and the forensic query

### 5.1 Real table and columns

`flask_app/models.py:762-774`:

```python
sl_ = service_log_table = Table(
    'service_log',
    metadata_obj,
    Column('service_log_id', BIGINT, primary_key=True, autoincrement=True),
    Column('service_url', String(255), nullable=True),
    Column('raw_json_string', LONGTEXT, nullable=True),
    Column('ip_address', String(100), nullable=True),
    Column('response', Text, nullable=True),
    Column('response_date', DateTime, nullable=True),
    Column('api_user', String(32), nullable=True),
    ...)
```

Writer: `wms_api.py:88-104` `insert_wms_response_in_service_log` — writes `service_url`,
`raw_json_string = json.dumps(request)`, `ip_address = r.remote_addr`, `response`,
`response_date = NOW()`. **`api_user` is never populated by this writer**, and there is no parcel,
advice or return column — the only way to tie a row to a parcel is the `RETURN{parcel_id}` string
inside `raw_json_string`.

Database: the OMS tenant MySQL schema named by the `Preferred-Schema` request header
(`flask_app/auth/oauth.py:74` — `flask.g.schema = request.headers.get('Preferred-Schema')`),
connected as the OMS user (`config/db_funcs.py:_make_mysql_sqlalchemy_engine`). The unit-test
fixture at `tests/test_unit/test_config/test_flask_config.py:27` names a schema `om1_shipitez`,
which is the strongest in-repo hint at ShipItEZ's schema name — **confirm before running**.

### 5.2 ⚠ The log is blind to the success case

`wms_api.py:144-146`:

```python
if response.status_code == 204:
    return {'status': 'success'}
```

— it returns **before** any `insert_wms_response_in_service_log` call. So on the advice path:

| Outcome | Row written? |
|---|---|
| HTTP 204 (the normal WMS success) | **NO** |
| non-204 with parseable JSON | yes (`:160`), before the status check |
| non-204, non-JSON | yes (`:154`), with `{'raw_body': ...}` |

This is inconsistent with the QA-complete path, which *does* log its 204
(`check_wms_qa_response`, `wms_api.py:54-58`).

**Forensic consequence, stated plainly: an absent `service_log` row for a parcel means one of
"the advice succeeded", "the advice was never attempted (Defect A or B)" or "`CONTACT_EXTERNAL`
is false" — the table cannot distinguish them.** The query below therefore enumerates *failures*;
the population of successes must be derived by anti-joining `returns` against the WMS `advice` table.

### 5.3 The queries (write-up only — **not run**)

Run against the OMS tenant MySQL schema (`USE om1_shipitez;` or whatever
`Preferred-Schema` the QA station sends).

```sql
-- Q1. Recent rest/advice/create calls WITH their WMS response.
--     Only FAILED calls appear here (see 5.2). ORDER matters: response_date is the only clock.
SELECT sl.service_log_id,
       sl.response_date,
       sl.service_url,
       sl.ip_address,
       SUBSTRING_INDEX(SUBSTRING_INDEX(sl.raw_json_string, '"reference_id":"', -1), '"', 1)
           AS advice_reference_id,   -- 'RETURN<parcel_id>'
       sl.raw_json_string,
       sl.response
FROM   service_log sl
WHERE  sl.service_url LIKE '%rest/advice/create%'
  AND  sl.response_date >= DATE_SUB(NOW(), INTERVAL 180 DAY)
ORDER  BY sl.response_date DESC;

-- Q2. Everything ever logged for one parcel (any endpoint), for a single-parcel post-mortem.
--     Replace 118954 with the parcel_id. 'RETURN118954' is the reference/shipment/delivery-note id.
SELECT sl.service_log_id, sl.response_date, sl.service_url, sl.raw_json_string, sl.response
FROM   service_log sl
WHERE  sl.raw_json_string LIKE CONCAT('%RETURN', 118954, '%')
    OR sl.raw_json_string LIKE CONCAT('%"parcel_id":', 118954, '%')
ORDER  BY sl.response_date;

-- Q3. THE decisive query for the UL claim: managed restock returns that produced no advice
--     attempt and no failure row. Every row returned is a return the operator believes was
--     restocked, for which the QA station either never called the WMS or called it successfully.
--     Cross-check the survivors against the WMS advice table (Q4) to split those two cases.
SELECT r.parcel_id,
       r.manage_date,
       r.disposition,
       rml.value                              AS disposition_value,
       r.managed_by,
       SUM(ri.quantity_undamaged)             AS qty_undamaged,
       SUM(ri.quantity_damaged)               AS qty_damaged,
       SUM(ri.quantity_missing)               AS qty_missing,
       CONCAT('RETURN', r.parcel_id)          AS expected_advice_reference_id
FROM   returns r
JOIN   return_mgmt_lut rml ON rml.return_mgmt_lut_id = r.disposition
LEFT   JOIN order_item_parcels oip ON oip.parcel_id = r.parcel_id
LEFT   JOIN return_item ri         ON ri.order_item_parcel_id = oip.order_item_parcel_id
WHERE  r.managed = 1
  AND  r.manage_date >= '2026-05-01'
GROUP  BY r.parcel_id, r.manage_date, r.disposition, rml.value, r.managed_by
ORDER  BY r.manage_date DESC;

-- Q4. Disposition mix — this settles Defect A. If managed returns are overwhelmingly
--     disposition 1 while the client's stated preference is Restock Inventory, the dropdown
--     is eating the selection.
SELECT rml.return_mgmt_lut_id, rml.value, rml.is_active, COUNT(r.parcel_id) AS managed_returns
FROM   return_mgmt_lut rml
LEFT   JOIN returns r ON r.disposition = rml.return_mgmt_lut_id
                     AND r.managed = 1
                     AND r.manage_date >= '2026-05-01'
GROUP  BY rml.return_mgmt_lut_id, rml.value, rml.is_active
ORDER  BY rml.return_mgmt_lut_id;

-- Q5. The client's configured return preference — what the dropdown pre-selects at mount.
--     (join per parcel_info_helper.py:372)
SELECT c.client_id, c.client_code, c.ship_return_management,
       COALESCE(rml.value, 'No Preference') AS return_preference
FROM   client c
LEFT   JOIN return_mgmt_lut rml ON rml.return_mgmt_lut_id = c.ship_return_management;

-- Q6. Which WMS each facility talks to (see §6).
SELECT w.wms_url_lut_id, w.facility_code, w.wms_url FROM wms_url_lut w ORDER BY w.facility_code;
```

On the WMS side (Postgres, per warehouse) the matching half of Q3 is:

```sql
-- Q7. Advices that DID land, to anti-join against Q3's parcel_ids.
SELECT a.externalid, a.number, a.state, a.created,
       count(p.id) AS positions, coalesce(sum(p.notifiedamount),0) AS notified_bottles
FROM   advice a LEFT JOIN adviceposition p ON p.advice_id = a.id
WHERE  a.type = 'RETURN' AND a.created >= '2026-05-01'
GROUP  BY a.externalid, a.number, a.state, a.created
ORDER  BY a.created;
```

*Caveats on Q1/Q2:* `SUBSTRING_INDEX` on `raw_json_string` assumes the exact key spelling
`"reference_id":"` with no whitespace — true for `json.dumps` of the dict built at `wms_api.py:180-189`,
but it would break if the serializer ever changed. `service_log` is also written by the Komatik
notification path (`returns_helper.py:275,831,834`) with a `None` response, so filtering on
`service_url` is mandatory.

---

## 6. Deployment reality

### 6.1 How qa-api finds the WMS

`common_util/wms_api.py:107-114`:

```python
def get_wms_base_url(return_facility: str) -> Optional[str]:
    """ Returns the base WMS URL of the given facility or None if no URL is registered."""
    wms_url_query = (select(wul_.c.wms_url.label('wms_base_url'))
                     .where(wul_.c.facility_code == return_facility))
```

The table is **`wms_url_lut`** (`models.py:814-822`):
`wms_url_lut_id`, `facility_code` (FK → `facility.facility_code`), `wms_url VARCHAR(255) NOT NULL`.
The base URL is concatenated with `rest/advice/create` (`wms_api.py:128`), so the stored value must
carry its trailing slash — there is no normalisation.

`return_facility` is the `return_location` posted by the UI, which is
`this.parcelInfo.fulfillment_facility_code` (`pages/manageReturn/_id.vue:135`) — i.e. **the
fulfilling facility, not the facility the parcel physically came back to**. Worth flagging for a
two-warehouse client: a parcel fulfilled in LA but returned to NY would be advised to the LA WMS.

`send_wms_qa_complete_request` uses a *different* source — `parcel_info.wms_base_url` carried on the
parcel row (`wms_api.py:20`), not this lookup. The two paths can disagree.

### 6.2 Which environments / clients

- **Runtime shape**: `kubernetes-architecture.txt` — *"The QA service is designed to run in
  Kubernetes, and be scaleable horizontally… configmap/qa contains necessary python config files,
  including config.ini… service/qa - NodePort service. We run on a manually-defined TCP port,
  unique to each environment. We will start at 32000."* and *"The QA service requires a connection
  to the OMS database, with the same rights as the OMS user."*
- **Image build**: `.gitlab-ci.yml` builds only on `$CI_COMMIT_TAG`. `Dockerfile` — `FROM python:3.8`,
  `EXPOSE 8086`, `ENTRYPOINT ["/start.sh"]`; `start.sh` sets `APP_CONFIG="/config.ini"` and runs gunicorn.
  The image bakes `sample/config.ini`, which the k8s configmap overlays.
- **Multi-tenancy**: one deployment serves many OMS schemas. `flask_config.py` has an
  `OMS_CREDENTIALS` section keyed by schema; `db_funcs.connect_to_db(username, schema)` builds and
  caches **one SQLAlchemy engine per schema** (`_engine_registry`), with the schema taken from the
  `Preferred-Schema` header (`auth/oauth.py:74`). `sample/config.ini` shows the shape
  (`oms_dev_schema1 = username password`); `tests/test_unit/test_config/test_flask_config.py:27`
  uses `om1_shipitez = username password`, with `KOMPHP_BASE_URL=https://oms.shipitez.sbo.li/`
  and `PICKSHEET_URL=https://picksheet.shipitez.sbo.li/`.
- **Clients evidenced in-repo**: **ShipItEZ** (the test config above) and **WineCo**
  (`qa-ui config/.env.development` → `API_BASE_URL=https://qa-api.wineco.dev.sbo.li`).
  *Method:* grep of committed config/test files. *Blind spot:* the real deployment list lives in
  k8s configmaps, which are not in either repo — **this is not a complete client list.**

### 6.3 Does ShipItEZ point at a v1 or a v2 WMS?

**Cannot be determined from the repos.** The answer is one row of `wms_url_lut` in ShipItEZ's OMS
MySQL schema (Q6 above), and no MySQL MCP is registered in this session.

What I *can* say, and how:

- The path `rest/advice/create` exists in **both** WMS versions, so the URL shape does not
  discriminate: `v1/wms-api .../controller/rest/AdviceRestController.java:60` `@RequestMapping("/rest/advice")`
  + `:105` `@PutMapping(value = "/create", ...)`, and `v2/wms2-api .../controller/rest/AdviceRestController.java:55`
  the same. Only the **hostname** in `wms_url_lut.wms_url` distinguishes them.
- A **v1** WMS is definitely live for ShipItEZ's wh01: MCP `wms1-shipitez1` resolves to
  `wh01_shipitez` and holds 1037 `RETURN` advices with the most recent created **2026-09-08** —
  i.e. this v1 database is still receiving returns today. That makes a v1 target overwhelmingly
  likely for at least wh01.
- Session memory records a ShipItEZ two-warehouse v2 migration in progress (NY = wh02, LA = wh01).
  I have **no MCP for wh02**, so I cannot say whether the NY facility's `wms_url_lut` row was
  repointed at wms2. **If it was, the whole §3.4 refutation of failure modes 4 and 5 does not
  apply to NY** — and v2's advice path is materially different (it has a
  `ReturnAdviceAutoReceiveService`, added under SBDEV-2778, whose own comment at
  `AdviceRestController.java:310` says it keeps the *"advice out of markFinished, which would
  otherwise flip it FINISHED having received"* — i.e. v2 has already fixed v1's silent-FINISH bug).

**What is needed:** `SELECT facility_code, wms_url FROM wms_url_lut;` on ShipItEZ's OMS schema, plus
the `facility_code` the QA station actually sends for the parcels in question.

---

## 7. Incidental finding (out of scope, flagging once)

`qa-ui .github/workflows/docker-image-develop.yml` contains a **plaintext container-registry
credential** (`registry: hub.impactathleticsny.com`, `username: impact`, password inline), repeated
twice in the same job. `docker-image.yml` should be checked for the same. This is the same class of
exposure as SBDEV-3194 but a different registry and account.

---

## 8. Open questions, ranked

1. **Is ShipItEZ's `client.ship_return_management` set to the restock disposition?** If yes,
   Defect A (§2.4) is the primary cause and it is a ~3-line UI fix. Query Q5.
2. **Which WMS does each ShipItEZ facility point at?** Query Q6. Determines whether the v1
   analysis in §3 even applies to the NY warehouse.
3. **What is the disposition mix of managed returns since April 2026?** Query Q4 — directly
   measures how often the WMS branch is taken, and would explain the post-April decline in RETURN
   advices seen in §3.4.
4. Does `wh02_shipitez` have a default `RETURN` printer and `PRINT_CASE_LABEL = true`?
   (Failure modes 4 and 5, unverified for NY.)
