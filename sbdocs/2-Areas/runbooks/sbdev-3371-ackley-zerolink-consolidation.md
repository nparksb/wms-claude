---
title: "SBDEV-3371 — release the Ackley and Zerolink orders held on WineCo v1"
ticket: "SBDEV-3371"
ticket_url: "https://app.clickup.com/t/868m5ucd1"
type: runbook
status: "DRAFTED 2026-09-16 — stock state measured against WineCo v1 prod; script logic tested end-to-end against a local stub (happy / resume / wrong-target / refusal / HTTP-500 paths). NOT yet executed against production: needs the API hostname confirmed and a prod Keycloak credential."
last_verified: 2026-09-16
applies_to: WineCo v1 PRODUCTION (`wh01_om1`, MCP `wms1-wineco`)
project: [wms1]
version: v1
related:
  - ../../4-Archieves/wms1/plan/SBDEV-2512-partitionallowed-split-pick-overstock-guard.md
  - ./wms1-verify-move-stock-lost-update-on-dev.md
  - ../../3-Resources/workflows/wms1-move-stock-unitload-workflow.md
tags:
  - runbook
  - order-release
---

# Releasing the two orders held by the SBDEV-2512 guard

| | |
|---|---|
| **Ackley Brands** | order `062100-000004` (`ME101413`), id **34956804**, state **50** |
| **Zerolink / Vino Shipper** | order `062126-000001` (`96934210193:807`), id **34963469**, state **50** |
| **Script** | `sbdocs/9-System/scripts/fix-SBDEV-3371-consolidate-club-stock.sh` |

## Why these are held — and why "add stock" is the wrong instinct

Neither order is short of inventory. Both are held by the SBDEV-2512 guard in
`ReleaseOrderJobService`: a non-partitionable position must be fillable from **one** stock unit.
Aggregate availability is *exactly* sufficient in both cases, but it is spread across several unit
loads, so no single unit covers the line.

| order | SKU | needs | pickable stock | largest single unit |
|---|---|---|---|---|
| 062100-000004 | 2290074 | 6 | Club01: **3 + 2 + 1 = 6** | **3** |
| 062126-000001 | 42000 | 12 | Club02: **10 + 2 = 12** | **10** |

Consolidating the residue onto one unit load per SKU satisfies the guard. The order-release cron
runs **every minute** (`ORDER_TIMER_MINUTE = '*'`) and releases both on its own afterwards. No code
change, no restart, no deploy.

Club-location eligibility is a red herring: `Club01` and `Club02` both sit in location area **id
51553, `Storage and Picking`**, which carries `useforpicking = true` and `entity_lock = 0`. The stock
**was** already eligible and **was** already counted. ⚠ `useforpicking` is a column on
**`location_area`**, not on `location` — a pre-flight written against `location.useforpicking` finds
no such column.

---

## Step 1 — pre-flight (read-only, run this first)

Abort if anything differs. This checks every precondition that `StockunitBusinessService
.transferStockToUnitLoad` imposes with `ignoreLock = false`, not just the stock amounts: source
stock unit, source unit load, **source location**, **destination unit load** and **destination
location** must all be at `entity_lock = 0`.

```sql
SELECT s.id AS stock_unit, s.amount, s.reservedamount,
       s.entity_lock AS su_lock, u.labelid AS unit_load, u.entity_lock AS ul_lock,
       l.name AS location, l.entity_lock AS loc_lock,
       a.name AS area, a.useforpicking, a.entity_lock AS area_lock
FROM   stockunit s
JOIN   unitload u      ON u.id = s.unitload_id
JOIN   location l      ON l.id = u.storagelocation_id
JOIN   location_area a ON a.id = l.area_id
WHERE  s.itemdata_id IN (826712454, 3353873)
  AND  l.name IN ('Club01','Club02')
ORDER  BY l.name, s.amount DESC;
```

| stock unit | amount | reserved | all four locks | unit load | location |
|---|---|---|---|---|---|
| 946694786 | 3 | 0 | 0 | `UL296352` | Club01 |
| 946694784 | 2 | 0 | 0 | `UL296350` | Club01 |
| 833881128 | 1 | 0 | 0 | `UL259126` | Club01 |
| 672162417 | 10 | 0 | 0 | `UL196620` | Club02 |
| 34966260 | 2 | 0 | 0 | `UL354466` | Club02 |

A second precondition that is easy to miss: emptying a source stock unit calls
`sendStockUnitToNirvana`, which throws `ACTIVE_PICK_MESSAGE` if **any** `pickingorder_position` row
references it — active or not. Must return 0:

```sql
SELECT count(*) FROM pickingorder_position
WHERE  pickfromstockunit_id IN (34966260, 946694784, 833881128);   -- expect 0
```

And both orders still held:

