# SBDEV-1512 — WMS v2 damaged-receipt capability survey

**Ref derived from:** `origin/develop` @ `9e294d4bf7a1a1ce41eca69a6987a5fffa0f2bcc`
("Merge pull request #358 from SiteBossInc/bugfix/SBDEV-2778-soft-fail-return-auto-receive").
The local checkout (`34b897c8`) is **56 commits behind**; nothing below was read from the working tree.
Every code claim is `git show origin/develop:<path>` / `git grep … origin/develop`.

**DB verification:** `c1wh-shipitez-uat` and `nywh-shipitez-uat` (live MCP, 2026-09-15).

**Bottom line up front:** there is **no** path in v2 that receives stock into a damaged state.
Damaged-ness in v2 is carried by `stockunit.entity_lock = 103 (QUALITY_FAULT)`, and the receiving
pipeline never writes that column to anything but `0`. The QA station's `qty_damaged` has nowhere
to land today.

---

## 1. The RETURN advice intake contract

### Endpoint

`PUT /rest/advice/create`, `AdviceRestController` (`src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java`):

```java
@RequestMapping("/rest/advice")
…
@PutMapping(value = "/create", consumes = "application/json", produces = "application/json")
public ResponseEntity<Object> create(@RequestBody List<AdviceDto> adviceList, @AuthenticationPrincipal Principal principal)
```

Body is a **JSON array** of `AdviceDto`. `/rest/**` is `permitAll()` — the class javadoc states this
explicitly ("`/rest/advice/create` is `permitAll()` (SecurityConfiguration:151 — the `/rest/**` entry
in the permitAll list) with the tenant chosen from an unauthenticated header (TenantFilter:40-41)").

**Instrument for the endpoint inventory:** `grep -nE "@(Get|Post|Put|Patch|Delete|Request)Mapping"`
over the file, plus `git grep -ln "AdviceDto\|AdviceUploadDto" -- src/main/java/net/aim_ai/wms/controller`.
That returns four mappings on this controller — `/create`, `/createTransfer`, `/createHubAndSpoke`,
`/reopen` — and exactly two controllers touching an advice DTO: this one and `FileImportController`
(spreadsheet upload, `AdviceUploadDto`, a different shape). **Blind spot:** the grep keys on the
annotation token, so a mapping contributed by a superclass or by a `MappedInterceptor`-style
registration would not appear; `AbstractRestController` was read in full and declares no mapping.

### `AdviceDto` — the envelope (`src/main/java/net/aim_ai/wms/json/AdviceDto.java`)

**Instrument:** full file read of `AdviceDto` + its superclass `AbstractWebServiceDto`.
**Blind spot:** Jackson can also bind via constructor/`@JsonAnySetter`; neither is present here, and
there is no `@JsonIgnoreProperties(ignoreUnknown=false)`, so **unknown JSON keys are silently
dropped** — relevant because a naive `"qty_damaged"` added to the wire would be accepted and ignored.

| JSON key | Java field | Type | Validated in `create()`? |
|---|---|---|---|
| `reference_id` | `referenceId` | String | **Required** — `FIELD_NOT_SET` if empty. Also the `advice.externalid` UNIQUE key (`uk_4d13b6sg589c6y88tkm98xl89`). For RETURN also length ≤64 + no control chars (`isUnsafeReference`) |
| `client_id` | `clientId` | String | **Required**; must resolve via `clientRepository.findByClNr` |
| `type` | `type` | String | **Required**; must be `REGULAR` or `RETURN` (`TRANSFER` is accepted by the `enablereceiving` pre-check but then **rejected** by the type switch — `throw … FIELD_MALFORMED_FORMAT`) |
| `facility_code` | `facilityCode` | String | **Required** — `validateWarehouse()` compares it against sysprop `MULTIWAREHOUSE_IDENTIFIER`; mismatch ⇒ `WRONG_FACILITY_CODE`. ⚠ declared **twice**: on `AdviceDto` *and* on `AbstractWebServiceDto`, with the subclass getter/setter shadowing |
| `printer_id` | `printerId` | Long | Optional. **RETURN only**: must exist AND be `PrinterType.RETURN`, else `FIELD_MALFORMED_FORMAT` (`resolvePrinter`). Ignored on REGULAR |
| `day_of_delivery` | `dayOfDelivery` | String | Optional; ISO `LocalDate.parse`, else `FIELD_MALFORMED_FORMAT` |
| `day_of_delivery_until` | `dayOfDeliveryUntil` | String | same |
| `delivery_note_number` | `deliveryNoteNumber` | String | Optional, stored verbatim |
| `comment` | `comment` | String | Optional, stored verbatim |
| `supplier` | `supplier` | String | Optional, stored verbatim |
| `purchase_order_number` | `purchaseOrderNumber` | String | Optional, stored verbatim |
| `shipment_id` | `shipmentId` | String | **Parsed and never used** by `create()` |
| `transfer_id` | `transferId` | String | **Not used** by `create()` (only `createTransfer` reads it) |
| `positions` | `positions` | `List<AdvicePositionDto>` | Optional-by-contract (the `TODO include when AIM is ready` block at `:131-134` is commented out). For RETURN a **null** list ⇒ `NO_POSITION`; an **empty** list is deliberately accepted and auto-receive is skipped |

