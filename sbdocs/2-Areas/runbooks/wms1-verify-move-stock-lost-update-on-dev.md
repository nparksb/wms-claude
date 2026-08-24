---
title: "WMSv1 — verify the Move Stock lost-update fix on WineCo dev (SBDEV-3003)"
ticket: "SBDEV-3003"
ticket_url: "https://app.clickup.com/t/868ku68tw"
type: runbook
priority: high
status: "RUNBOOK 2026-08-20 — executed end-to-end against WineCo v1 dev. M1, M2 and M5 all PASS; M4 and M6 still unrun. Every command here was actually run, not drafted. Reusable for QA and for any future concurrency change to StockunitBusinessService.transferStockToUnitLoad."
project: [wms1]
version: v1
requester: "nam.park@siteboss.net"
created: 2026-08-20
updated: 2026-08-20
related:
  - ../../1-Projects/wms1/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation.md
  - ../../3-Resources/workflows/wms1-move-stock-unitload-workflow.md
  - ../../3-Resources/architecture/wms1-transaction-boundary-map.md
tags:
  - runbook
---

# Verify the Move Stock lost-update fix on WineCo v1 dev

Covers SBDEV-3003 (wms-api PR #200 / `5425625`, wms-mobile-ui PR #101 / `b95b5e4`). The defect:
`transferStockToUnitLoad` computed a stock unit's new **absolute** amount from a **stale** caller
instance, so a replayed transfer debited the source once while crediting the destination twice.

**Reuse this for any future change to `transferStockToUnitLoad`.** The three tests below are the only
coverage the batch paths have — the v1 integration-test lane is dead (SBDEV-2384, `ro_id` view drift),
so nothing here can be replaced by a unit test.

---

## 0. Environment — get this wrong and every result is meaningless

| | |
|---|---|
| **v1 API** | `https://wms-api.wineco.dev.sbo.li` |
| **v1 DB** | `wh01_om1` @ `10.0.0.4` — MCP `wms1-wineco-dev` |
| Keycloak | `https://kc.dev.sbo.li/auth`, realm `spk`, client `om1` |
| Facility code | **`WSL`** (uppercase — `los_sysprop.MULTIWAREHOUSE_IDENTIFIER`) |
| Test client | **TCOMPANY** — id `52200`, `cl_nr` `TCOMPANY` |

⚠ **`wms-api.dev.sbo.li` (no `wineco`) is the v2 API, not v1.** Tell them apart with
`curl -s <host>/actuator/info` — **v1 is Java 8, v2 is Java 21**. The v2 host also returns 401 for an
`om1`-issued token because its per-tenant JWT decoder rejects it.

Do **not** test against `dev_wh01_om1` or `wh01_om1_v2`; both are v2 databases.

Confirm the API and the DB are the same environment before trusting anything — pick any batch from
the DB and fetch it:

```bash
curl -s -H "Authorization: Bearer $AT" \
  "$API/v3/clubLine/orderBatch/<batchid>" | head -c 300
```

### Token

```bash
API=https://wms-api.wineco.dev.sbo.li
AT=$(curl -s -X POST 'https://kc.dev.sbo.li/auth/realms/spk/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=password --data-urlencode client_id=om1 \
  --data-urlencode username=<user> --data-urlencode password=<pass> \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
```

Valid 2 h. `panderson` carries `/wms/wh01/wms_admin`, which is sufficient. `/rest/**` needs **no**
token; `/v3/**` does.

---

## 1. ⚠ The timezone trap — read before writing any query

`stockrecord.created` is **`timestamp without time zone`** holding **warehouse-local** time
(America/Los_Angeles), while `now()` returns **UTC**. A naive filter silently returns **nothing**:

```sql
-- WRONG: ~7h off, returns empty, reads as "nothing happened"
WHERE created > now() - interval '10 minutes'

-- RIGHT
WHERE created > (now() AT TIME ZONE 'America/Los_Angeles') - interval '10 minutes'
```

This bit during the real run. It is dangerous precisely because an empty result is
indistinguishable from a test that did nothing — and it could equally mask a **failing** test.
Safest habit: drop the time filter and use `ORDER BY created DESC LIMIT 20`.

**v2 differs** — `wh01_om1_v2` returns tz-aware timestamps, so a raw `now()` comparison works there.
Never carry a working v2 query into v1.

---

## 2. M2 — concurrent replay with no UI guard (start here)

Strictly harsher than a scanner double-fire, and it isolates the **API** fix. Run this first: a
UI-driven double-tap passing could mean the *UI guard* works while the API fix is **not deployed** —
the two ship separately.

Pick any stock unit with surplus and zero reserved:

```sql
SELECT i.item_nr, su.id, su.amount, su.version, ul.labelid, l.name
FROM stockunit su JOIN unitload ul ON ul.id=su.unitload_id
JOIN location l ON l.id=ul.storagelocation_id JOIN itemdata i ON i.id=su.itemdata_id
WHERE su.amount >= 200 AND su.reservedamount = 0 AND su.entity_lock = 0
  AND l.name NOT IN ('Nirwana','Shipped','Clearing') ORDER BY su.amount DESC LIMIT 5;
```

Fire two identical transfers concurrently:

```bash
P='{"id":<SU_ID>,"amountToTransfer":50,"printLabel":false,"locationName":"TransferLane01",
    "labelId":"<SOURCE_UL>","isTransferExistingContainer":false,"comment":null}'
for n in 1 2; do
  ( curl -s -X POST "$API/v3/stockUnit/transferStock" -H "Authorization: Bearer $AT" \
      -H 'Content-Type: application/json' -d "$P" -w "req$n HTTP=%{http_code}\n" -o /dev/null ) &
done; wait
```

```sql
SELECT to_char(created,'HH24:MI:SS.MS') AS ts, type, amount AS delta, amountstock, fromunitload
FROM stockrecord WHERE itemdata='<SKU>' ORDER BY created DESC LIMIT 8;
```

| | |
|---|---|
| **PASS** | `amountstock` **steps down** (e.g. 9891 → 9841 → 9791); source `version` +1 per debit |
| **FAIL** | two removals with the **same** `amountstock` — the defect; the API fix is not deployed |

**Measured 2026-08-20:** two calls 90 ms apart → `9841` then `9791`, `version 1 → 3`, ledger intact.

---

## 3. M1 — UI double-tap

Mobile UI → Move Stock: source stock-unit id, amount, **New Container**, pick `TransferLane01`, then
**tap Submit twice fast**. The button must grey out and spin after the first tap.

Expect **one** removal and **one** new unit load. (v1 dev has TransferLane01–06 only; there is no
TransferLane07 — that name comes from the customer's environment.)

---

## 4. M5 — club run splitting one shared stock unit ← **the important one**

This is the scenario that killed two earlier candidate fixes, and it has no automated coverage.

**Both conditions are required:**

1. the staged stock unit holds **strictly more** than one order needs → forces the *split* branch
2. **two or more orders** draw the same SKU → forces reuse of the **same managed instance**

Miss either and the run takes the whole-unit relocation branch, emits a single `STOCK_TRANSFERRED`
with `delta 0`, and proves nothing. That is exactly what batch `41664-6` did.

### 4a. Stage surplus in ONE container

```bash
curl -s -X POST "$API/v3/stockUnit/transferStock" -H "Authorization: Bearer $AT" \
  -H 'Content-Type: application/json' \
  -d '{"id":27113067,"amountToTransfer":30,"printLabel":false,"locationName":"StagingLane01",
       "labelId":"UL317397","isTransferExistingContainer":false,"comment":null}'
```

`27113067` = TCOMPANY WINE750 (itemdata `52350`), a large pool at location `1795`. StagingLane01 is
location id **`51619`**.

### 4b. Create the CLUB batch — `PUT /rest/order/create`, no auth

Every field below is **required**; the API validates them one at a time, so an incomplete payload
costs a round trip each. All JSON names are **snake_case** (`@JsonProperty`), not camelCase.

```bash
mk () { cat <<EOF
{"unique_id":"M5-XXX-$1","client_id":"TCOMPANY","client_order_number":"M5$1","number_of_items":6,
 "shippers_id":"GSP","weight":6,"box_sku":"2","fulfillment_type":"DTC-Direct Ship",
 "parcel_external_number":"M5PX-$1",
 "positions":[{"unique_id":"M5-XXX-$1-1","client_id":"TCOMPANY","number":1,"sku_id":"WINE750","amount":6}]}
EOF
}
curl -s -X PUT "$API/rest/order/create" -H 'Content-Type: application/json' \
  -d "[{\"facility_code\":\"WSL\",\"batch_id\":\"M5-XXX\",\"batch_name\":\"SBDEV-3003 M5\",
        \"batch_type\":\"CLUB\",\"priority\":3,\"client_id\":\"TCOMPANY\",
        \"positions\":[$(mk A),$(mk B),$(mk C)]}]"
```

Expect **HTTP 204**. Gotchas, all hit for real:

| Field | Requirement |
|---|---|
| `priority` | **1–5 on input.** The 0/100/1000/10000/100000 values in `WmsConstants.Priority` are the *stored* scale — sending 1000 fails "wrong format" |
| `facility_code` | `WSL`, case-sensitive (`AbstractRestController.validateWarehouse`) |
| `box_sku` | must match an existing `boxtype.externalid` — `"2"` = 6PK750C |
| `shippers_id` | resolved by `shipperid.externalid`; **auto-created if unknown**, so reuse an existing one (`GSP`, `GSC`, `WCCC`) to avoid junk |
| `fulfillment_type` | one of `3Tier`, `DTC-Direct Ship`, `DTC-Temp Control`, `Transfer`, `Will Call` |
| `parcel_external_number` | **optional at import, MANDATORY at club-run time.** Omit it and the batch imports and activates fine but `runClubLine` fails with *"has no parcel external number"* — a state that can never run. Must be unique |
| `batch_id` | must not already exist |
| naming | on a **batch**, `positions` = orders; on an **order**, `positions` = line items |

Three orders beat two — it distinguishes "only the last debit survived" from "one debit lost".

### 4c. Activate, then run — note the inconsistency

```bash
curl -s -H "Authorization: Bearer $AT" "$API/v3/clubLine/activateBatch/<BATCH_PK>/51619"
curl -s -H "Authorization: Bearer $AT" "$API/v3/clubLine/runClubLine/<BATCH_ID_STRING>"
```

⚠ **Same path-variable name, opposite semantics, same controller:** `activateBatch` does
`Long.parseLong(orderBatchId)` and wants the **numeric PK**; `runClubLine` does
`findByBatchid(orderBatchId)` and wants the **batchid string**. Get the PK with:

```sql
SELECT id, batchid, state FROM customerorder_batch WHERE batchid = 'M5-XXX';
```

### 4d. Verdict

```sql
SELECT to_char(created,'HH24:MI:SS.MS') AS ts, type, ordernumber,
       amount AS delta, amountstock, fromunitload
FROM stockrecord
WHERE activitycode='PACKAGING_CLUB' AND itemdata='WINE750'
ORDER BY created DESC LIMIT 12;

SELECT amount, version FROM stockunit WHERE id = <STAGED_SU_ID>;
SELECT state FROM customerorder_batch WHERE batchid = 'M5-XXX';   -- 530 = completed
```

| | |
|---|---|
| **PASS** | `amountstock` steps down once per order (30 → **24 → 18 → 12**); `version` = 1 + one bump per debit; batch state `530` |
| **FAIL** | the same `amountstock` repeated — a debit was lost. `version` short of the debit count is the same signal |

**Measured 2026-08-20:** three orders × 6 from a single 30-unit instance → `24`, `18`, `12`;
`version 1 → 4`; batch `530`. **PASS.**

`version` is the decisive field. In the original CWUSTK incident the source sat at `version = 1`
after **two** removals — proof the second write never reached the database.

---

## 5. Detecting existing victims

A `stockunit`-vs-ledger drift query **cannot** find them: the corrupting transaction writes nothing
at all (Hibernate's dirty check sees the freshly-loaded value equal to the stale-derived one and
emits no `UPDATE`), so the row carries no version bump and no `modified` change, and the
`stockrecord` deltas still sum correctly. Key on the duplicate-removal fingerprint:

```sql
SELECT itemdata, fromunitload, amount, amountstock, count(*) AS dups,
       min(created) AS first_seen, max(created) AS last_seen
FROM stockrecord
WHERE type='STOCK_REMOVED' AND created >= '2026-01-01'
GROUP BY itemdata, fromunitload, amount, amountstock
HAVING count(*) > 1 AND max(created) - min(created) < interval '10 seconds';
```

Validated both directions: finds the CWUSTK case on `wh01_om1` (**exactly one** occurrence in all of
2026), returns **zero** on `wh01_om1_v2`. Inflation per victim = `(dups − 1) × abs(amount)`.

**Never auto-repair.** A phantom +12 and a genuine +12 receipt are indistinguishable in `stockunit`
alone; establish the physical count first.

---

## 6. Remaining tests

- **M4** — CWUSTK must stay at 3,012 (pre-existing +12 damage; the fix prevents new corruption, it
  does not repair old). `SELECT su.amount, su.version FROM stockunit su WHERE su.itemdata_id = 21375992;`
- **M6** — close a BOL over a pallet holding **several** stock units (`BillofladingService:992` loops
  per stock unit). Pass: completes cleanly. Fail: dies mid-loop with *"more than available"*.

---

## 7. Cleanup

Test runs leave real unit loads. Harmless on dev, and the ledgers stay consistent.

**Route stock to Nirvana through the UI. Never `DELETE` rows** — that creates exactly the ledger
drift §5's detector hunts for, and poisons the next person's baseline.

Left behind by the 2026-08-20 run: batch `M5-3003-1` (pk `27892070`, state 530, parcels
`M5PX-00000{1,2,3}`); `UL317415` @ StagingLane01 with 12 WINE750; `UL317412`/`UL317414` @
TransferLane01 with 50 VUSTK each; `UL317409` with 100 VUSTK.

Note WINE750 carries a **pre-existing** `onhand − ledger = −12` discrepancy unrelated to these tests
(opposite sign to this ticket's defect). Don't read it as fallout.