```sql
SELECT o.id, o.number, o.state AS order_state, p.id AS position, p.state AS position_state, p.amount
FROM   customerorder o JOIN customerorder_position p ON p.order_id = o.id
WHERE  o.id IN (34956804, 34963469) AND p.state BETWEEN 50 AND 58;
-- expect: 34956804/34956807 state 55 amount 6, and 34963469/34963470 state 55 amount 12
```

---

## Step 2 — consolidate

### Connection settings — confirm before running

| variable | value | how it was established |
|---|---|---|
| `API` | **unknown — you must supply it** | see below |
| `KC` | `https://kc.om1.komatik.co/auth` | `los_sysprop.KEYCLOAK_SERVER_URL`, read from prod |
| `REALM` | `komatik` | `los_sysprop.KEYCLOAK_REALM` |
| `CLIENT` | `om1-api` | `los_sysprop.KEYCLOAK_CLIENT`, the part **before** the slash |
| `CLIENT_SECRET` | the part **after** the slash in `KEYCLOAK_CLIENT` | `om1-api` is a confidential client, so the password grant needs it; without it Keycloak answers `invalid_client` |

Read the secret out of the database at run time rather than copying it anywhere:

```sql
SELECT sysvalue FROM los_sysprop WHERE syskey = 'KEYCLOAK_CLIENT';  -- "om1-api/<secret>"
```

⚠ **Do not use `kc.dev.sbo.li` / realm `spk` / client `om1`.** Those are the DEV values that
`application.properties:64` commits, and the sibling runbook
[`wms1-verify-move-stock-lost-update-on-dev`](./wms1-verify-move-stock-lost-update-on-dev.md) uses —
they are correct there and wrong here.

⚠ **`API` has no default and must come from whoever owns the deploy.** Nothing in the repo or the
database establishes it, and two prod host families are in active use for this warehouse:
`wms.wineco.sbo.li` / `api-oms.wineco.sbo.li` (`MOBILE_UI_URL`, `WEBSERVICE_*`) and
`wh01m.komatik.co` / `kc.om1.komatik.co` (`WEB_UI_REDIRECT_URL`, `MOBILE_UI_REDIRECT_URL`,
`KEYCLOAK_SERVER_URL`). Guessing is the one way this procedure could do real damage: `UL######` is a
house-wide label format and stock unit ids are per-database, so a *different* v1 deployment that
accepted the token could plausibly own these ids and move somebody else's stock while printing `OK`.

### Run it

```bash
cd sbdocs/9-System/scripts

# 1. verify only — proves the target and the state, changes nothing
API=<confirmed v1 api base url> KC_USER=<user> KC_PASS=<pass> CLIENT_SECRET=<secret> \
  ./fix-SBDEV-3371-consolidate-club-stock.sh

# 2. apply
API=<same> KC_USER=<user> KC_PASS=<pass> CLIENT_SECRET=<secret> \
  ./fix-SBDEV-3371-consolidate-club-stock.sh --apply
```

**How it protects itself.** There is no Java-version check — this is Spring Boot 2.3.7 with no
build-info and no git-commit-id plugin, so `/actuator/info` returns `{}` and a version guard would be
dead code that always warns. Instead the script asserts the **stock shape**: stock units `946694786`
and `672162417` must read `3`/`10` (nothing applied) or `3`/`12`, `5`/`12`, `6`/`12` (this plan
partly or fully applied). Anything else stops the run. Each leg is then guarded on both sides —
source exactly as expected before, destination exactly as expected after — so:

- a leg that already ran is **detected and skipped**;
- **re-running the script is safe**, and is how you resume after a partial failure;
- an unexpected amount stops everything before it moves anything.

The three legs, in order (Zerolink first: one call, smallest blast radius, and it exercises the
identical branch — same unit-load type, same merge path — so it genuinely proves the recipe):

| # | move | from | to | result |
|---|---|---|---|---|
| 1 | 2 of SKU 42000 (su `34966260`) | `UL354466` | `UL196620` | **12 in one unit** → Zerolink releasable |
| 2 | 2 of SKU 2290074 (su `946694784`) | `UL296350` | `UL296352` | 5 — still short, expected |
| 3 | 1 of SKU 2290074 (su `833881128`) | `UL259126` | `UL296352` | **6 in one unit** → Ackley releasable |

### Without the script

Three POSTs, in this order. The endpoint answers **HTTP 200 on failure too**, with
`{"errors":[…]}` — success is the literal body `true` and nothing else.