### `AdvicePositionDto` — the position (`src/main/java/net/aim_ai/wms/json/AdvicePositionDto.java`)

**Six fields, total.** There is no damaged/condition/disposition field of any kind.

| JSON key | Java field | Type | Validated in `create()` | Extra validation on the RETURN path (`resolveRefs`) |
|---|---|---|---|---|
| `reference_id` | `referenceId` | String | Required (`FIELD_NOT_SET`) | + `isUnsafeReference` (≤64 chars, no `<0x20`/`0x7F`) |
| `client_id` | `clientId` | String | Required; must resolve | same |
| `sku` | `sku` | String | Required; must resolve to `Itemdata` for that client; unique per client within the request | same, plus a per-`(client,sku)` dedup key |
| `box_id` | `boxId` | String | *Optional in the code path* — see the NPE note below | **Required** (`resolveBoxtypeId` throws `FIELD_NOT_SET`/`box_id` when empty) and must resolve via `findByExternalid` |
| `amount_of_boxes` | `amountOfBoxes` | Integer | **Not null-checked** — `new BigDecimal(advicePosition.getAmountOfBoxes())` unboxes | **Required** (explicit null check, added precisely to pre-empt that NPE) |
| `amount_of_bottles` | `amountOfBottles` | Integer | Required, and `>= 0` | stricter: `>= 1` and `<= 100_000` (`MAX_UNITS_PER_POSITION`) |

**Pre-existing defect worth recording (not SBDEV-1512 scope).** In the save loop:

```java
Optional<Boxtype> optionalBoxtype = null;
if (StringUtils.isNotEmpty(advicePosition.getBoxId())) { … }
…
Boxtype boxtype = optionalBoxtype.get();
```

With `box_id` absent this is an NPE ⇒ HTTP 500, *after* `adviceRepository.save` has committed. On the
RETURN path `resolveRefs` pre-empts it; on **REGULAR** it is live.

### Batch-shape guards on the RETURN path (both introduced by SBDEV-2778)

- `MAX_RETURN_ADVICES_PER_REQUEST = 100`, counted over RETURN advices only.
- **An auto-receiving RETURN advice must arrive alone**: `returnAdvices > 0 && adviceList.size() > 1
  && isAutoReceiveEnabled()` ⇒ `FIELD_MALFORMED_FORMAT`. Any SBDEV-1512 wire change must keep the
  single-element-array shape the QA station already sends.

### Responses

- `204 No Content` `{}` — clean import (and every REGULAR import).
- `200 OK` `{"status":"success","warning":{code,reason,correlation_id,advice,sku,received,total,description}}`
  — auto-receive was `PARTIAL` or `SKIPPED`. Deliberately 200, because OMS short-circuits on 204.
- `400` `e.getErrorMap()`.

---

## 2. `ReturnAdviceAutoReceiveService`, end to end

`src/main/java/net/aim_ai/wms/service/ReturnAdviceAutoReceiveService.java` (891 lines, read in full).
Three phases, called from `create()`:

### Phase 0 — `validate(adviceDto)` — runs **before** anything is persisted

`self.resolveRefs(adviceDto)` (`@Transactional(value = "tenantTransactionManager", readOnly = true)`,
reached through the `@Lazy @Autowired self` proxy) then a CUPS probe **outside** that transaction.

Per advice: resolve printer (explicit `printer_id` must be type `RETURN`, else the
`processdefault` RETURN printer, else throw); reject null `positions`; cap positions at 500;
assert `MAXIMUM_RECEIVING_DURING_INBOUND` parses as an int; **warn-not-throw** if the
`oms_integration` user row is absent; resolve `UNIT_LOAD_TYPE_BOX`.

Per position: the validations in the table above, plus the memoised
`putawayDestinationResolver.requireUsablePlacement(itemdata, client, unitloadtypeId)` — the
pre-persist twin of the gate `ReceivingService` applies at receive time.

