# SBDEV-1512 — DB verification (triage floor item 1)

Run 2026-09-15. Every query below was executed; results are pasted verbatim from the MCP result.

## E0 — Environment reality: ShipItEZ runs **v1** in production; the `_v2` DB is a frozen migration snapshot

| probe | `wh01_shipitez` (MCP `wms1-shipitez1`) | `wh01_shipitez_v2` (MCP `c1wh-shipitez-uat`) |
|---|---|---|
| `flyway_schema_history` present | **0** (psql-provisioned v1) | **1** (v2) |
| `count(*) FROM advice` | 3004 | 2999 |
| `max(advice.created)` | **2026-09-15 08:24 UTC** | 2026-09-10 20:08 UTC |
| `max(stockunit.created)` | **2026-09-15 09:36 UTC** | 2026-09-10 22:36 UTC |
| `count(*) advice WHERE type='RETURN'` | 1037 | 1037 |
| `max(created) RETURN advice` | 2026-09-08 | 2026-09-08 |

Reading: the v1 DB is taking live writes today; the v2 DB stopped on 2026-09-10 and carries an
**identical** RETURN-advice population, i.e. it is a copy taken during migration rehearsal, not a
second live system. **No return has ever been processed by a v2 WMS for ShipItEZ.**

Consequence for the plan: the client-reported symptom (ST#979) is observed against **v1**, while the
fix target is **v2** (Nam's 2026-04-12 ticket comment; [[v1-is-reference-only-v2-is-the-only-target]]).
The QA station (`v1/qa-api`) is **shared** — it routes by `wms_url` per facility — so any change to
the QA→WMS contract touches live v1 production traffic on the same day it ships. That coupling is
what makes this T3.

`nywh-shipitez-uat` = `wh02_shipitez_v2`: 19 RETURN advices, latest 2025-11-26 — stale, not useful.

## E1 — The symptom, confirmed structurally: the RETURN advice contract has **no** damaged field

```sql
SELECT table_name, column_name FROM information_schema.columns
WHERE table_schema='public' AND column_name ILIKE '%damag%' ORDER BY table_name;
```
→ exactly two rows, on `wh01_shipitez_v2`:

| table_name | column_name |
|---|---|
| `inventory_record` | `damage` |
| `stock_view` | `damaged` |

Neither `advice` nor `adviceposition` nor any receiving table has one. Full `adviceposition` column
list: `id, created, modified, name, number, version, externalid, notifiedamount, notifiedcases,
state, client_id, advice_id, boxtype_id, itemdata_id, unitloadtype_id, palletlabel, parcellabel,
manifestlocation, shipperid_id`.

**Positive control** (required — a broken instrument and a true zero are indistinguishable): the same
`information_schema.columns` instrument, run on `adviceposition` with `column_name ILIKE '%notified%'`,
returned `notifiedamount` and `notifiedcases` — non-zero, so the scan works and the damaged-column
zero is real.

So the loss is structural at **both** ends: `v1/qa-api` sends only `qty_undamaged`
(`flask_app/common_util/wms_api.py`, `"amount_of_bottles = returned_items[item.item_id]['qty_undamaged']"`),
and the WMS schema could not store a damaged quantity even if it were sent.

## E2 — "Damaged inventory" is a **lock code**, not the Damaged location

`stock_view.damaged` (the view behind the client's damaged-inventory report) is defined as:

```sql
sum(CASE WHEN su.entity_lock = 103 OR ul.entity_lock = 103 THEN su.amount ELSE 0 END) AS damaged
```

It never references `location.name = 'Damaged'`. This **reframes the ticket's wording**: the ticket
asks for damaged stock to be "placed in the Damage location", but placing it there is not what makes
it show up as damaged. `entity_lock = 103` is. A fix that only moves stock to the location would
leave the client's report exactly as empty as it is today.

**Two instruments on `wh01_shipitez_v2`, and they disagree** — the disagreement is the finding:

| measure | rows | qty |
|---|---|---|
| `entity_lock = 103` on stockunit or unitload | **171** | 42 |
| unit load sitting in `location 'Damaged'` (id 50184, type_id 50053) | **158** | 42 |
| both | 156 | — |
| locked damaged but **not** in the Damaged location | **15** | — |
| in the Damaged location but **not** locked damaged | **2** | — |

Quantities agree (42) because the 15 extra rows carry amount 0. Row-level they do not. Any acceptance
criterion for this ticket must say **which** of the two it grades, and the answer should be the lock.

## E3 — The undamaged half of restock works; only the damaged half vanishes

Every recent RETURN adviceposition on `wh01_shipitez_v2` is `FINISHED` with exactly one
`goodsreceiptposition` whose `amount` equals `notifiedamount` (15 most recent positions inspected,
spanning advices `RETURN123977`, `RETURN122255`, `RETURN124233`, `RETURN123348`, `RETURN123766`,
`RETURN123663`, 2026-08-20 → 2026-09-08). Monthly rollup: 1037 RETURN advices, **0** in any state
other than `FINISHED`, across 2025-08 → 2026-09.

This **partially refutes the reported cause.** Ryan Fernandez's "I have the restock option selected
every time, yet it still does not print and the bottles disappear" reads as *restock is broken*. It
is not — what the QA station sends arrives and is received cleanly. What disappears is precisely the
quantity the QA station never sends. Blind spot: this measures the WMS side only; whether a UL label
physically printed is not recorded in these tables, so the "no ULs" half of the complaint is
**not** settled by this evidence and needs the qa-api service-log query below.

## E4 — Blast radius: measurable lower bound only

A return in which **every** item is damaged produces an advice with **zero** positions, because
`build_wms_create_advice_request` skips any position with `amount_of_bottles == 0`. On live
`wh01_shipitez`: **1 of 1037** RETURN advices has zero positions.

That is a *lower bound*, not the exposure. Partially-damaged returns — the common case — produce a
well-formed advice that is silently short by the damaged quantity, and the WMS has no record of the
shortfall to count. **The real number lives in the OMS/QA MySQL database, which has no MCP server in
this session.** The implementer must run, against the ShipItEZ QA schema:

```sql
-- total damaged units silently dropped, and how many returns are affected
SELECT count(DISTINCT rt.parcel_id)      AS returns_with_damage,
       sum(rti.quantity_damaged)         AS units_never_received,
       min(rt.manage_date)               AS first_seen,
       max(rt.manage_date)               AS last_seen
FROM   return_item rti
JOIN   return_ rt ON rt.parcel_id = <join per flask_app/models.py rti_/rt_ definitions>
WHERE  rti.quantity_damaged > 0;
```

(Exact table/column identifiers must be taken from `flask_app/models.py` — `rti_` and `rt_` — not
from this snippet.)

---

## E5 — Rollout-safety probe: v1/wms-api ignores an unknown advice field (does NOT 400)

The chosen rollout (Nam, 2026-09-15) is **additive**: `qa-api` always sends a new per-position
damaged quantity; v2 consumes it, v1 ignores it. That is only safe if v1's advice endpoint tolerates
an unknown JSON key. Derived from `origin/develop` of `v1/wms-api`:

**Endpoint.** `AdviceRestController`, `"@RequestMapping(\"/rest/advice\")"` +
`"@PutMapping(value = \"/create\", consumes = \"application/json\""` binding
`"@RequestBody List<AdviceDto> adviceList"`. This is the endpoint `qa-api`'s
`send_wms_create_advice` targets (`url = f'{wms_base_url}rest/advice/create'`, sent with
`requests.put`) — method and path both match.

**Two independent mechanisms both set the tolerant behaviour**, in `WebConfigurer`:

1. The `@Primary` `ObjectMapper` bean — `"mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)"`.
2. `extendMessageConverters` re-applies it to the live MVC converter —
   `"objectMapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)"`.

**No DTO-level override.** Neither `AdviceDto` nor `AdvicePositionDto` carries a
`@JsonIgnoreProperties` annotation (instrument: `git grep -l` for the class declarations on
`origin/develop`, then a per-file grep for `JsonIgnoreProperties|JsonProperty|private `; blind spot —
this reads the two DTO source files only, so a `@JsonIgnoreProperties` inherited from
`AbstractWebServiceDto`, which `AdviceDto` extends, would not be caught by that grep and must be
checked before the change ships).

`AdvicePositionDto`'s current fields are exactly: `reference_id`, `client_id`, `sku`, `box_id`,
`amount_of_boxes`, `amount_of_bottles`. A new sibling key is therefore unmapped, and unmapped means
dropped, not rejected.

**Verdict: the additive field is safe for live v1 traffic** — but this is a code-level read, not an
observed one. The plan must pin it with an executable check (a v1 deserialization test asserting a
payload carrying the new key binds without throwing, or a probe against a v1 dev instance), because
"I read the config" is exactly the class of claim that has been wrong before in this repo.

---

## E6 — Closing the Architect's stated blind spot on `notifiedamount` consumers

The Architect review's finding **H2** (`notifiedamount` stays at the undamaged quantity while the
receive takes the total) named its consumers via `git grep -ln "notifiedamount" origin/develop -- src/main`
and declared a blind spot inline: *"a projection interface deriving the column by property name, or a
report function inside `V2.2.00__base_v2_schema.sql`, would not appear — and `notifiedamount` **does**
appear in that SQL file, which I did not read for view definitions."*

Closed by querying the live schema on `c1wh-shipitez-uat` rather than parsing the 17k-line dump.

**Views** — `SELECT table_name FROM information_schema.views WHERE table_schema='public' AND view_definition ILIKE '%notifiedamount%'`
→ **one** row: `receiving_dto_view`. Already named by H2 via `ReceivingDtoViewRepository`, so no new consumer.

**Report functions** — `SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' AND pg_get_functiondef(p.oid) ILIKE '%notifiedamount%'`
→ **zero** rows.

**Positive control on that zero** (a broken instrument and a true zero are indistinguishable): the same
`pg_get_functiondef ... ILIKE` instrument, run over the three known report functions for a token they
certainly contain:

| function | `%activitycode%` | `%notifiedamount%` |
|---|---|---|
| `stock_history` | **true** | false |
| `transaction_detail` | **true** | false |
| `transaction_summary` | **true** | false |

The control returns non-zero, so the instrument works and the `notifiedamount` zero is real.

**Effect on H2: it stands, but its blast radius is bounded.** The over-delivery does NOT propagate into
`transaction_detail`, `transaction_summary` or `stock_history`. The damage is confined to the two Java
consumers H2 already named (`AdviceRepository`'s `SUM(ap.notifiedamount) as qtyRequired` and
`ReceivingDtoViewRepository`'s `ap.notifiedamount AS orderedbottles`) plus the `receiving_dto_view` that
backs the second — i.e. the **receiving screen reads "ordered 7 / received 10"**, and the advice list
understates required quantity. No report is silently corrupted.

**Blind spots of THIS check, stated:** it reads the live `wh01_shipitez_v2` schema, which is a migration
snapshot frozen 2026-09-10 and may lag `db/migration` HEAD — a function added in a later `V2.2.x` would
not appear. `prokind='f'` excludes procedures and aggregates. And it does not address H2's other named
blind spot, a projection interface deriving the column by property name, which is a Java-side question
this query cannot see.

---

## E7 — OQ-7 SETTLED: D5's "two messages, net-correct" is NOT net-correct, and the cause is a pre-existing defect

Derived from `origin/develop` of `v2/oms-laravel-api` (the consumer) and `v2/wms2-api` (the producer).

### The OMS contract, stated in its own code

`app/Services/Legacy/LegacyInventoryAdjustService.php`, `applyInventoryQuantities`:

```php
$newValue = $addToExisting ? ((int) $inventory->{$column} + (int) $value) : (int) $value;
$inventory->{$column} = max(0, $newValue); // inventory can never go negative
```

Each bucket is an **independent additive delta**. `quantity_damaged` rising does **not** reduce
`quantity_on_hand`. The netting branch immediately above is explicitly gated OFF for this path:

```php
if (!$addToExisting && array_key_exists('quantity_on_hand', $quantities)) {
    $quantities['quantity_on_hand'] = (int) $quantities['quantity_on_hand']
        - (int) ($quantities['quantity_damaged'] ?? 0) ...
```

and the comment says what the incremental path requires instead, with a worked example:

> *"The incremental stock-update path (`$addToExisting = true`) is NOT netted: its `normal` field is a
> per-bucket delta of GOOD units only, arriving alongside independent damaged/missing/on_hold deltas.
> Netting it would double-count a bucket move — e.g. **shifting one unit from good to damaged is
> reported as normal -1 / damaged +1** and must drop on-hand by 1, not 2."*

**So a good→damaged move MUST be sent as `normal = −N, damaged = +N`.** That is the contract, written
by the consumer, with the exact case at hand as its example.

### What the WMS actually sends — and it is inconsistent across sites

Instrument: `git grep -n "getStockChangeDTO" origin/develop -- src/main/java` (20 hits: 2 declarations
in `SharedService`, 18 call sites). Blind spot: a caller constructing a `StockChangeDto` directly
rather than through this factory would not appear.

| Site | `normal` arg | `damaged` arg | Obeys the contract? |
|---|---|---|---|
| `UnitloadService:582` (manual removal) | `stockUnit.getAmount().negate()` | `damaged` | **Yes** |
| `StockunitService:786` (**`setLockDamaged` — the method D1 reuses**) | **`0`** | `damagedStock.getAmount()` | **No** |
| `StockunitService:609` (`transferStock` into `Damaged`) | **`0`** | `damagedStock.getAmount()` | **No** |
| `MobileMoveUnitloadService:560` (mobile move into `Damaged`) | **`0`** | `stockUnit.getAmount()` | **No** |

One site nets; the three damage sites do not. The disagreement between two call sites of the same
factory IS the finding — it is not a style difference, it is one of them being wrong.

### Consequence for this ticket

Under D5, a 5-unit return with 2 damaged sends:

| message | `normal` | `damaged` | OMS effect |
|---|---|---|---|
| receive (`ReceivingService:584`) | +5 | 0 | `quantity_on_hand += 5` |
| damage (`setLockDamaged`) | **0** | +2 | `quantity_damaged += 2` |
| **net** | **+5** | **+2** | on_hand **5**, damaged 2 |

Physical reality is **3 sellable, 2 damaged**. The OMS would hold **5 sellable** — it **overstates
sellable inventory by exactly the damaged quantity, on every mixed return**, which is an
overselling exposure and the precise opposite of what the ticket asks for.

**The fix is one argument:** the damage message must carry `normal = −damagedAmount`. Either at the
new call site, or — better — by correcting `setLockDamaged` itself, which also repairs the
pre-existing defect below.

### The pre-existing defect this uncovers (scope note)

`setLockDamaged` is the method behind the **manual "Transfer To Damaged" row action**, which is live
today. Every manual damage move already sends `normal = 0`, so **the OMS has been overstating
sellable inventory by the damaged quantity on every manual damage since that path shipped.** This
ticket did not introduce it; D1 would inherit and multiply it across every damaged return.

Tier of the added scope: **T3** (data integrity, cross-system, affects live client inventory).
Per the ticket policy a T3 finding is **PROPOSED, never filed** — Nam decides. Two shapes:

1. **Fix `setLockDamaged` (and the two sibling sites) to send `normal = −N`.** Repairs the manual
   flow and makes D1 correct by construction. Blast radius: every OMS inventory sync from a damage
   move; needs a backfill decision for inventory already drifted.
2. **Fix only the new call site**, leaving the manual flow wrong. Cheaper, keeps this ticket
   self-contained, but ships a knowingly-inconsistent contract and leaves the existing drift.

**Blind spots of this analysis, stated:** (a) it reads `origin/develop` of `oms-laravel-api`, and
which build each client actually runs was not checked; (b) it assumes the WMS→OMS stock sync reaches
`LegacyInventoryAdjustService` for these clients — the outbox/notification routing was not traced
end to end here; (c) it does not measure the accumulated drift on any live tenant, which would need
an OMS MySQL read (no MCP in this session). Any remediation must confirm (a) and (b) first.

---

## E8 — ⚠ E7 IS INVERTED. The defect is in the OMS, not the WMS. D8 would fix the wrong side.

E7 identified a real symptom — the OMS overstates sellable inventory after a damage move — and
attributed it **backwards**. Established by `oms-routing-lane` and independently re-verified here.

### The WMS convention is four years old and has never once matched what the OMS now assumes

On live v1 production `wh01_shipitez` (MCP `wms1-shipitez1`), over the `message` table:

| probe | rows |
|---|---|
| messages mentioning `damaged` | 12,611 |
| shape `"normal": 0` **and** `"damaged": +N` | **173** |
| shape `"normal": -N` **and** `"damaged": +N` | **0** |
| span | 2022-07-31 → **2026-09-15** (today) |

**Positive control on that zero** — the decisive step, because a broken regex and a true zero look
identical. Over the same table:

| control probe | rows |
|---|---|
| any `"normal": -N` at all | **1,634** |
| any `"normal": +N` | 10,802 |
| any `"damaged": -N` | 145 |

The matcher finds negative `normal` 1,634 times, so it works. The WMS **can** and **does** emit a
negative `normal` — just never paired with a positive `damaged`. The tuple `normal:-N, damaged:+N`
does not exist in four years of production traffic.

### The actual regression: `oms-laravel-api` commit `dd17b84f`, 2026-07-31 (SBDEV-2671)

That commit changed the netting guard in `LegacyInventoryAdjustService::applyInventoryQuantities`
from unconditional to incremental-path-excluded:

```php
-        if (array_key_exists('quantity_on_hand', $quantities)) {
+        if (!$addToExisting && array_key_exists('quantity_on_hand', $quantities)) {
```

**Before** it, the incremental path netted too: for `normal:0, damaged:+N` the adjusted on-hand
delta was `0 − N = −N`, so `quantity_on_hand` fell by N and `quantity_damaged` rose by N —
**correct**. **After** it, on-hand is unchanged and damaged rises — sellable overstated by N.

Its own justification asserts *"shifting one unit from good to damaged is reported as normal -1 /
damaged +1"*. The 173/0 measurement above says the WMS has never done that. Its pinning test fixes
`normal:10, damaged:1`, a tuple no WMS call site emits.

### Consequences

- **`normal` is a GROSS physical delta**, and the OMS derives sellable by netting. Under that rule
  the WMS sites E7 flagged are **correct**, and the convention matches v1's Zend OMS
  (`productUpdate.psql`, `SET on_hand = on_hand - damaged - missing - on_hold`) unchanged.
- **D8 is withdrawn.** Editing `setLockDamaged`, `transferStock` and `MobileMoveUnitloadService` to
  send `normal = −N` would repair 1 of the lane's 10 mismatched sites, break the WMS's internal
  consistency with v1, and leave the actual regression in place.
- **The fix is one condition in `applyInventoryQuantities`**, in `oms-laravel-api` — not three edits
  across two WMS subsystems.
- **Drift to date is zero** on the measured tenants, because no WMS site emits the shape the new OMS
  code mishandles — but see the limit below.

### Where E7 went wrong, so the same error is recognisable next time

E7 read the *consumer's own code comment* as the contract and never checked it against the
*producer's traffic*. The comment was newly written, by the change that introduced the regression,
and it described a convention that had never existed. **A comment asserting what a caller sends is a
claim about a system, not documentation of it — verify it against the wire.** The 173/0 query is
twenty seconds of work and would have inverted the conclusion before any decision was taken.

### Stated limits of E8

`oms-routing-lane` reports 10 of 18 sites mismatched under today's OMS, in **both** directions —
that count is its work, not re-derived here, and it should be re-checked before any OMS-side fix.
The deployed `oms-laravel-api` build could not be read; `dd17b84f` is on `main` with earliest tag
`v2.0.76` (2026-08-04), which is tag ancestry, not a deploy confirmation. And **"zero drift" rests
on the absence of defective messages, not on a reconciliation** — no MySQL MCP exists for the OMS
tenant DBs, so `product_inventory.quantity_on_hand` was never compared against WMS stock.