```bash
for body in \
 '{"id":34966260,"amountToTransfer":2,"isTransferExistingContainer":true,"labelId":"UL196620","printLabel":false,"comment":"SBDEV-3371"}' \
 '{"id":946694784,"amountToTransfer":2,"isTransferExistingContainer":true,"labelId":"UL296352","printLabel":false,"comment":"SBDEV-3371"}' \
 '{"id":833881128,"amountToTransfer":1,"isTransferExistingContainer":true,"labelId":"UL296352","printLabel":false,"comment":"SBDEV-3371"}' ; do
  echo "--> $body"
  curl -sS -X POST "$API/v3/stockUnit/transferStock" -H "Authorization: Bearer $AT" \
       -H 'Content-Type: application/json' -d "$body"; echo
done
```

Or on the handheld: mobile **Move Stock** (`MOBILE_UI_VIEW_STOCK_TRANSFER`) — scan the source unit
load, pick the stock unit and amount, then scan the **destination unit-load label**. Not a location
name: `MobileMoveStockService.selectDestination` rejects a location that is not a flowbin with
*"Destination is not a flowbin!"*.

### Expected side effects

- `UL354466`, `UL296350` and `UL259126` end up empty and are sent to Nirwana, so their labels vanish
  from Club01/Club02. The emptied **stock units are not deleted** — `sendStockUnitToNirvana`
  reparents them to the Nirwana unit load and sets `entity_lock = 405`, so the rows still resolve by
  id afterwards.
- **The release is announced to the live OMS.** `ReleaseOrderJobService` calls
  `ManageOrderService.customerOrderReleaseForPicking`, which POSTs to
  `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` = `https://api-oms.wineco.sbo.li/services/call/readytopick`
  on this database. Two orders reach the production OMS within ~2 minutes of the third leg. This is
  the intended outcome, and it is the part that cannot be taken back.

---

## Step 3 — confirm the release

Wait ~2 minutes for the cron, then:

```sql
SELECT o.id, o.number, o.state AS order_state, p.id AS position, p.state AS position_state
FROM   customerorder o JOIN customerorder_position p ON p.order_id = o.id
WHERE  o.id IN (34956804, 34963469)
ORDER  BY o.id, p.id;
```

**PASS** — orders and positions at **200** (`ASSIGNED`, rendered "Released").
**FAIL** — still 50 / 55.

Consolidation itself:

```sql
SELECT s.id, s.amount, u.labelid, l.name
FROM   stockunit s JOIN unitload u ON u.id = s.unitload_id JOIN location l ON l.id = u.storagelocation_id
WHERE  s.id IN (946694786, 672162417);
-- expect 946694786 = 6 on UL296352, 672162417 = 12 on UL196620
```

### If it does not release

**Re-run the Step 1 pre-flight SQL first.** Do not reason from the script's output — a client
timeout does not roll the server transaction back, so after any non-clean exit the on-disk state is
the only thing that knows what happened. Then, in order:

1. Did the consolidation actually land (the query just above)? If not, re-run the script — it skips
   whatever already applied and retries the rest.
2. **Is the guard now hitting a *different* position on the Ackley order?** This is the most likely
   answer, and it is the plan's real fragility. `containsUnsatisfiedPosition` is **order-wide**, so
   one failing line holds all of 34956804 — and its other two lines are subject to the same guard
   (`partitionallowed = false`, like every position in this system) with **zero slack**:

   | position | SKU | needs | covered by | slack |
   |---|---|---|---|---|
   | 34956805 | 1989050 | 3 | su `34964617` = 3 on `UL354400`, Club01 | **none** |
   | 34956806 | 2089031 | 3 | su `34964283` = 3 on `UL354397`, Club01 | **none** |

   Each is satisfied by exactly one exactly-covering unit. Any pick, split or move against either
   between now and the release holds the Ackley order again, and the fix is the same: consolidate
   that SKU onto one unit load. Check with:

   ```sql
   SELECT p.id AS position, p.amount AS needs, max(s.amount - s.reservedamount) AS largest_unit
   FROM   customerorder_position p
   JOIN   stockunit s      ON s.itemdata_id = p.itemdata_id AND s.entity_lock = 0
   JOIN   unitload u       ON u.id = s.unitload_id AND u.entity_lock = 0
   JOIN   location l       ON l.id = u.storagelocation_id AND l.entity_lock = 0
   JOIN   location_area a  ON a.id = l.area_id AND a.useforpicking
   WHERE  p.id IN (34956805, 34956806, 34956807, 34963470)
   GROUP  BY p.id, p.amount;
   -- every row must have largest_unit >= needs
   ```

3. Has something consumed the consolidated unit? Nothing should compete for it: on 2026-09-16 no
   other order below state 200 held a position on any of these four SKUs.

---

## Alternative — the kill switch (global, no inventory movement)

One row, no redeploy, releases **every** order held this way rather than these two.