The ordering is load-bearing and documented as such: `create()` is **not** `@Transactional`, so a
throw after `adviceRepository.save` would burn `advice.externalid = RETURN{parcel_id}` and every OMS
retry would then die on the duplicate guard.

### Phase 1 — `bind(validated, savedAdvice, savedPositions)`

Pure in-memory positional zip. Aborts (`RETURN_AUTO_RECEIVE_ABORTED`) if
`lines.size() != savedPositions.size()` or if `line.positionExternalId()` diverges from
`saved.getExternalid()` at any index.

### Phase 2 — `execute(plan)` → `executeAsIntegrationUser` → `executeInternal`

Not `@Transactional` by design. Sets the `SecurityContext` principal to `"oms_integration"` (only
when that `mywms_user` row exists) so `goodsreceipt.operator_id` is attributable, then, **per
position in order**:

```java
receivingService.receiveGoods(line.advicePositionId(), null, false,
        line.amount(), line.amount(), 1, line.boxtypeId(), plan.printer());
```

Note `carrierUnitLoadId = null`, `storeOnCarrier = false`, `amountCases = 1`, and
`amountBottlesPerCase == amountBottles` — so **one unit load per position**, and `amountCases = 1`
structurally bypasses the `MAXIMUM_RECEIVING_DURING_INBOUND` volume check.

After the loop (and **only** if every position succeeded) `self.markFinished(adviceId)` flips
positions and advice to `FINISHED` in one tenant transaction.

### Where the stock physically lands

Inside `ReceivingService.receiveGoods` (`src/main/java/net/aim_ai/wms/service/ReceivingService.java`),
per case:

1. `Location storageLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_INBOUND_NAME)` — the
   `InboundWorkstation`. This is `inboundWorkStation`, used for `goodsreceipt.goodsinlocation_id`
   and stamped onto the stock record.
2. `unitloadService.createUnitload(inboundWorkStation, unitloadType.getId(), client.getId(), codeReceiving, spawnLocation, boxType.getId())`
   — a **new** unit load, `setEntityLock(0)`.
3. `stockunitBusinessService.createStockUnit(client, itemdata, new BigDecimal(amount), false, unitload, codeReceiving, …)`
   — a new `stockunit`. **No lock argument; `entity_lock` is left at its default `0`.**
4. `goodsreceiptpositionRepository.save(goodsreceiptPosition)`.
5. `unitloadBusinessService.transferUnitLoadToLocation(unitload, putaway.location(), false, codeReceiving, …)`
   — moves it to the resolved putaway destination (`carrier == null` on this path).
6. For `AdviceType.RETURN`: **unconditionally**
   `sharedService.getStockChangeDTO(itemdata, originalAmountBottles, 0, 0, 0, 0, "RETURN: "+externalid, CODE_RECEIVING_RETURN)`
   → `messageService.sendStockChangeMessage(list)`.
   In `SharedService:129` the signature is `(itemData, int total, int damaged, int missing, int onHold, int transfer, …)`,
   so the received quantity goes to `normal` and **`damaged` is hard-coded 0**.

**Live confirmation** (`c1wh-shipitez-uat`, goods-receipt positions on RETURN advices, last 120 days):

| location | `entity_lock` | rows | units |
|---|---|---|---|
| `PutAwayLane` | **0 (NOT_LOCKED)** | 11 | 33 |
| `Nirwana` | 2 | 96 | 0 (consumed) |
| `Shipped` | 405 | 1 | 12 |

and all 2,956 `RETURN` stock records carry `tostoragelocation = 'InboundWorkstation'`. Returned stock
arrives **unlocked and immediately pickable**. Nothing here can produce `entity_lock = 103`.

### `AutoReceiveOutcome`

Record `(Status, adviceNumber, failedSku, received, total, FailureReason, correlationId, description)`.

- **SUCCESS** — every position received; `markFinished` ran.
- **PARTIAL** — position *k* threw (`BusinessException | FacadeException | RuntimeException`).
  Returns immediately; `markFinished` is **not** reached, so the advice stays `OPEN` for dock
  recovery. `FailureReason` comes from `diagnose()`, which probes **observed state**, never the
  exception: `PRINTER_UNREACHABLE` → `ZPL_TEMPLATE_MISSING` → `CONFIG_MISSING` → `UNKNOWN`.
- **SKIPPED** — `plan.lines().isEmpty()`, reason `SKIPPED_NO_POSITIONS`. Defence in depth; the
  controller already gates on non-empty positions.

`isWarning()` is `status != SUCCESS`, and that is what turns the 204 into a 200-with-warning.

### The gate and its default

`WmsConstants:1410-1411`:

```java
public static final String SYSTEM_PROPERTY_RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED_KEY = "RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED";
public static final String SYSTEM_PROPERTY_RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED_DEFAULT_VALUE = "true";
```

```java
boolean enabled = !"false".equalsIgnoreCase(StringUtils.trimToEmpty(raw));
```

**Default ON** — absent row / null / blank ⇒ enabled. This is the *opposite* of the nine other
feature flags in the repo (`Boolean.parseBoolean`, default OFF), and the javadoc says so explicitly:
"Do not 'consistency-fix' this." Seeded by `db/migration/V2.2.09__seed_return_advice_auto_receive_sysprop.sql`.
Measured on `c1wh-shipitez-uat`: `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED = 'true'` (modified 2026-09-09).

### Does it print a label? — Yes, and this is where the client's complaint lands

`receiveGoods` accumulates `sharedService.createCaseLabel(unitload, stockUnit, advice, goodsreceipt, warehouseName)`
into an `outputStream` **inside** the per-case loop (so one label per unit load), then, at the very end:

```java
if (Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY))) {
    …
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
        @Override public void afterCommit() { printService.cupsPrint(printerAddress, labelData); }
```

So a label **is** printed on restock, but only when sysprop `PRINT_CASE_LABEL` is truthy, and the
check is `Boolean.parseBoolean` — **default OFF**: an absent/blank/mistyped row silently suppresses
every receiving label with no error and no metric. The base-dump seed at
`V2.2.00__base_v2_schema.sql:2600` describes it as *"Print UL Labels — On/Off selector to determine
whether or not UL labels are printed during receiving process."*

Measured on `c1wh-shipitez-uat`: `PRINT_CASE_LABEL = 'true'`, **`modified = 2026-09-09 20:11:58`** —
i.e. changed six days before this survey. Per
[[los-sysprop-modified-does-not-track-value-changes]] that timestamp dates the *row*, not the value,
so it does **not** prove the flag was previously false — but it is the first thing to ask the client
about, because it is the only switch on this path that produces exactly the reported symptom
(receipt succeeds, no label emitted, no error anywhere).

Also note the print is `afterCommit` and best-effort: a CUPS failure is logged
(`"Failed to print labels after successful receive"`) and swallowed.

---

## 3. `StockunitService.setLockDamaged`, in full

`src/main/java/net/aim_ai/wms/service/StockunitService.java:738`:

```java
public Stockunit setLockDamaged(Stockunit stockUnit, BigDecimal amount, String comment, boolean printLabel, Principal principal) throws BusinessException, FacadeException {
```

**It is NOT `@Transactional`.** (A `git grep` of the enclosing method plus a read of the 12 lines
above the signature confirms no annotation; the file's own comment block at `:169-177` says so —
"Only 2 of the 11 enclosing methods are annotated — and setLockDamaged … is not".) The atomicity
lives one level down, in the helper it calls.

### Sequence

1. `comment = AuditCommentUtil.clamp(comment)` (SBDEV-3085).
2. **Lock-state precondition** — a `switch` on `stockUnit.getEntityLock()`:
   `NOT_LOCKED` ⇒ proceed; `SHIPPED` / `GOING_TO_DELETE` ⇒ named `BusinessException`;
   **anything else (including an already-`QUALITY_FAULT` unit) ⇒ throw.**
   So the source stock unit must be `entity_lock = 0`.
3. `amount > 0` required; `amount` is **clamped down** to `stockUnit.getAmount()` if larger;
   `availableamount < amount` ⇒ `"Stock unit has too much reserved amount. Please cancel orders first!"`.
4. `Location location_damaged = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_DAMAGED)
   .orElseThrow(() -> new EntityNotFoundException(…))`.
5. `UnitloadType` = `UNIT_LOAD_TYPE_BOX`, **always** (fixes SBDEV-1953 / SBDEV-1746).
6. `String containerLabel = unitloadService.mintUnitloadLabel();` — minted **outside** any
   transaction, because the sequence write is `REQUIRES_NEW` and must not run inside a lock holder.
7. **The real work**, one cross-bean call:
   `unitloadService.moveStockToNewDamagedContainer(containerLabel, stockUnit, location_damaged, unitLoadType.getId(), amount, comment)`.
8. `sharedService.getStockChangeDTO(itemData, 0, damagedStock.getAmount().intValue(), 0, 0, 0, comment, WmsConstants.CODE_DAMAGED)`
   → `messageService.sendStockChangeMessage` — i.e. `normal = 0`, **`damaged = +N`**.
9. `triggerReplenishmentMaintenance(stockUnit.getItemdataId())`.
10. `printLabel(printLabel, unitLoad, damagedStock)` **last**, wrapped in a
    `catch (BusinessException | FacadeException)` that only warns — a printer outage must not
    report a committed damage move as failed, because `setLockDamaged` is **not idempotent**.

### The transactional core — `UnitloadService.moveStockToNewDamagedContainer`

`src/main/java/net/aim_ai/wms/service/UnitloadService.java:158`:

```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public DamagedTransfer moveStockToNewDamagedContainer(String containerLabel, Stockunit stockUnit,
        Location damagedLocation, Long unitLoadTypeId, BigDecimal amount, String comment)
```

1. `locationRepository.findByIdForUpdate(damagedLocation.getId())` — **must remain the first
   statement**; deadlock-ordering guard (D3).
2. `createUnitload(containerLabel, damagedLocation, unitLoadTypeId, stockUnit.getClientId(), CODE_DAMAGED)`
   — a brand-new container **at the Damaged location**; `boxtypeId` set from the item's default.
3. `stockunitBusinessService.transferStockToUnitLoad(stockUnit, container, amount, CODE_DAMAGED, null, comment, false, true)`
   — **this splits the stock unit** when `amount < stockUnit.getAmount()`, and writes the
   `stockrecord` rows (`activitycode = 'DAMAGED'`).
4. `damagedStock.setEntityLock(WmsConstants.BusinessObjectLockState.QUALITY_FAULT)` (= `103`) +
   `setAdditionalcontent(comment)` + save — **inside** the boundary, so a crash cannot leave damaged
   stock readable as `NOT_LOCKED`, i.e. pickable (D2).

So: **moves** (to `Damaged`), **splits**, **sets the lock flag**, **writes stock history**, and
**prints** — all five.

### Label printing

`StockunitService:978`:

```java
private void printLabel(boolean printLabel, Unitload unitLoad, Stockunit damagedStock) {
    if (printLabel && unitLoad != null) {
        … Printer defaultInboundPrinter = printerRepository.findByTypeAndProcessdefaultTrue(WmsConstants.PrinterType.INBOUND) …
        printService.cupsPrint(printer, caseLabel);
```

Gated on the **caller-supplied `printLabel` boolean**, *not* on `PRINT_CASE_LABEL`, and it uses the
**INBOUND** default printer — whereas the auto-receive path uses a **RETURN**-type printer. Two
different printer selections for the two paths; any SBDEV-1512 design that fuses them has to pick one.

### Callability from a non-HTTP context

**Yes.** It is a plain `public` method on a `@Service` with no `@PreAuthorize`, no `@RequiresFunction`
and no HTTP-scoped arguments except `Principal principal` — **which the body never reads**
(read in full; `principal` is unused). The authorization sits on the two controller handlers only:

```java
@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)
@PostMapping(path= "/transferToDamaged", …)
@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)
@PostMapping(path= "/bulkTransferToDamaged", …)
```

A receive path could call it directly and would bypass the gate entirely — **which is a design
decision to make deliberately, not a side effect to inherit**: `/rest/advice/create` is `permitAll()`,
so calling `setLockDamaged` from there hands an unauthenticated caller a capability the UI gates.

**Caller census (instrument: `git grep -n "setLockDamaged\|moveStockToNewDamagedContainer" origin/develop -- 'src/main/java/**/*.java'`):**
exactly **two** call sites, both in `StockUnitController` (`:553`, `:595`). Remaining hits are the
declaration and comment references. **Blind spot:** a reflective or SpEL invocation would not appear;
none is plausible here, and the two controller sites match the two UI actions.

### Preconditions summary

The stock unit must already exist, be `entity_lock = 0`, have `amount > 0` and
`availableamount >= amount`. It does **not** have to be in a "normal" *location* — no location check
is performed on the source — but the `Damaged` **location row must exist by name** or the method
throws `EntityNotFoundException`.

---

## 4. Is there ANY existing path that receives stock directly into a damaged state?

**No.** Four probes, each with a positive control.

### Probe A — every `QUALITY_FAULT` mention in `src/main/java`

`git grep -n "QUALITY_FAULT" origin/develop -- 'src/main/java/**/*.java'` → 30 hits across 8 files
(**non-zero, so the instrument works**). Filtering to **writes** (`setEntityLock(… QUALITY_FAULT)`)
gives exactly **three** sites:

| # | Site | Reached from |
|---|---|---|
| 1 | `UnitloadService:179` (`moveStockToNewDamagedContainer`) | `setLockDamaged` ← `POST /stockUnit/{bulk}transferToDamaged` |
| 2 | `StockunitService:585` (`transferStock`, when destination location is named `Damaged`) | `POST /stockUnit/transferStock` |
| 3 | `MobileMoveUnitloadService:563` (mobile move unit load into `Damaged`) | mobile Move Unit Load |