The `NOT NULL`-without-default columns on `los_sysprop` are **`id`, `version`, `hidden`, `syskey`,
`workstation`, `client_id`** — all six must be supplied. House convention on every existing row is
`workstation = 'DEFAULT'`, `client_id = 0`, `hidden = false`, `version = 0`, `entity_lock = 0`; ids
step by 50 and `max(id)` was `6826751` on 2026-09-16. The unique constraint is
`(client_id, syskey, workstation)` and no `ENFORCE_PARTITIONALLOWED` row exists, so there is no
conflict.

```sql
INSERT INTO los_sysprop (id, syskey, sysvalue, workstation, client_id, hidden,
                         groupname, description, created, modified, version, entity_lock)
VALUES (6826801, 'ENFORCE_PARTITIONALLOWED', 'false', 'DEFAULT', 0, false,
        'Operation Options',
        'SBDEV-3371: disable the SBDEV-2512 single-covering-unit guard', now(), now(), 0, 0);
```

Re-check `SELECT max(id) FROM los_sysprop;` before taking `6826801`. `groupname` is supplied
deliberately: the admin listing query `getSystemByGroupname` filters `where ls.groupname = :groupName`,
so a NULL-groupname row is **invisible in the sysprop admin UI** — a poor property for a switch
someone may later need to find and flip back.

⚠ Three things to know before choosing this:

- It reinstates exactly what SBDEV-2512 existed to stop: a 12-bottle line picked as loose bottles
  across several unit loads instead of one case (the original complaint, BF173533).
- It disables **both** halves of that fix — Fix A (the hold) and Fix B (the single-pick) read the
  same `enforcePartitionGuard` local.
- `los_sysprop.description` is `varchar(255)`; the text above is 62 characters.

Reverse it by setting `sysvalue = 'true'` or deleting the row. The guard reads
`!"false".equalsIgnoreCase(...)`, so only the literal `false` disables it; absent or anything else
enforces. **Effective on the next cron tick** — `findSysvalueBySyskey` is a plain native query and v1
has no caching layer at all (no `@Cacheable` / `@CacheEvict` / `@EnableCaching` anywhere in
`v1/wms-api/src/main/java/net/aim_ai/wms`). Do not carry the v2 assumption here: v2 caches sysprops
for 2 minutes and a direct SQL write there bypasses the `@CacheEvict`.

**Recommendation:** consolidate (Step 2). The kill switch is the right lever only if this starts
happening to many orders at once, in which case the real answer is the code change discussed on the
ticket, not a permanently-off guard.

---

## Do not do this with raw SQL

Updating `stockunit.amount` directly would leave no `stockrecord` pair, would not send the emptied
stock unit or unit load to Nirwana, and would not bump `@Version`. The inventory ledger is what
billing and the stock reports read, and there is no repair path for a hand-edited row. Both routes
above go through `transferStockToUnitLoad`, which is also the path SBDEV-3003 hardened against lost
updates.

## No clean rollback

Two separate things cannot be undone, and both should be decided before running, not after:

- **The merge has no inverse call.** Splitting the stock back out creates a **new** unit load with a
  new label; it does not restore `UL296350` / `UL259126` / `UL354466`, which will have gone to
  Nirwana. Safe to do — it is an ordinary warehouse operation and the same stock stays on the same
  location — but not a rollback.
- **The OMS notification.** Once the cron releases the orders, `readytopick` has been POSTed to the
  production OMS. Nothing in the WMS can retract it.

---

## Traps encountered while writing this

- **`POST /v3/stockUnit/transferStock` returns HTTP 200 on failure.** `StockUnitController:104-119`
  catches `BusinessException` / `FacadeException` / `Exception` and answers `200` with
  `{"errors":[…]}`; success is `ResponseEntity<Object>(true, …)` at `:116`, which Jackson writes as
  the literal `true`. A status-code check reports success on a refused transfer. Equally,
  `curl -f` is wrong here — it would let a 401/404/500/timeout kill the script inside a command
  substitution before any handler could say what state things are in. The script captures status and
  body separately and judges both.
- **`id` is read as `((Integer) reqMap.get("id")).longValue()`** (`StockUnitController:62`), and both
  that cast and the `isTransferExistingContainer` unboxing happen **outside** the try block — so a
  stock-unit id above 2^31, or an omitted flag, is a 500 rather than a handled error. All four ids
  here are comfortably below it; a future reuse of this recipe may not be.
- **Timestamps on this DB are warehouse-local, `now()` is UTC.** A `WHERE created > now() - interval`
  filter silently returns nothing and reads as "the job never ran". Measured on `customerorder`:
  creation activity falls only in hours 07–16, a workday in `America/Los_Angeles`. Drop the time
  filter and use `ORDER BY created DESC LIMIT 20`. Same trap as
  [`wms1-verify-move-stock-lost-update-on-dev`](./wms1-verify-move-stock-lost-update-on-dev.md) §1.
- **`useforpicking` lives on `location_area`, not `location`.**
- **Destination must be a unit-load label, not a location name** on the mobile path.