All three are **operator-initiated moves of stock that already exists**. None is in a receiving,
goods-receipt or putaway path.

**Blind spots, stated:** the grep keys on the *constant name*, so a site writing the literal `103`
would be missed, and a native-SQL `UPDATE` would be missed.

### Probe B — literal `103` / native `entity_lock = 103` writes

`git grep -nE "setEntityLock\(\s*103|entity_lock\s*=\s*103" origin/develop -- src/main`
→ **one** hit, and it is a **read**, not a write:
`V2.2.00__base_v2_schema.sql:4700` — `WHEN ((su.entity_lock = 103) OR (ul.entity_lock = 103)) THEN su.amount` (the `stock_view.damaged` column).
Positive control: `git grep -c "setEntityLock(" -- 'src/main/java/**/*.java'` returns 55 files, so the
matcher does find `setEntityLock` calls; the zero for `103` is a true zero.

### Probe C — `STORAGE_LOCATION_DAMAGED` inside the receiving pipeline

Scanned: `ReceivingService`, `ReturnAdviceAutoReceiveService`, `PutawayDestinationResolver`,
`PutawayConfigService`, `AdviceRestController`.
**Result: zero hits (exit 1).**
**Positive control:** `git grep -c "STORAGE_LOCATION_" -- ReceivingService.java` → **17**. The scanner
*can* see location constants inside `ReceivingService` (`STORAGE_LOCATION_INBOUND_NAME`,
`STORAGE_LOCATION_SPAWN`, …); it simply never sees `DAMAGED` there. The zero is real.

### Probe D — any damage/condition field on the receipt or advice model

`git grep -in "damag"` over `model/Goodsreceipt*.java`, `model/Advice*.java`, `json/Advice*.java`
→ **zero hits (exit 1)**.
**Positive control:** `git grep -ci "amount"` over the same file set → `AdvicePositionDto` 13,
`AdviceUploadDto` 6, `Adviceposition` 5, `Goodsreceiptposition` 5. The scan reaches those files.

### Verdict

The receiving pipeline has no damaged concept at any layer — not on the wire DTO, not on
`Adviceposition`, not on `Goodsreceiptposition`, not in `ReceivingService`, and not in the putaway
resolver. `PutawayDestinationResolver` routes by item/merchant/warehouse config; `Damaged` is never a
candidate destination. **SBDEV-1512 is net-new capability, not a broken existing one.**

---

## 5. What `STORAGE_LOCATION_DAMAGED` resolves to, and whether it is guaranteed

```java
// WmsConstants.java:939
public static final String STORAGE_LOCATION_DAMAGED = "Damaged";
```

It is a **name lookup**, `locationRepository.findByName("Damaged")`, at every one of its four
consumers (`StockunitService:770`, `StockunitService:569/582`, `MobileMoveUnitloadService:321`,
`UtilRestController:865`). There is no id constant, no enum, no FK.

### Provisioning

**Fresh v2 DB** — seeded by the base dump, `V2.2.00__base_v2_schema.sql:2467`, inside
`INSERT INTO public.location VALUES` at **id = 6**, `type_id = 3`, `area_id = 0`:

```sql
(6, NULL, '2021-07-12 14:36:33.032+00', 0, '2021-07-12 14:36:33.032+00', 0, 0, 0, 0, 'Damaged', 0, 0, NULL, 3, false, false, false, false, false),
```

**v1→v2 onboarding toolkit** — the equivalent seed exists at
`db/v1-to-v2-onboarding/schema/V1.1.02__wms_data.sql:53`, same id 6, same shape.

**`UtilRestController.initDB` does NOT create it.** The creation line is commented out
(`:809`: `// locationService.createLocation(client_system, WmsConstants.STORAGE_LOCATION_DAMAGED, storage_location_type_overstock_box, default_area);`).
What `initDB` *does* is **assume it already exists** and re-type it (`:865`):

```java
loc = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_DAMAGED).orElseThrow(() -> new EntityNotFoundException("Location not found by name: " + WmsConstants.STORAGE_LOCATION_DAMAGED));
loc.setTypeId(storage_location_type_overstock_box.getId());
```

So on a DB lacking the row, `initDB` **throws** rather than repairing it.

### Is it guaranteed on a v1→v2 MIGRATED tenant?

**Measured, not assumed.** Both ShipItEZ UAT tenants have it:

| Tenant | id | `type_id` | `sltname` | `area_id` |
|---|---|---|---|---|
| `nywh-shipitez-uat` | 6 | 3 | `overstock box` | 0 (`Default`) |
| `c1wh-shipitez-uat` | **50184** | 50053 | `overstock box` | 50100 |

The `50xxx` id on `c1wh` is the v1-migration id offset — i.e. that row came from the **client's own v1
data**, not from the v2 seed. So on a migrated tenant the guarantee rests on the v1 database having
had a location literally named `Damaged`, which it does because v1 depends on the same name lookup
(`v1/wms-api` `StockunitService:407`, `MobileMoveStockService:245`, `MobileMoveUnitloadService:208`,
`WmsConstants:769`).

**⚠ Flag it anyway, for three reasons:**

1. **It is name-keyed with no constraint behind it.** There is no unique index on `location.name` and
   no `NOT REMOVE` guard — the `Damaged` row, unlike `Nirwana`/`Clearing`/`Spawn`, does **not** carry
   the `'This is a system used entity. DO NOT REMOVE OR LOCK IT!'` description in either seed (its
   description column is `NULL`). An operator renaming or deleting it breaks the feature at runtime
   with an `EntityNotFoundException`, and nothing in CI or Flyway would catch it.
2. **Its `type_id` differs across the two provisioning routes in principle** — the base dump hard-codes
   `3`, and `initDB` re-points it at `overstock box`. Both measured tenants happen to resolve to
   `overstock box`, so they agree today; a tenant that never ran `initDB` and whose v1 row had a
   different type would silently diverge, and the type is what governs `location_constraint`
   compatibility (`CONSTRAINT_OVERSTOCK_BOX` ⇒ only `Box` unit loads). `setLockDamaged` always mints a
   `Box` container, so it happens to satisfy that constraint — a receive path that placed a `Pallet`
   into `Damaged` would **not**.
3. `area_id` differs (`0` vs `50100`), and `PutawayDestinationResolver` reasons about
   `LocationArea.useforpicking`. Any SBDEV-1512 design that routes a *receipt* to `Damaged` through
   the putaway resolver must be checked against that area on each tenant, not just on dev.

**Recommendation:** whatever SBDEV-1512 does, resolve `Damaged` **once, at validate time**, and fail
pre-persist — the same R9 discipline `ReturnAdviceAutoReceiveService` already applies to the printer,
the box type and the putaway destination.

---

## 6. Stock history / reporting — which view the bottles fail to appear in

There are **three** distinct "damaged" surfaces, and they key on different things. This matters:
a fix that satisfies one will not necessarily satisfy the others.

### (a) `stock_view.damaged` — the live damaged-inventory view

`V2.2.00__base_v2_schema.sql:4685`, mapped by `model/StockView.java` (`@Table(name = "stock_view")`,
`@Column(columnDefinition = "numeric", name = "damaged")`):

```sql
sum(CASE WHEN ((su.entity_lock = 103) OR (ul.entity_lock = 103)) THEN su.amount ELSE (0)::numeric END) AS damaged,
```

**Keyed purely on `entity_lock = 103`**, on the stock unit **or** its unit load. Not on location, not
on activity code, not on any advice field.

⇒ Auto-received return stock (`entity_lock = 0`, measured above) contributes **0** to this column.
**This is almost certainly the view the ShipItEZ client means when they say the bottles "fail to
appear in damaged inventory."** It is also the cheapest thing for SBDEV-1512 to satisfy: setting
`entity_lock = 103` on the received stock unit is *sufficient*, regardless of where it sits.

### (b) `transaction_detail(...)` — the transaction report

Served by `TransactionReportRestController` (`@RequestMapping("/rest/report")`,
`POST /getTransactionReport` and the detailed variant) via the `TransactionDetailView` projection.
Current function body: `db/migration/V2.2.25__transaction_detail_return_order_refs.sql`.

```sql
coalesce(CASE WHEN sr.activitycode = ''DAMAGED'' AND sr.type = ''STOCK_CREATED''
  THEN sr.amount ELSE 0 END, 0) AS damaged,
```

and the row's label:

```sql
(CASE WHEN tr.received != 0    THEN ''Received''
 WHEN tr.returned  != 0        THEN ''Returned''
 …
 WHEN tr.damaged   != 0        THEN ''Damaged''
```

with `returned` being `sr.activitycode = 'RETURN'`.

**Keyed on `stockrecord.activitycode`, and `RETURN` and `DAMAGED` are mutually exclusive tokens**
(`WmsConstants:985-986`: `CODE_RECEIVING_RETURN = "RETURN"`, `CODE_DAMAGED = "DAMAGED"`). Because the
`CASE` is ordered, a row with `returned != 0` is labelled **`Returned`** and can never *also* be
labelled `Damaged` — even if the underlying stock is `QUALITY_FAULT`.

⇒ A damaged return received through the advice path lands in the report as **`Returned`**, with
`damaged = 0`. **Fixing (a) alone does not fix (b).**

**Live corroboration (`c1wh-shipitez-uat`, `stockrecord`):**

| `activitycode` | `type` | rows | last seen |
|---|---|---|---|
| `DAMAGED` | `STOCK_CREATED` | 230 | 2026-08-19 |
| `DAMAGED` | `STOCK_REMOVED` | 165 | 2026-08-19 |
| `DAMAGED` | `STOCK_TRANSFERRED` | 1 | 2024-01-05 |
| `RETURN` | `STOCK_CREATED` | **2,956** | 2026-09-08 |

Two disjoint populations. 1,037 RETURN advices, **all** `FINISHED`. Not one `DAMAGED` row was
produced by a return.

### (c) `InventoryRecord.damage` — the periodic stock snapshot

`model/InventoryRecord.java:31` — `@Column(columnDefinition = "numeric(19,2)") private BigDecimal damage = BigDecimal.ZERO;`
Written by `InventoryRecordService` / `WarehouseStockReportService` / `StockSummaryExportJob`
(instrument: `git grep -ln "InventoryRecord" -- src/main/java`, 8 files).
`UnitloadService:579` shows the derivation idiom:

```java
int damaged = (entityLock != null && entityLock == BusinessObjectLockState.QUALITY_FAULT) ? stockUnit.getAmount().negate().intValue() : 0;
```

⇒ same `entity_lock = 103` key as (a). Fixing (a) fixes (c).

### (d) The OMS-facing wire — `StockChangeDto`

`SharedService:129` `getStockChangeDTO(itemData, total, damaged, missing, onHold, transfer, comment, activityCode)`
→ `setNormal(total)` / `setDamaged(damaged)`.

- RETURN receive: `(originalAmountBottles, 0, 0, 0, 0, …, CODE_RECEIVING_RETURN)` — `normal = +N`, `damaged = 0`.
- `setLockDamaged`: `(0, amount, 0, 0, 0, comment, CODE_DAMAGED)` — `normal = 0`, `damaged = +N`.

So **OMS's own inventory is also told the returned units are normal stock.** Any SBDEV-1512 design
must decide what the wire message says, or OMS and WMS will disagree about the same bottles.

### Summary table

| Surface | Keyed on | Damaged return today? | Fixed by setting `entity_lock=103`? |
|---|---|---|---|
| `stock_view.damaged` | `entity_lock = 103` | **No** — counted as normal | **Yes** |
| `InventoryRecord.damage` | `entity_lock = 103` | **No** | **Yes** |
| `transaction_detail.damaged` | `activitycode='DAMAGED' AND type='STOCK_CREATED'` | **No** — labelled `Returned` | **No** — needs a `DAMAGED` stock record too |
| OMS `StockChangeDto.damaged` | explicit call argument | **No** — sent as `normal` | **No** — needs the DTO argument changed |

---

## Open risks

**Biggest:** the three damaged surfaces key on **two different things**
(`entity_lock = 103` vs `stockrecord.activitycode = 'DAMAGED'`), and a natural implementation —
"receive the damaged units, then stamp `QUALITY_FAULT`" — satisfies only the first. The transaction
report would keep showing those bottles as `Returned` with `damaged = 0`, which is very likely one of
the symptoms being reported. An acceptance criterion written against `stock_view` alone would pass
while the client's report stays wrong.

**Second:** `PRINT_CASE_LABEL` is a `Boolean.parseBoolean` default-OFF gate on the only label the
restock path emits, it was touched on `c1wh-shipitez-uat` on 2026-09-09, and
`los_sysprop.modified` cannot tell us whether the *value* changed. The "no unit-load label printed"
complaint may be entirely a sysprop story rather than a code story — confirm with the client before
designing anything.

**Third:** `setLockDamaged` is ungated at the service layer (`@RequiresFunction` lives only on the two
controller handlers) and reads its `Principal` parameter not at all, while `/rest/advice/create` is
`permitAll()`. Wiring the two together without an explicit decision hands an unauthenticated caller
the `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` capability.

**Fourth:** `setLockDamaged` requires a source stock unit at `entity_lock = 0` and rejects everything
else, and `moveStockToNewDamagedContainer` always mints a **new** `Box` unit load at `Damaged` — so
reusing it from the receive path means receiving normally and then immediately splitting/moving,
producing two unit loads, two labels and two stock records per damaged line. Whether that is the
desired physical workflow is a question for the warehouse, not for the code.
